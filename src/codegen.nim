import std/tables
import sljit_bindings, runtime, ir, regalloc, ast

type
  JitCompiler* = object
    compiler*: SljitCompiler
    labels*: Table[int, SljitLabel]
    jumpsToResolve*: seq[tuple[jump: SljitJump, targetLabelIdx: int]]
    regAlloc*: RegAllocResult

proc initJitCompiler*(): JitCompiler =
  JitCompiler(
    compiler: nil,
    labels: initTable[int, SljitLabel](),
    jumpsToResolve: @[],
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

  # Perform Linear Scan Register Allocation
  jit.regAlloc = allocateRegisters(instructions, maxIntRegs = 4, maxFloatRegs = 4)

  # Function Entry Prologue: 4 scratches, 4 saveds, 4 float scratches
  let localSize = int32(jit.regAlloc.spillStackSize + 64) # extra stack buffer for C-ABI call spilling
  let enterFlags = SLJIT_ENTER_FLOAT(4)
  discard sljit_emit_enter(jit.compiler, 0, SLJIT_ARGS0V(), 4 or enterFlags, 4, localSize)

  for inst in instructions:
    case inst.op
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
        # Integer division: Load dividend into SLJIT_R0 and divisor into SLJIT_R1
        let s1 = jit.getRegOrLoad(inst.src1, SLJIT_R0)
        let s2 = jit.getRegOrLoad(inst.src2, SLJIT_R1)
        if s1 != SLJIT_R0: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R0, 0, s1, 0)
        if s2 != SLJIT_R1: discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_R1, 0, s2, 0)
        discard sljit_emit_op0(jit.compiler, SLJIT_DIV_SW) # SLJIT_R0 = SLJIT_R0 div SLJIT_R1
        let dst = jit.getRegOrLoad(inst.dst, SLJIT_R2)
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, dst, 0, SLJIT_R0, 0)
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

    of opCall:
      discard

    of opReturn:
      let retReg = jit.getRegOrLoad(inst.src1, SLJIT_RETURN_REG)
      if retReg != SLJIT_RETURN_REG:
        discard sljit_emit_op1(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0, retReg, 0)
      discard sljit_emit_return(jit.compiler, SLJIT_MOV, SLJIT_RETURN_REG, 0)

  # Default Return
  discard sljit_emit_return_void(jit.compiler)

  # Resolve Jump Targets to Labels
  for item in jit.jumpsToResolve:
    if jit.labels.hasKey(item.targetLabelIdx):
      sljit_set_label(item.jump, jit.labels[item.targetLabelIdx])

  result = sljit_generate_code(jit.compiler, 0, nil)
  sljit_free_compiler(jit.compiler)
