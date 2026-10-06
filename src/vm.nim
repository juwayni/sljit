import std/tables
import ir, ast, runtime, codegen

type
  JitCompilerCallback* = proc(instructions: seq[IRInstruction], stringPool: seq[string]): pointer

  CallFrame* = object
    returnPc*: int
    returnDstVReg*: VirtualReg
    registers*: Table[VRegId, VMValue]

  VMContext* = object
    registers*: Table[VRegId, VMValue]
    callStack*: seq[CallFrame]
    stringPool*: seq[string]
    loopCounters*: Table[int, int]
    hotThreshold*: int
    jitCallback*: JitCompilerCallback
    jitCompiledCode*: Table[int, pointer] # loopId -> native code ptr
    procEntryPoints*: Table[string, int] # Proc name -> IR instruction index

proc initVMContext*(stringPool: seq[string], hotThreshold = 10, jitCallback: JitCompilerCallback = nil): VMContext =
  VMContext(
    registers: initTable[VRegId, VMValue](),
    callStack: @[],
    stringPool: stringPool,
    loopCounters: initTable[int, int](),
    hotThreshold: hotThreshold,
    jitCallback: jitCallback,
    jitCompiledCode: initTable[int, pointer](),
    procEntryPoints: initTable[string, int]()
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

  # Pre-scan procedure entry points
  for idx, inst in instructions:
    if inst.op == opProcEntry:
      vm.procEntryPoints[inst.procName] = idx

  while pc < instructions.len:
    let inst = instructions[pc]

    case inst.op
    of opProcEntry:
      discard

    of opProcExit:
      if vm.callStack.len > 0:
        let frame = vm.callStack.pop()
        pc = frame.returnPc
        vm.registers = frame.registers
        inc pc
        continue

    of opCall:
      if vm.procEntryPoints.hasKey(inst.procName):
        let targetPc = vm.procEntryPoints[inst.procName]
        let frame = CallFrame(
          returnPc: pc,
          returnDstVReg: inst.dst,
          registers: vm.registers
        )
        vm.callStack.add(frame)
        pc = targetPc + 1
        continue
      else:
        raise newException(ValueError, "VM Error: Procedure '" & inst.procName & "' not found.")

    of opReturn:
      let retVal = vm.registers.getOrDefault(inst.src1.id, VMValue(kind: vkInt, intVal: 0))
      if vm.callStack.len > 0:
        let frame = vm.callStack.pop()
        pc = frame.returnPc
        vm.registers = frame.registers
        if frame.returnDstVReg.id > 0:
          vm.registers[frame.returnDstVReg.id] = retVal
        inc pc
        continue
      else:
        return retVal.intVal

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
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) == vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) == vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

    of opCmpNeq:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) != vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) != vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

    of opCmpLt:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) < vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) < vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

    of opCmpLe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) <= vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) <= vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

    of opCmpGt:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) > vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) > vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

    of opCmpGe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.getFloat(inst.src1) >= vm.getFloat(inst.src2)) else: (vm.getInt(inst.src1) >= vm.getInt(inst.src2))
      vm.registers[inst.dst.id] = VMValue(kind: vkInt, intVal: if cond: 1'i64 else: 0'i64)

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

      if currentCount >= vm.hotThreshold:
        if not vm.jitCompiledCode.hasKey(loopId):
          echo "[VM Tier 4 Hot Loop Detector] Loop #", loopId, " reached threshold (", currentCount, " iterations). Triggering True OSR JIT Compilation!"
          let codePtr = compileOSRToNative(instructions, vm.stringPool, loopId, vm.registers)
          vm.jitCompiledCode[loopId] = codePtr

        if vm.jitCompiledCode[loopId] != nil:
          type NativeOSRProc = proc() {.cdecl.}
          let nativeFn = cast[NativeOSRProc](vm.jitCompiledCode[loopId])
          echo "[VM Tier 4 True OSR] Transferring active live VM register frame directly into SLJIT Native Loop Execution!"
          nativeFn()
          return 0

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

    inc pc

  return 0
