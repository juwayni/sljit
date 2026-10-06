import std/tables
import ../src/[sljit_bindings, runtime, lexer, parser, typechecker, ir, regalloc, vm, codegen]

proc testFullPipeline() =
  echo "[Test 1] Arithmetic and Variable Assignment"
  let code1 = """
var a: int64 = 15
var b: int64 = 25
var c: int64 = a * b + 10
print c
"""
  let tokens1 = tokenizeAll(code1)
  var p1 = initParser(tokens1)
  let ast1 = p1.parseProgram()
  var tc1 = initTypeChecker()
  tc1.checkStmt(ast1)
  var ir1 = initIRBuilder()
  ir1.lowerStmt(ast1)
  let codePtr1 = compileToNative(ir1.instructions, tc1.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr1)()

proc testFloatOperations() =
  echo "[Test 2] Float64 Arithmetic and Comparisons"
  let code2 = """
var x: float64 = 2.5
var y: float64 = 4.0
var z: float64 = x * y + 1.5
print z
if x < y:
  print 100
"""
  let tokens2 = tokenizeAll(code2)
  var p2 = initParser(tokens2)
  let ast2 = p2.parseProgram()
  var tc2 = initTypeChecker()
  tc2.checkStmt(ast2)
  var ir2 = initIRBuilder()
  ir2.lowerStmt(ast2)
  let codePtr2 = compileToNative(ir2.instructions, tc2.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr2)()

proc testStringArchitecture() =
  echo "[Test 3] Native 16-Byte String Descriptor Operations"
  let code3 = """
var s1: string = "Nim + "
var s2: string = "SLJIT JIT = "
var s3: string = "Pure Speed!"
var full: string = s1 + s2 + s3
print full
"""
  let tokens3 = tokenizeAll(code3)
  var p3 = initParser(tokens3)
  let ast3 = p3.parseProgram()
  var tc3 = initTypeChecker()
  tc3.checkStmt(ast3)
  var ir3 = initIRBuilder()
  ir3.lowerStmt(ast3)
  let codePtr3 = compileToNative(ir3.instructions, tc3.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr3)()

proc testHotLoopOSR() =
  echo "[Test 4] Tiered VM Interpreter & True OSR JIT Loop Execution"
  let code4 = """
var total: int64 = 0
for i in 1..20:
  total = total + i
print total
"""
  let tokens4 = tokenizeAll(code4)
  var p4 = initParser(tokens4)
  let ast4 = p4.parseProgram()
  var tc4 = initTypeChecker()
  tc4.checkStmt(ast4)
  var ir4 = initIRBuilder()
  ir4.lowerStmt(ast4)

  var vmCtx = initVMContext(tc4.stringPool, hotThreshold = 5)
  discard vmCtx.executeInterpreter(ir4.instructions)
  assert len(vmCtx.loopCounters) > 0

proc testRegisterSpilling() =
  echo "[Test 5] Linear Scan Register Allocator Stack Spilling"
  let code5 = """
var v1: int64 = 1
var v2: int64 = 2
var v3: int64 = 3
var v4: int64 = 4
var v5: int64 = 5
var v6: int64 = v1 + v2 + v3 + v4 + v5
print v6
"""
  let tokens5 = tokenizeAll(code5)
  var p5 = initParser(tokens5)
  let ast5 = p5.parseProgram()
  var tc5 = initTypeChecker()
  tc5.checkStmt(ast5)
  var ir5 = initIRBuilder()
  ir5.lowerStmt(ast5)

  let ra = allocateRegisters(ir5.instructions, maxIntRegs = 2)
  assert ra.spillStackSize > 0
  echo "Spill stack size verified: ", ra.spillStackSize

  let codePtr5 = compileToNative(ir5.instructions, tc5.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr5)()

proc testProcedureCalls() =
  echo "[Test 6] Procedure Declarations and Procedure Calls"
  let code6 = """
proc calc(a: int64, b: int64): int64
  var v: int64 = a * b + 10
  print v

calc(5, 4)
"""
  let tokens6 = tokenizeAll(code6)
  var p6 = initParser(tokens6)
  let ast6 = p6.parseProgram()
  var tc6 = initTypeChecker()
  tc6.checkStmt(ast6)
  var ir6 = initIRBuilder()
  ir6.lowerStmt(ast6)
  let codePtr6 = compileToNative(ir6.instructions, tc6.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr6)()

proc testVariableShadowing() =
  echo "[Test 7] Scoped Variable Shadowing"
  let code7 = """
var val: int64 = 100
if val > 50:
  var val: int64 = 200
  print val
print val
"""
  let tokens7 = tokenizeAll(code7)
  var p7 = initParser(tokens7)
  let ast7 = p7.parseProgram()
  var tc7 = initTypeChecker()
  tc7.checkStmt(ast7)
  var ir7 = initIRBuilder()
  ir7.lowerStmt(ast7)
  let codePtr7 = compileToNative(ir7.instructions, tc7.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr7)()

proc testStringArenaReset() =
  echo "[Test 8] String Arena Memory Cleanup"
  let before = globalStringAllocations.len
  var s1 = createNimString("Hello ")
  var s2 = createNimString("Arena")
  discard nim_str_concat(addr s1, addr s2)
  assert globalStringAllocations.len > before
  nim_arena_reset()
  assert globalStringAllocations.len == 0
  echo "String Arena reset verified!"

when isMainModule:
  echo "=================================================="
  echo "Running Comprehensive Compiler Pipeline Tests..."
  echo "=================================================="
  testFullPipeline()
  testFloatOperations()
  testStringArchitecture()
  testHotLoopOSR()
  testRegisterSpilling()
  testProcedureCalls()
  testVariableShadowing()
  testStringArenaReset()
  echo "=================================================="
  echo "ALL COMPILER PIPELINE TESTS PASSED SUCCESSFULLY!"
  echo "=================================================="
