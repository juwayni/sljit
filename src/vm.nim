import std/tables
import ir, ast, runtime, codegen

type
  JitCompilerCallback* = proc(instructions: seq[IRInstruction], stringPool: seq[string]): pointer

  CallFrame* = object
    returnPc*: int
    returnDstVReg*: VirtualReg
    registers*: ptr UncheckedArray[VMValue]

  VMContext* = object
    registers*: ptr UncheckedArray[VMValue]
    maxRegs*: int
    callStack*: seq[CallFrame]
    stringPool*: seq[string]
    loopCounters*: Table[int, int]
    hotThreshold*: int
    jitCallback*: JitCompilerCallback
    jitCompiledCode*: Table[int, pointer] # loopId -> native code ptr
    procEntryPoints*: Table[string, int] # Proc name -> IR instruction index

proc initVMContext*(stringPool: seq[string], hotThreshold = 10, jitCallback: JitCompilerCallback = nil, maxRegs = 1024): VMContext =
  let regBuf = cast[ptr UncheckedArray[VMValue]](alloc0(sizeof(VMValue) * maxRegs))
  VMContext(
    registers: regBuf,
    maxRegs: maxRegs,
    callStack: @[],
    stringPool: stringPool,
    loopCounters: initTable[int, int](),
    hotThreshold: hotThreshold,
    jitCallback: jitCallback,
    jitCompiledCode: initTable[int, pointer](),
    procEntryPoints: initTable[string, int]()
  )

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

    let dst = inst.dst.id
    let s1 = inst.src1.id
    let s2 = inst.src2.id

    {.computedGoto.}
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
      let retVal = vm.registers[s1]
      if vm.callStack.len > 0:
        let frame = vm.callStack.pop()
        pc = frame.returnPc
        vm.registers = frame.registers
        if frame.returnDstVReg.id > 0:
          vm.registers[frame.returnDstVReg.id] = retVal
        inc pc
        continue
      else:
        return retVal.asInt

    of opLoadIntConst:
      vm.registers[dst].asInt = inst.intImm

    of opLoadFloatConst:
      vm.registers[dst].asFloat = inst.floatImm

    of opLoadStrConst:
      let sHeaderPtr = addr strHeaders[inst.strIndex]
      vm.registers[dst].asPtr = cast[pointer](sHeaderPtr)

    of opLoadVar, opStoreVar:
      if s1 > 0:
        vm.registers[dst] = vm.registers[s1]

    of opAdd:
      if inst.dst.dataType == dtFloat64:
        vm.registers[dst].asFloat = vm.registers[s1].asFloat + vm.registers[s2].asFloat
      else:
        vm.registers[dst].asInt = vm.registers[s1].asInt + vm.registers[s2].asInt

    of opSub:
      if inst.dst.dataType == dtFloat64:
        vm.registers[dst].asFloat = vm.registers[s1].asFloat - vm.registers[s2].asFloat
      else:
        vm.registers[dst].asInt = vm.registers[s1].asInt - vm.registers[s2].asInt

    of opMul:
      if inst.dst.dataType == dtFloat64:
        vm.registers[dst].asFloat = vm.registers[s1].asFloat * vm.registers[s2].asFloat
      else:
        vm.registers[dst].asInt = vm.registers[s1].asInt * vm.registers[s2].asInt

    of opDiv:
      if inst.dst.dataType == dtFloat64:
        vm.registers[dst].asFloat = vm.registers[s1].asFloat / vm.registers[s2].asFloat
      else:
        let divVal = vm.registers[s2].asInt
        vm.registers[dst].asInt = if divVal != 0: vm.registers[s1].asInt div divVal else: 0

    of opShl:
      vm.registers[dst].asInt = vm.registers[s1].asInt shl inst.shiftAmount

    of opAshr:
      vm.registers[dst].asInt = vm.registers[s1].asInt shr inst.shiftAmount

    of opConcatStr:
      let str1Ptr = cast[ptr NimStringHeader](vm.registers[s1].asPtr)
      let str2Ptr = cast[ptr NimStringHeader](vm.registers[s2].asPtr)
      let resHeaderPtr = nim_str_concat(str1Ptr, str2Ptr)
      vm.registers[dst].asPtr = cast[pointer](resHeaderPtr)

    of opCmpEq:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat == vm.registers[s2].asFloat) else: (vm.registers[s1].asInt == vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opCmpNeq:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat != vm.registers[s2].asFloat) else: (vm.registers[s1].asInt != vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opCmpLt:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat < vm.registers[s2].asFloat) else: (vm.registers[s1].asInt < vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opCmpLe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat <= vm.registers[s2].asFloat) else: (vm.registers[s1].asInt <= vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opCmpGt:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat > vm.registers[s2].asFloat) else: (vm.registers[s1].asInt > vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opCmpGe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let cond = if isFloat: (vm.registers[s1].asFloat >= vm.registers[s2].asFloat) else: (vm.registers[s1].asInt >= vm.registers[s2].asInt)
      vm.registers[dst].asInt = if cond: 1'i64 else: 0'i64

    of opJumpCmp:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      var cond = false
      if isFloat:
        let v1 = vm.registers[s1].asFloat
        let v2 = vm.registers[s2].asFloat
        case inst.cmpOp
        of opCmpEq: cond = (v1 == v2)
        of opCmpNeq: cond = (v1 != v2)
        of opCmpLt: cond = (v1 < v2)
        of opCmpLe: cond = (v1 <= v2)
        of opCmpGt: cond = (v1 > v2)
        of opCmpGe: cond = (v1 >= v2)
        else: discard
      else:
        let v1 = vm.registers[s1].asInt
        let v2 = vm.registers[s2].asInt
        case inst.cmpOp
        of opCmpEq: cond = (v1 == v2)
        of opCmpNeq: cond = (v1 != v2)
        of opCmpLt: cond = (v1 < v2)
        of opCmpLe: cond = (v1 <= v2)
        of opCmpGt: cond = (v1 > v2)
        of opCmpGe: cond = (v1 >= v2)
        else: discard

      let takeJump = if inst.jumpIfZero: not cond else: cond
      if takeJump:
        pc = findLabelPos(instructions, inst.labelIdx)
        continue

    of opJump:
      pc = findLabelPos(instructions, inst.labelIdx)
      continue

    of opJumpIfZero:
      if vm.registers[s1].asInt == 0:
        pc = findLabelPos(instructions, inst.labelIdx)
        continue

    of opJumpIfNotZero:
      if vm.registers[s1].asInt != 0:
        pc = findLabelPos(instructions, inst.labelIdx)
        continue

    of opJumpBack:
      let loopId = inst.loopId
      let currentCount = vm.loopCounters.getOrDefault(loopId, 0) + 1
      vm.loopCounters[loopId] = currentCount

      if currentCount >= vm.hotThreshold:
        if not vm.jitCompiledCode.hasKey(loopId):
          echo "[VM Tier 4 Hot Loop Detector] Loop #", loopId, " reached threshold (", currentCount, " iterations). Triggering Phase 3 True OSR JIT Compilation!"
          let codePtr = compileOSRToNative(instructions, vm.stringPool, loopId, vm.maxRegs)
          vm.jitCompiledCode[loopId] = codePtr

        if vm.jitCompiledCode[loopId] != nil:
          type OSREntryProc = proc(vmFrame: ptr UncheckedArray[VMValue]): int {.cdecl.}
          let nativeOSR = cast[OSREntryProc](vm.jitCompiledCode[loopId])
          echo "[VM Tier 4 True OSR] Transferring VM register frame -> Hardware registers, jumping directly into native loop!"
          let exitLabelIdx = nativeOSR(vm.registers)
          echo "[VM Tier 4 True OSR] Loop completed natively. Written back hardware registers -> VM frame. Resuming VM at label ", exitLabelIdx
          if exitLabelIdx > 0:
            pc = findLabelPos(instructions, exitLabelIdx)
            continue
          else:
            return 0

      pc = findLabelPos(instructions, inst.labelIdx)
      continue

    of opLabel:
      discard

    of opPrint:
      case inst.printType
      of dtInt64:
        nim_int_print(vm.registers[s1].asInt)
      of dtFloat64:
        nim_float_print(vm.registers[s1].asFloat)
      of dtString:
        nim_str_print(cast[ptr NimStringHeader](vm.registers[s1].asPtr))
      else:
        discard

    inc pc

  return 0
