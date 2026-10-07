import os

const sljitDir = currentSourcePath() / "../../sljit_src"
{.passC: "-I" & sljitDir.}
{.compile: sljitDir / "sljitLir.c".}

type
  SljitCompilerObj {.importc: "struct sljit_compiler", header: "sljitLir.h".} = object
  SljitCompiler* = ptr SljitCompilerObj

  SljitLabelObj {.importc: "struct sljit_label", header: "sljitLir.h".} = object
  SljitLabel* = ptr SljitLabelObj

  SljitJumpObj {.importc: "struct sljit_jump", header: "sljitLir.h".} = object
  SljitJump* = ptr SljitJumpObj

# Register Constants (C macro wrappers via importc header sljitLir.h)
var
  SLJIT_R0* {.importc: "SLJIT_R0", header: "sljitLir.h".}: int32
  SLJIT_R1* {.importc: "SLJIT_R1", header: "sljitLir.h".}: int32
  SLJIT_R2* {.importc: "SLJIT_R2", header: "sljitLir.h".}: int32
  SLJIT_R3* {.importc: "SLJIT_R3", header: "sljitLir.h".}: int32
  SLJIT_R4* {.importc: "SLJIT_R4", header: "sljitLir.h".}: int32
  SLJIT_R5* {.importc: "SLJIT_R5", header: "sljitLir.h".}: int32
  SLJIT_R6* {.importc: "SLJIT_R6", header: "sljitLir.h".}: int32
  SLJIT_R7* {.importc: "SLJIT_R7", header: "sljitLir.h".}: int32

  SLJIT_S0* {.importc: "SLJIT_S0", header: "sljitLir.h".}: int32
  SLJIT_S1* {.importc: "SLJIT_S1", header: "sljitLir.h".}: int32
  SLJIT_S2* {.importc: "SLJIT_S2", header: "sljitLir.h".}: int32
  SLJIT_S3* {.importc: "SLJIT_S3", header: "sljitLir.h".}: int32
  SLJIT_S4* {.importc: "SLJIT_S4", header: "sljitLir.h".}: int32
  SLJIT_S5* {.importc: "SLJIT_S5", header: "sljitLir.h".}: int32

  SLJIT_SP* {.importc: "SLJIT_SP", header: "sljitLir.h".}: int32
  SLJIT_RETURN_REG* {.importc: "SLJIT_RETURN_REG", header: "sljitLir.h".}: int32

  SLJIT_FR0* {.importc: "SLJIT_FR0", header: "sljitLir.h".}: int32
  SLJIT_FR1* {.importc: "SLJIT_FR1", header: "sljitLir.h".}: int32
  SLJIT_FR2* {.importc: "SLJIT_FR2", header: "sljitLir.h".}: int32
  SLJIT_FR3* {.importc: "SLJIT_FR3", header: "sljitLir.h".}: int32
  SLJIT_FR4* {.importc: "SLJIT_FR4", header: "sljitLir.h".}: int32
  SLJIT_FR5* {.importc: "SLJIT_FR5", header: "sljitLir.h".}: int32
  SLJIT_FR6* {.importc: "SLJIT_FR6", header: "sljitLir.h".}: int32
  SLJIT_FR7* {.importc: "SLJIT_FR7", header: "sljitLir.h".}: int32
  SLJIT_RETURN_FREG* {.importc: "SLJIT_RETURN_FREG", header: "sljitLir.h".}: int32

# Operand type flags and helper funcs
const
  SLJIT_MEM* = int32(0x80)
  SLJIT_IMM* = int32(0x7f)

template SLJIT_MEM1*(r1: int32): int32 =
  int32(SLJIT_MEM or r1)

template SLJIT_MEM2*(r1: int32, r2: int32): int32 =
  int32(SLJIT_MEM or r1 or (r2 shl 8))

# Modifiers & Flags
const
  SLJIT_32* = int32(0x100)
  SLJIT_SET_Z* = int32(0x0200)

# Operations (op0, op1, op2)
const
  SLJIT_NOP* = int32(1)
  SLJIT_DIV_UW* = int32(6)
  SLJIT_DIV_SW* = int32(7)

  SLJIT_FAST_RETURN* = int32(112)
  SLJIT_FAST_ENTER* = int32(118)

  SLJIT_MOV* = int32(32)
  SLJIT_MOV_U8* = int32(33)
  SLJIT_MOV_S8* = int32(34)
  SLJIT_MOV_U16* = int32(35)
  SLJIT_MOV_S16* = int32(36)
  SLJIT_MOV_U32* = int32(37)
  SLJIT_MOV_S32* = int32(38)
  SLJIT_MOV32* = int32(39)
  SLJIT_MOV_P* = int32(40)

  SLJIT_ADD* = int32(64)
  SLJIT_SUB* = int32(66)
  SLJIT_MUL* = int32(68)
  SLJIT_AND* = int32(69)
  SLJIT_OR*  = int32(70)
  SLJIT_XOR* = int32(71)
  SLJIT_SHL* = int32(72)
  SLJIT_LSHR* = int32(74)
  SLJIT_ASHR* = int32(76)

# Floating point ops
const
  SLJIT_MOV_F64* = int32(144)
  SLJIT_MOV_F32* = int32(144 or SLJIT_32)
  SLJIT_CONV_F64_FROM_SW* = int32(148)
  SLJIT_CONV_SW_FROM_F64* = int32(146)
  SLJIT_CMP_F64* = int32(152)
  SLJIT_NEG_F64* = int32(153)
  SLJIT_ABS_F64* = int32(154)

  SLJIT_ADD_F64* = int32(176)
  SLJIT_SUB_F64* = int32(177)
  SLJIT_MUL_F64* = int32(178)
  SLJIT_DIV_F64* = int32(179)

# Comparison & Jump Conditions
const
  SLJIT_EQUAL* = int32(0)
  SLJIT_NOT_EQUAL* = int32(1)
  SLJIT_LESS* = int32(2)
  SLJIT_GREATER_EQUAL* = int32(3)
  SLJIT_GREATER* = int32(4)
  SLJIT_LESS_EQUAL* = int32(5)
  SLJIT_SIG_LESS* = int32(6)
  SLJIT_SIG_GREATER_EQUAL* = int32(7)
  SLJIT_SIG_GREATER* = int32(8)
  SLJIT_SIG_LESS_EQUAL* = int32(9)

  SLJIT_F_EQUAL* = int32(16)
  SLJIT_F_NOT_EQUAL* = int32(17)
  SLJIT_F_LESS* = int32(18)
  SLJIT_F_GREATER_EQUAL* = int32(19)
  SLJIT_F_GREATER* = int32(20)
  SLJIT_F_LESS_EQUAL* = int32(21)

  SLJIT_JUMP_TYPE* = int32(36)
  SLJIT_FAST_CALL* = int32(37)
  SLJIT_CALL* = int32(38)
  SLJIT_CALL_REG_ARG* = int32(39)

# Argument Type Definitions
const
  SLJIT_ARG_TYPE_SCRATCH_REG* = int32(0x8)
  SLJIT_ARG_TYPE_RET_VOID* = int32(0)
  SLJIT_ARG_TYPE_W* = int32(1)
  SLJIT_ARG_TYPE_W_R* = SLJIT_ARG_TYPE_W or SLJIT_ARG_TYPE_SCRATCH_REG
  SLJIT_ARG_TYPE_32* = int32(2)
  SLJIT_ARG_TYPE_32_R* = SLJIT_ARG_TYPE_32 or SLJIT_ARG_TYPE_SCRATCH_REG
  SLJIT_ARG_TYPE_P* = int32(3)
  SLJIT_ARG_TYPE_P_R* = SLJIT_ARG_TYPE_P or SLJIT_ARG_TYPE_SCRATCH_REG
  SLJIT_ARG_TYPE_F64* = int32(4)
  SLJIT_ARG_TYPE_F32* = int32(5)

  SLJIT_ARG_SHIFT = 4

template SLJIT_ARG_RETURN*(t: int32): int32 = t
template SLJIT_ARG_VALUE*(t: int32, idx: int32): int32 = (t shl (idx * SLJIT_ARG_SHIFT))

template SLJIT_ARGS0*(ret: int32): int32 = SLJIT_ARG_RETURN(ret)
template SLJIT_ARGS0V*(): int32 = SLJIT_ARG_RETURN(SLJIT_ARG_TYPE_RET_VOID)

template SLJIT_ARGS1*(ret, a1: int32): int32 = SLJIT_ARGS0(ret) or SLJIT_ARG_VALUE(a1, 1)
template SLJIT_ARGS1V*(a1: int32): int32 = SLJIT_ARGS0V() or SLJIT_ARG_VALUE(a1, 1)

template SLJIT_ARGS2*(ret, a1, a2: int32): int32 = SLJIT_ARGS1(ret, a1) or SLJIT_ARG_VALUE(a2, 2)
template SLJIT_ARGS2V*(a1, a2: int32): int32 = SLJIT_ARGS1V(a1) or SLJIT_ARG_VALUE(a2, 2)

template SLJIT_ARGS3*(ret, a1, a2, a3: int32): int32 = SLJIT_ARGS2(ret, a1, a2) or SLJIT_ARG_VALUE(a3, 3)
template SLJIT_ARGS3V*(a1, a2, a3: int32): int32 = SLJIT_ARGS2V(a1, a2) or SLJIT_ARG_VALUE(a3, 3)

template SLJIT_ENTER_FLOAT*(regs: int32): int32 = regs shl 8

# Foreign Function Declarations
proc sljit_create_compiler*(allocator_data: pointer): SljitCompiler {.importc: "sljit_create_compiler", header: "sljitLir.h".}
proc sljit_free_compiler*(compiler: SljitCompiler) {.importc: "sljit_free_compiler", header: "sljitLir.h".}
proc sljit_generate_code*(compiler: SljitCompiler, options: int32, exec_allocator_data: pointer): pointer {.importc: "sljit_generate_code", header: "sljitLir.h".}
proc sljit_free_code*(code: pointer, exec_allocator_data: pointer) {.importc: "sljit_free_code", header: "sljitLir.h".}
proc sljit_get_compiler_error*(compiler: SljitCompiler): int32 {.importc: "sljit_get_compiler_error", header: "sljitLir.h".}

proc sljit_emit_enter*(compiler: SljitCompiler, options: int32, arg_types: int32, scratches: int32, saveds: int32, local_size: int32): int32 {.importc: "sljit_emit_enter", header: "sljitLir.h".}
proc sljit_emit_return_void*(compiler: SljitCompiler): int32 {.importc: "sljit_emit_return_void", header: "sljitLir.h".}
proc sljit_emit_return*(compiler: SljitCompiler, op: int32, src: int32, srcw: int): int32 {.importc: "sljit_emit_return", header: "sljitLir.h".}

proc sljit_emit_op0*(compiler: SljitCompiler, op: int32): int32 {.importc: "sljit_emit_op0", header: "sljitLir.h".}
proc sljit_emit_op1*(compiler: SljitCompiler, op: int32, dst: int32, dstw: int, src: int32, srcw: int): int32 {.importc: "sljit_emit_op1", header: "sljitLir.h".}
proc sljit_emit_op2*(compiler: SljitCompiler, op: int32, dst: int32, dstw: int, src1: int32, src1w: int, src2: int32, src2w: int): int32 {.importc: "sljit_emit_op2", header: "sljitLir.h".}

proc sljit_emit_fop1*(compiler: SljitCompiler, op: int32, dst: int32, dstw: int, src: int32, srcw: int): int32 {.importc: "sljit_emit_fop1", header: "sljitLir.h".}
proc sljit_emit_fop2*(compiler: SljitCompiler, op: int32, dst: int32, dstw: int, src1: int32, src1w: int, src2: int32, src2w: int): int32 {.importc: "sljit_emit_fop2", header: "sljitLir.h".}

proc sljit_emit_fset32*(compiler: SljitCompiler, freg: int32, value: float32): int32 {.importc: "sljit_emit_fset32", header: "sljitLir.h".}
proc sljit_emit_fset64*(compiler: SljitCompiler, freg: int32, value: float64): int32 {.importc: "sljit_emit_fset64", header: "sljitLir.h".}

proc sljit_emit_fmem*(compiler: SljitCompiler, typeVal: int32, freg: int32, mem: int32, memw: int): int32 {.importc: "sljit_emit_fmem", header: "sljitLir.h".}

proc sljit_emit_label*(compiler: SljitCompiler): SljitLabel {.importc: "sljit_emit_label", header: "sljitLir.h".}
proc sljit_emit_jump*(compiler: SljitCompiler, typeVal: int32): SljitJump {.importc: "sljit_emit_jump", header: "sljitLir.h".}
proc sljit_emit_cmp*(compiler: SljitCompiler, typeVal: int32, src1: int32, src1w: int, src2: int32, src2w: int): SljitJump {.importc: "sljit_emit_cmp", header: "sljitLir.h".}
proc sljit_emit_fcmp*(compiler: SljitCompiler, typeVal: int32, src1: int32, src1w: int, src2: int32, src2w: int): SljitJump {.importc: "sljit_emit_fcmp", header: "sljitLir.h".}
proc sljit_set_label*(jump: SljitJump, label: SljitLabel) {.importc: "sljit_set_label", header: "sljitLir.h".}

proc sljit_emit_call*(compiler: SljitCompiler, typeVal: int32, arg_types: int32): SljitJump {.importc: "sljit_emit_call", header: "sljitLir.h".}
proc sljit_emit_ijump*(compiler: SljitCompiler, typeVal: int32, src: int32, srcw: int): int32 {.importc: "sljit_emit_ijump", header: "sljitLir.h".}
proc sljit_emit_icall*(compiler: SljitCompiler, typeVal: int32, arg_types: int32, src: int32, srcw: int): int32 {.importc: "sljit_emit_icall", header: "sljitLir.h".}

proc sljit_emit_op_dst*(compiler: SljitCompiler, op: int32, dst: int32, dstw: int): int32 {.importc: "sljit_emit_op_dst", header: "sljitLir.h".}
proc sljit_emit_op_src*(compiler: SljitCompiler, op: int32, src: int32, srcw: int): int32 {.importc: "sljit_emit_op_src", header: "sljitLir.h".}

proc sljit_get_local_base*(compiler: SljitCompiler, dst: int32, dstw: int, offset: int): int32 {.importc: "sljit_get_local_base", header: "sljitLir.h".}
