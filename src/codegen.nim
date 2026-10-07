import std/tables
import sljit_bindings, runtime, ir, regalloc, ast

type
  JitCompiler* = object
    compiler*: SljitCompiler
    labels*: Table[int, SljitLabel]
    procLabels*: Table[string, SljitLabel]
    jumpsToResolve*: seq[tuple[jump: SljitJump, targetLabelIdx: int]]
    procJumps*: seq[tuple[jump: SljitJump, procName: string]]
    regAlloc*: RegAllocResult

proc initJitCompiler*(): JitCompiler =
  JitCompiler(
    compiler: nil,
    labels: initTable[int, SljitLabel](),
    procLabels: initTable[string, SljitLabel](),
    jumpsToResolve: @[],
    procJumps: @[],
    regAlloc: RegAllocResult()
  )

proc getRegOrLoad*(jit: var JitCompiler, vreg: VirtualReg, scratchReg: int32): int32 =
  if vreg.id <= 0: return scratchReg
  if jit.regAlloc.locations.hasKey(vreg.id):
    let loc = jit.regAlloc.locations[vreg.id]
    case loc.kind
    of rlReg:
      return loc.physReg
    of rlStackSlot:
      let opc = if vreg.dataType == dtFloat64: SLJIT_MOV_F64 else: SLJIT_MOV
      if vreg.dataType == dtFloat64:
        discard sljit_emit_fop1(jit.compiler, opc, scratchReg, 0, SLJIT_MEM1(SLJIT_SP), loc.stackOffset)
      else:
        discard sljit_emit_op1(jit.compiler, opc, scratchReg, 0, SLJIT_MEM1(SLJIT_SP), loc.stackOffset)
      return scratchReg
  return scratchReg

proc writeBack*(jit: var JitCompiler, vreg: VirtualReg, srcReg: int32) =
  if vreg.id <= 0: return
  if jit.regAlloc.locations.hasKey(vreg.id):
    let loc = jit.regAlloc.locations[vreg.id]
    case loc.kind
    of rlReg:
      if loc.physReg != srcReg:
        if vreg.dataType == dtFloat64:
          discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, loc.physReg, 0, srcReg, 0)
        else:
          discard sljit_emit_op1(jit.compiler, SLJIT_MOV, loc.physReg, 0, srcReg, 0)
    of rlStackSlot:
      if vreg.dataType == dtFloat64:
        discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, SLJIT_MEM1(SLJIT_SP), loc.stackOffset, srcReg, 0)
      else:
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_MEM1(SLJIT_SP), loc.stackOffset, srcReg, 0)

proc compileToNative*(instructions: seq[IRInstruction], stringPool: seq[string]): pointer =
  var jit = initJitCompiler()
  jit.compiler = sljit_create_compiler(nil)
  if jit.compiler == nil:
    raise newException(ValueError, "SLJIT Error: Failed to create compiler.")

  # Heap-allocate static string headers so they persist during JIT execution
  var heapHeaders: ptr UncheckedArray[NimStringHeader] = nil
  if stringPool.len > 0:
    heapHeaders = cast[ptr UncheckedArray[NimStringHeader]](alloc0(sizeof(NimStringHeader) * stringPool.len))
    for idx, s in stringPool:
      heapHeaders[idx] = createNimString(s)

  # Perform Hardware-Wide Register Allocation
  jit.regAlloc = allocateRegisters(instructions, maxIntRegs = 7, maxFloatRegs = 4)

  # Function Entry Prologue
  let localSize = int32(jit.regAlloc.spillStackSize + 128) # extra stack buffer for C-ABI call spilling
  let enterFlags = SLJIT_ENTER_FLOAT(4)
  discard sljit_emit_enter(jit.compiler, 0, SLJIT_ARGS0V(), 6 or enterFlags, 6, localSize)

  for inst in instructions:
    case inst.op
    of opProcEntry:
      let lbl = sljit_emit_label(jit.compiler)
      jit.procLabels[inst.procName] = lbl
      discard sljit_emit_op_dst(jit.compiler, SLJIT_FAST_ENTER, SLJIT_S3, 0)
      let procReturnSlot = jit.regAlloc.spillStackSize + 32
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_MEM1(SLJIT_SP), procReturnSlot, SLJIT_S3, 0)

    of opProcExit:
      let procReturnSlot = jit.regAlloc.spillStackSize + 32
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_S3, 0, SLJIT_MEM1(SLJIT_SP), procReturnSlot)
      discard sljit_emit_op_src(jit.compiler, SLJIT_FAST_RETURN, SLJIT_S3, 0)

    of opCall:
      let callJmp = sljit_emit_jump(jit.compiler, SLJIT_FAST_CALL)
      jit.procJumps.add((jump: callJmp, procName: inst.procName))

    of opLabel:
      let lbl = sljit_emit_label(jit.compiler)
      jit.labels[inst.labelIdx] = lbl

    of opLoadIntConst:
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R0)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_IMM, inst.intImm)
      jit.writeBack(inst.dst, dstReg)

    of opLoadFloatConst:
      let dstFReg = jit.getRegOrLoad(inst.dst, SLJIT_FR0)
      discard sljit_emit_fset64(jit.compiler, dstFReg, inst.floatImm)
      jit.writeBack(inst.dst, dstFReg)

    of opLoadStrConst:
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R0)
      let strHeaderPtr = addr heapHeaders[inst.strIndex]
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_IMM, cast[int](strHeaderPtr))
      jit.writeBack(inst.dst, dstReg)

    of opLoadVar, opStoreVar:
      if inst.src1.id > 0:
        if inst.dst.dataType == dtFloat64:
          let srcReg = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
          let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_FR1)
          discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, dstReg, 0, srcReg, 0)
          jit.writeBack(inst.dst, dstReg)
        else:
          let srcReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
          let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R1)
          discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, srcReg, 0)
          jit.writeBack(inst.dst, dstReg)

    of opAdd:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_ADD_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_ADD, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opSub:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_SUB_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_SUB, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opMul:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_MUL_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_MUL, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opDiv:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_DIV_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        if s1 != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, s1, 0)
        if s2 != SLJIT_R1: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, s2, 0)
        discard sljit_emit_op0(jit.compiler, SLJIT_DIV_SW)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_R0, 0)
        jit.writeBack(inst.dst, dst)

    of opShl:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R1)
      discard sljit_emit_op2(jit.compiler, SLJIT_SHL, dst, 0, s1, 0, SLJIT_IMM, inst.shiftAmount)
      jit.writeBack(inst.dst, dst)

    of opAshr:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R1)
      discard sljit_emit_op2(jit.compiler, SLJIT_ASHR, dst, 0, s1, 0, SLJIT_IMM, inst.shiftAmount)
      jit.writeBack(inst.dst, dst)

    of opConcatStr:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
      if s1 != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, s1, 0)
      if s2 != SLJIT_R1: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, s2, 0)
      let concatFnAddr = cast[int](nim_str_concat)
      discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS2(SLJIT_ARG_TYPE_P, SLJIT_ARG_TYPE_P, SLJIT_ARG_TYPE_P), SLJIT_IMM, concatFnAddr)
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R2)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_RETURN_REG, 0)
      jit.writeBack(inst.dst, dstReg)

    of opCmpEq, opCmpNeq, opCmpLt, opCmpLe, opCmpGt, opCmpGe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)

      var trueLbl: SljitJump
      if isFloat:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        var fcond: int32
        case inst.op
        of opCmpEq: fcond = SLJIT_F_EQUAL
        of opCmpNeq: fcond = SLJIT_F_NOT_EQUAL
        of opCmpLt: fcond = SLJIT_F_LESS
        of opCmpLe: fcond = SLJIT_F_LESS_EQUAL
        of opCmpGt: fcond = SLJIT_F_GREATER
        of opCmpGe: fcond = SLJIT_F_GREATER_EQUAL
        else: fcond = SLJIT_F_EQUAL
        trueLbl = sljit_emit_fcmp(jit.compiler, fcond, s1, 0, s2, 0)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        var icond: int32
        case inst.op
        of opCmpEq: icond = SLJIT_EQUAL
        of opCmpNeq: icond = SLJIT_NOT_EQUAL
        of opCmpLt: icond = SLJIT_SIG_LESS
        of opCmpLe: icond = SLJIT_SIG_LESS_EQUAL
        of opCmpGt: icond = SLJIT_SIG_GREATER
        of opCmpGe: icond = SLJIT_SIG_GREATER_EQUAL
        else: icond = SLJIT_EQUAL
        trueLbl = sljit_emit_cmp(jit.compiler, icond, s1, 0, s2, 0)

      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_IMM, 0)
      let endJmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)

      let lbl = sljit_emit_label(jit.compiler)
      sljit_set_label(trueLbl, lbl)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_IMM, 1)

      let endLbl = sljit_emit_label(jit.compiler)
      sljit_set_label(endJmp, endLbl)

      jit.writeBack(inst.dst, dst)

    of opJumpCmp:
      # Phase 6: Direct 1-instruction branch condition fusion
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      var jmp: SljitJump
      if isFloat:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        var fcond: int32
        case inst.cmpOp
        of opCmpEq:  fcond = if inst.jumpIfZero: SLJIT_F_NOT_EQUAL else: SLJIT_F_EQUAL
        of opCmpNeq: fcond = if inst.jumpIfZero: SLJIT_F_EQUAL else: SLJIT_F_NOT_EQUAL
        of opCmpLt:  fcond = if inst.jumpIfZero: SLJIT_F_GREATER_EQUAL else: SLJIT_F_LESS
        of opCmpLe:  fcond = if inst.jumpIfZero: SLJIT_F_GREATER else: SLJIT_F_LESS_EQUAL
        of opCmpGt:  fcond = if inst.jumpIfZero: SLJIT_F_LESS_EQUAL else: SLJIT_F_GREATER
        of opCmpGe:  fcond = if inst.jumpIfZero: SLJIT_F_LESS else: SLJIT_F_GREATER_EQUAL
        else: fcond = SLJIT_F_EQUAL
        jmp = sljit_emit_fcmp(jit.compiler, fcond, s1, 0, s2, 0)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        var icond: int32
        case inst.cmpOp
        of opCmpEq:  icond = if inst.jumpIfZero: SLJIT_NOT_EQUAL else: SLJIT_EQUAL
        of opCmpNeq: icond = if inst.jumpIfZero: SLJIT_EQUAL else: SLJIT_NOT_EQUAL
        of opCmpLt:  icond = if inst.jumpIfZero: SLJIT_SIG_GREATER_EQUAL else: SLJIT_SIG_LESS
        of opCmpLe:  icond = if inst.jumpIfZero: SLJIT_SIG_GREATER else: SLJIT_SIG_LESS_EQUAL
        of opCmpGt:  icond = if inst.jumpIfZero: SLJIT_SIG_LESS_EQUAL else: SLJIT_SIG_GREATER
        of opCmpGe:  icond = if inst.jumpIfZero: SLJIT_SIG_LESS else: SLJIT_SIG_GREATER_EQUAL
        else: icond = SLJIT_EQUAL
        jmp = sljit_emit_cmp(jit.compiler, icond, s1, 0, s2, 0)

      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJump:
      let jmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpIfZero:
      let condReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let jmp = sljit_emit_cmp(jit.compiler, SLJIT_EQUAL, condReg, 0, SLJIT_IMM, 0)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpIfNotZero:
      let condReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let jmp = sljit_emit_cmp(jit.compiler, SLJIT_NOT_EQUAL, condReg, 0, SLJIT_IMM, 0)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpBack:
      let jmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opPrint:
      case inst.printType
      of dtInt64:
        let valReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        if valReg != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, valReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_W), SLJIT_IMM, cast[int](nim_int_print))
      of dtFloat64:
        let valFReg = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        if valFReg != SLJIT_FR0: discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, SLJIT_FR0, 0, valFReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_F64), SLJIT_IMM, cast[int](nim_float_print))
      of dtString:
        let valReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        if valReg != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, valReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_P), SLJIT_IMM, cast[int](nim_str_print))
      else:
        discard

    of opReturn:
      let retReg = jit.getRegOrLoad(inst.src1, SLJIT_RETURN_REG)
      if retReg != SLJIT_RETURN_REG:
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0, retReg, 0)
      discard sljit_emit_return(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0)

  discard sljit_emit_return_void(jit.compiler)

  for item in jit.jumpsToResolve:
    if jit.labels.hasKey(item.targetLabelIdx):
      sljit_set_label(item.jump, jit.labels[item.targetLabelIdx])

  for item in jit.procJumps:
    if jit.procLabels.hasKey(item.procName):
      sljit_set_label(item.jump, jit.procLabels[item.procName])

  result = sljit_generate_code(jit.compiler, 0, nil)
  sljit_free_compiler(jit.compiler)

proc compileOSRToNative*(instructions: seq[IRInstruction], stringPool: seq[string], targetLoopId: int, maxRegs = 1024): pointer =
  var jit = initJitCompiler()
  jit.compiler = sljit_create_compiler(nil)
  if jit.compiler == nil:
    raise newException(ValueError, "SLJIT Error: Failed to create compiler.")

  var heapHeaders: ptr UncheckedArray[NimStringHeader] = nil
  if stringPool.len > 0:
    heapHeaders = cast[ptr UncheckedArray[NimStringHeader]](alloc0(sizeof(NimStringHeader) * stringPool.len))
    for idx, s in stringPool:
      heapHeaders[idx] = createNimString(s)

  var vregTypes = initTable[int, DataType]()
  for inst in instructions:
    if inst.dst.id > 0: vregTypes[inst.dst.id] = inst.dst.dataType
    if inst.src1.id > 0: vregTypes[inst.src1.id] = inst.src1.dataType
    if inst.src2.id > 0: vregTypes[inst.src2.id] = inst.src2.dataType

  jit.regAlloc = allocateRegisters(instructions, maxIntRegs = 7, maxFloatRegs = 4)

  let localSize = int32(jit.regAlloc.spillStackSize + 128)
  let enterFlags = SLJIT_ENTER_FLOAT(4)
  # OSR signature: accepts pointer vmFrame in SLJIT_R0 (SLJIT_ARG_TYPE_P_R) and returns exit PC (SLJIT_ARG_TYPE_W)
  discard sljit_emit_enter(jit.compiler, 0, SLJIT_ARGS1(SLJIT_ARG_TYPE_W, SLJIT_ARG_TYPE_P_R), 6 or enterFlags, 6, localSize)

  # Save vmFrame pointer from SLJIT_R0 into stack slot vmFrameSlot
  let vmFrameSlot = jit.regAlloc.spillStackSize + 16
  discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_MEM1(SLJIT_SP), vmFrameSlot, SLJIT_R0, 0)

  # Find OSR target label for targetLoopId and loop end label
  var targetLabelIdx = -1
  var endLabelIdx = -1
  for idx, inst in instructions:
    if inst.op == opJumpBack and inst.loopId == targetLoopId:
      targetLabelIdx = inst.labelIdx
      if idx + 1 < instructions.len and instructions[idx + 1].op == opLabel:
        endLabelIdx = instructions[idx + 1].labelIdx
      break

  # Prologue: Read live-in virtual variables from vmFrame into JIT registers / stack slots
  for vregId in 1..<maxRegs:
    if jit.regAlloc.locations.hasKey(vregId):
      let dt = vregTypes.getOrDefault(vregId, dtInt64)
      let vreg = VirtualReg(id: vregId, dataType: dt)
      let offset = vregId * sizeof(VMValue)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, SLJIT_MEM1(SLJIT_SP), vmFrameSlot)
      if dt == dtFloat64:
        discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, SLJIT_FR0, 0, SLJIT_MEM1(SLJIT_R0), offset)
        jit.writeBack(vreg, SLJIT_FR0)
      else:
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, SLJIT_MEM1(SLJIT_R0), offset)
        jit.writeBack(vreg, SLJIT_R1)

  if targetLabelIdx > 0:
    let osrJmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
    jit.jumpsToResolve.add((jump: osrJmp, targetLabelIdx: targetLabelIdx))

  # OSR Epilogue Label
  let epilogueLabelIdx = 999999

  for inst in instructions:
    case inst.op
    of opProcEntry:
      let lbl = sljit_emit_label(jit.compiler)
      jit.procLabels[inst.procName] = lbl
      discard sljit_emit_op_dst(jit.compiler, SLJIT_FAST_ENTER, SLJIT_S3, 0)
      let procReturnSlot = jit.regAlloc.spillStackSize + 32
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_MEM1(SLJIT_SP), procReturnSlot, SLJIT_S3, 0)

    of opProcExit:
      let procReturnSlot = jit.regAlloc.spillStackSize + 32
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_S3, 0, SLJIT_MEM1(SLJIT_SP), procReturnSlot)
      discard sljit_emit_op_src(jit.compiler, SLJIT_FAST_RETURN, SLJIT_S3, 0)

    of opCall:
      let callJmp = sljit_emit_jump(jit.compiler, SLJIT_FAST_CALL)
      jit.procJumps.add((jump: callJmp, procName: inst.procName))

    of opLabel:
      let lbl = sljit_emit_label(jit.compiler)
      jit.labels[inst.labelIdx] = lbl

      # Upon reaching endLabelIdx at loop exit, jump directly to OSR epilogue
      if inst.labelIdx == endLabelIdx and endLabelIdx > 0:
        let exitJmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
        jit.jumpsToResolve.add((jump: exitJmp, targetLabelIdx: epilogueLabelIdx))

    of opLoadIntConst:
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R0)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_IMM, inst.intImm)
      jit.writeBack(inst.dst, dstReg)

    of opLoadFloatConst:
      let dstFReg = jit.getRegOrLoad(inst.dst, SLJIT_FR0)
      discard sljit_emit_fset64(jit.compiler, dstFReg, inst.floatImm)
      jit.writeBack(inst.dst, dstFReg)

    of opLoadStrConst:
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R0)
      let strHeaderPtr = addr heapHeaders[inst.strIndex]
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_IMM, cast[int](strHeaderPtr))
      jit.writeBack(inst.dst, dstReg)

    of opLoadVar, opStoreVar:
      if inst.src1.id > 0:
        if inst.dst.dataType == dtFloat64:
          let srcReg = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
          let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_FR1)
          discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, dstReg, 0, srcReg, 0)
          jit.writeBack(inst.dst, dstReg)
        else:
          let srcReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
          let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R1)
          discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, srcReg, 0)
          jit.writeBack(inst.dst, dstReg)

    of opAdd:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_ADD_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_ADD, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opSub:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_SUB_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_SUB, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opMul:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_MUL_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op2(jit.compiler, SLJIT_MUL, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)

    of opDiv:
      if inst.dst.dataType == dtFloat64:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_FR2)
        discard sljit_emit_fop2(jit.compiler, SLJIT_DIV_F64, dst, 0, s1, 0, s2, 0)
        jit.writeBack(inst.dst, dst)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        if s1 != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, s1, 0)
        if s2 != SLJIT_R1: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, s2, 0)
        discard sljit_emit_op0(jit.compiler, SLJIT_DIV_SW)
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_R0, 0)
        jit.writeBack(inst.dst, dst)

    of opShl:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R1)
      discard sljit_emit_op2(jit.compiler, SLJIT_SHL, dst, 0, s1, 0, SLJIT_IMM, inst.shiftAmount)
      jit.writeBack(inst.dst, dst)

    of opAshr:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R1)
      discard sljit_emit_op2(jit.compiler, SLJIT_ASHR, dst, 0, s1, 0, SLJIT_IMM, inst.shiftAmount)
      jit.writeBack(inst.dst, dst)

    of opConcatStr:
      let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
      if s1 != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, s1, 0)
      if s2 != SLJIT_R1: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, s2, 0)
      let concatFnAddr = cast[int](nim_str_concat)
      discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS2(SLJIT_ARG_TYPE_P, SLJIT_ARG_TYPE_P, SLJIT_ARG_TYPE_P), SLJIT_IMM, concatFnAddr)
      let dstReg = jit.getRegOrLoad(inst.dst, SLJIT_R2)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dstReg, 0, SLJIT_RETURN_REG, 0)
      jit.writeBack(inst.dst, dstReg)

    of opCmpEq, opCmpNeq, opCmpLt, opCmpLe, opCmpGt, opCmpGe:
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)

      var trueLbl: SljitJump
      if isFloat:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        var fcond: int32
        case inst.op
        of opCmpEq: fcond = SLJIT_F_EQUAL
        of opCmpNeq: fcond = SLJIT_F_NOT_EQUAL
        of opCmpLt: fcond = SLJIT_F_LESS
        of opCmpLe: fcond = SLJIT_F_LESS_EQUAL
        of opCmpGt: fcond = SLJIT_F_GREATER
        of opCmpGe: fcond = SLJIT_F_GREATER_EQUAL
        else: fcond = SLJIT_F_EQUAL
        trueLbl = sljit_emit_fcmp(jit.compiler, fcond, s1, 0, s2, 0)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        var icond: int32
        case inst.op
        of opCmpEq: icond = SLJIT_EQUAL
        of opCmpNeq: icond = SLJIT_NOT_EQUAL
        of opCmpLt: icond = SLJIT_SIG_LESS
        of opCmpLe: icond = SLJIT_SIG_LESS_EQUAL
        of opCmpGt: icond = SLJIT_SIG_GREATER
        of opCmpGe: icond = SLJIT_SIG_GREATER_EQUAL
        else: icond = SLJIT_EQUAL
        trueLbl = sljit_emit_cmp(jit.compiler, icond, s1, 0, s2, 0)

      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_IMM, 0)
      let endJmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)

      let lbl = sljit_emit_label(jit.compiler)
      sljit_set_label(trueLbl, lbl)
      discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_IMM, 1)

      let endLbl = sljit_emit_label(jit.compiler)
      sljit_set_label(endJmp, endLbl)

      jit.writeBack(inst.dst, dst)

    of opJumpCmp:
      # Phase 6: Direct 1-instruction branch condition fusion
      let isFloat = (inst.src1.dataType == dtFloat64 or inst.src2.dataType == dtFloat64)
      var jmp: SljitJump
      if isFloat:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_FR1)
        var fcond: int32
        case inst.cmpOp
        of opCmpEq:  fcond = if inst.jumpIfZero: SLJIT_F_NOT_EQUAL else: SLJIT_F_EQUAL
        of opCmpNeq: fcond = if inst.jumpIfZero: SLJIT_F_EQUAL else: SLJIT_F_NOT_EQUAL
        of opCmpLt:  fcond = if inst.jumpIfZero: SLJIT_F_GREATER_EQUAL else: SLJIT_F_LESS
        of opCmpLe:  fcond = if inst.jumpIfZero: SLJIT_F_GREATER else: SLJIT_F_LESS_EQUAL
        of opCmpGt:  fcond = if inst.jumpIfZero: SLJIT_F_LESS_EQUAL else: SLJIT_F_GREATER
        of opCmpGe:  fcond = if inst.jumpIfZero: SLJIT_F_LESS else: SLJIT_F_GREATER_EQUAL
        else: fcond = SLJIT_F_EQUAL
        jmp = sljit_emit_fcmp(jit.compiler, fcond, s1, 0, s2, 0)
      else:
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        var icond: int32
        case inst.cmpOp
        of opCmpEq:  icond = if inst.jumpIfZero: SLJIT_NOT_EQUAL else: SLJIT_EQUAL
        of opCmpNeq: icond = if inst.jumpIfZero: SLJIT_EQUAL else: SLJIT_NOT_EQUAL
        of opCmpLt:  icond = if inst.jumpIfZero: SLJIT_SIG_GREATER_EQUAL else: SLJIT_SIG_LESS
        of opCmpLe:  icond = if inst.jumpIfZero: SLJIT_SIG_GREATER else: SLJIT_SIG_LESS_EQUAL
        of opCmpGt:  icond = if inst.jumpIfZero: SLJIT_SIG_LESS_EQUAL else: SLJIT_SIG_GREATER
        of opCmpGe:  icond = if inst.jumpIfZero: SLJIT_SIG_LESS else: SLJIT_SIG_GREATER_EQUAL
        else: icond = SLJIT_EQUAL
        jmp = sljit_emit_cmp(jit.compiler, icond, s1, 0, s2, 0)

      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJump:
      let jmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpIfZero:
      let condReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let jmp = sljit_emit_cmp(jit.compiler, SLJIT_EQUAL, condReg, 0, SLJIT_IMM, 0)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpIfNotZero:
      let condReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
      let jmp = sljit_emit_cmp(jit.compiler, SLJIT_NOT_EQUAL, condReg, 0, SLJIT_IMM, 0)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opJumpBack:
      let jmp = sljit_emit_jump(jit.compiler, SLJIT_JUMP_TYPE)
      jit.jumpsToResolve.add((jump: jmp, targetLabelIdx: inst.labelIdx))

    of opPrint:
      case inst.printType
      of dtInt64:
        let valReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        if valReg != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, valReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_W), SLJIT_IMM, cast[int](nim_int_print))
      of dtFloat64:
        let valFReg = jit.getRegOrLoad(inst.src1, SLJIT_FR0)
        if valFReg != SLJIT_FR0: discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, SLJIT_FR0, 0, valFReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_F64), SLJIT_IMM, cast[int](nim_float_print))
      of dtString:
        let valReg = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        if valReg != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, valReg, 0)
        discard sljit_emit_icall(jit.compiler, SLJIT_CALL, SLJIT_ARGS1V(SLJIT_ARG_TYPE_P), SLJIT_IMM, cast[int](nim_str_print))
      else:
        discard

    of opReturn:
      let retReg = jit.getRegOrLoad(inst.src1, SLJIT_RETURN_REG)
      if retReg != SLJIT_RETURN_REG:
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0, retReg, 0)
      discard sljit_emit_return(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0)

  # OSR Epilogue
  let epilogueLbl = sljit_emit_label(jit.compiler)
  jit.labels[epilogueLabelIdx] = epilogueLbl

  # Epilogue: Flush all modified live-out hardware registers back to vmFrame (vmFrameReg)
  discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, SLJIT_MEM1(SLJIT_SP), vmFrameSlot)
  for vregId in 1..<maxRegs:
    if jit.regAlloc.locations.hasKey(vregId):
      let dt = vregTypes.getOrDefault(vregId, dtInt64)
      let vreg = VirtualReg(id: vregId, dataType: dt)
      let offset = vregId * sizeof(VMValue)
      if dt == dtFloat64:
        let valFReg = jit.getRegOrLoad(vreg, SLJIT_FR0)
        discard sljit_emit_fop1(jit.compiler, SLJIT_MOV_F64, SLJIT_MEM1(SLJIT_R0), offset, valFReg, 0)
      else:
        let valReg = jit.getRegOrLoad(vreg, SLJIT_R1)
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_MEM1(SLJIT_R0), offset, valReg, 0)

  # Return exit interpreter label PC index
  let exitPC = if endLabelIdx > 0: endLabelIdx else: 0
  discard sljit_emit_return(jit.compiler, SLJIT_MOV, SLJIT_IMM, exitPC)

  for item in jit.jumpsToResolve:
    if jit.labels.hasKey(item.targetLabelIdx):
      sljit_set_label(item.jump, jit.labels[item.targetLabelIdx])

  for item in jit.procJumps:
    if jit.procLabels.hasKey(item.procName):
      sljit_set_label(item.jump, jit.procLabels[item.procName])

  result = sljit_generate_code(jit.compiler, 0, nil)
  sljit_free_compiler(jit.compiler)
