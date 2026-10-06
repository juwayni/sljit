import std/tables
import ir, ast, runtime

type
  VMValueKind* = enum
    vkInt,
    vkFloat,
    vkString

  VMValue* = object
    case kind*: VMValueKind
    of vkInt:
      intVal*: int64
    of vkFloat:
      floatVal*: float64
    of vkString:
      strVal*: ptr NimStringHeader

  JitCompilerCallback* = proc(instructions: seq[IRInstruction], stringPool: seq[string]): pointer

  VMContext* = object
    registers*: Table[VRegId, VMValue]
    stringPool*: seq[string]
    loopCounters*: Table[int, int]
    hotThreshold*: int
    jitCallback*: JitCompilerCallback
    jitCompiledCode*: Table[int, pointer] # loopId -> native code ptr

proc initVMContext*(stringPool: seq[string], hotThreshold = 10, jitCallback: JitCompilerCallback = nil): VMContext =
  VMContext(
    registers: initTable[VRegId, VMValue](),
    stringPool: stringPool,
    loopCounters: initTable[int, int](),
    hotThreshold: hotThreshold,
    jitCallback: jitCallback,
    jitCompiledCode: initTable[int, pointer]()
  )

proc getInt*(vm: VMContext, vreg: VirtualReg): int64 =
  if vreg.id in vm.registers:
    return vm.registers[vreg.id].intVal
  return 0

proc getFloat*(vm: VMContext, vreg: VirtualReg): float64 =
  if vreg.id in vm.registers:
    return vm.registers[vreg.id].floatVal
  return 0.0

proc getString*(vm: VMContext, vreg: VirtualReg): ptr NimStringHeader =
  if vreg.id in vm.registers:
    return vm.registers[vreg.id].strVal
  return nil

proc findLabelPos*(instructions: seq[IRInstruction], labelIdx: int): int =
  for idx, inst in instructions:
    if inst.op == opLabel and inst.labelIdx == labelIdx:
      return idx
  raise newException(ValueError, "VM Error: Label " & $labelIdx & " not found.")

proc executeInterpreter*(vm: var VMContext, instructions: seq[IRInstruction]): int64 =
  var pc = 0
  var strHeaders: seq[NimStringHeader] = @[]

  for s in vm.stringPool:
    strHeaders.add(createNimString(s))

  while pc < instructions.len:
    let inst = instructions[pc]

    case inst.op
    of opLoadIntConst:
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: inst.intImm)

    of opLoadFloatConst:
      vm.registers[inst.dst.id] = VMValue(kind: vkFloat, floatVal: inst.floatImm)

    of opLoadStrConst:
      let sHeaderPtr = addr strHeaders[inst.strIndex]
      vm.registers[inst.dst.id] = VMValue(kind: vkString, strVal: sHeaderPtr)

    of opLoadVar, opStoreVar:
      if inst.src1.id > 0 and vm.registers.hasKey(inst.src1.id):
        vm.registers[inst.dst.id] = vm.registers[inst.src1.id]

    of opAdd:
      if inst.dst.dataType == dtFloat64:
        let res = vm.getFloat(inst.src1) + vm.getFloat(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkFloat, floatVal: res)
      else:
        let res = vm.getInt(inst.src1) + vm.getInt(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opSub:
      if inst.dst.dataType == dtFloat64:
        let res = vm.getFloat(inst.src1) - vm.getFloat(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkFloat, floatVal: res)
      else:
        let res = vm.getInt(inst.src1) - vm.getInt(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opMul:
      if inst.dst.dataType == dtFloat64:
        let res = vm.getFloat(inst.src1) * vm.getFloat(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkFloat, floatVal: res)
      else:
        let res = vm.getInt(inst.src1) * vm.getInt(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opDiv:
      if inst.dst.dataType == dtFloat64:
        let res = vm.getFloat(inst.src1) / vm.getFloat(inst.src2)
        vm.registers[inst.dst.id] = VMValue(kind: vkFloat, floatVal: res)
      else:
        let r2 = vm.getInt(inst.src2)
        let res = if r2 != 0: vm.getInt(inst.src1) div r2 else: 0
        vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opConcatStr:
      let s1 = vm.getString(inst.src1)
      let s2 = vm.getString(inst.src2)
      let resHeaderPtr = nim_str_concat(s1, s2)
      vm.registers[inst.dst.id] = VMValue(kind: vkString, strVal: resHeaderPtr)

    of opCmpEq:
      let res = if vm.getInt(inst.src1) == vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opCmpNeq:
      let res = if vm.getInt(inst.src1) != vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opCmpLt:
      let res = if vm.getInt(inst.src1) < vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opCmpLe:
      let res = if vm.getInt(inst.src1) <= vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opCmpGt:
      let res = if vm.getInt(inst.src1) > vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opCmpGe:
      let res = if vm.getInt(inst.src1) >= vm.getInt(inst.src2): 1'i64 else: 0'i64
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: res)

    of opJump:
      pc = findLabelPos(instructions, inst.labelIdx)
      continue

    of opJumpIfZero:
      if vm.getInt(inst.src1) == 0:
        pc = findLabelPos(instructions, inst.labelIdx)
        continue

    of opJumpIfNotZero:
      if vm.getInt(inst.src1) != 0:
        pc = findLabelPos(instructions, inst.labelIdx)
        continue

    of opJumpBack:
      let loopId = inst.loopId
      let currentCount = vm.loopCounters.getOrDefault(loopId, 0) + 1
      vm.loopCounters[loopId] = currentCount

      if currentCount >= vm.hotThreshold and vm.jitCallback != nil:
        if not vm.jitCompiledCode.hasKey(loopId):
          echo "[VM Tier 4 Hot Loop Detector] Loop #", loopId, " reached threshold (", currentCount, " iterations). Triggering OSR / JIT Compilation!"
          let codePtr = vm.jitCallback(instructions, vm.stringPool)
          vm.jitCompiledCode[loopId] = codePtr

        if vm.jitCompiledCode[loopId] != nil:
          type NativeMainProc = proc(): int64 {.cdecl.}
          let nativeFn = cast[NativeMainProc](vm.jitCompiledCode[loopId])
          echo "[VM Tier 4 OSR] Transferring control to SLJIT Native Code Execution!"
          return nativeFn()

      pc = findLabelPos(instructions, inst.labelIdx)
      continue

    of opLabel:
      discard

    of opPrint:
      case inst.printType
      of dtInt64:
        nim_int_print(vm.getInt(inst.src1))
      of dtFloat64:
        nim_float_print(vm.getFloat(inst.src1))
      of dtString:
        nim_str_print(vm.getString(inst.src1))
      else:
        discard

    of opCall:
      discard

    of opReturn:
      return vm.getInt(inst.src1)

    inc pc

  return 0
