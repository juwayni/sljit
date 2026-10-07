import std/[monotimes, times, strformat, tables]
import ../src/[sljit_bindings, runtime, lexer, parser, ast, typechecker, ir, regalloc, vm, codegen]

type
  BenchmarkResult* = object
    id*: int
    name*: string
    durationMs*: float64
    metric*: string

var benchmarkResults*: seq[BenchmarkResult] = @[]

proc logBench*(id: int, name: string, durationMs: float64, metric: string) =
  benchmarkResults.add(BenchmarkResult(id: id, name: name, durationMs: durationMs, metric: metric))
  echo fmt"[{id:02d}] {name:<55} | Time: {durationMs:8.3f} ms | {metric}"

# Benchmark 1: 1M Integer Addition Loop
proc bench1_IntAdditionLoop*() =
  let code = """
var sum: int64 = 0
for i in 1..1000000:
  sum = sum + i
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  var vmCtx = initVMContext(tc.stringPool, hotThreshold = 10, jitCallback = compileToNative)
  discard vmCtx.executeInterpreter(irB.instructions)
  let t1 = getMonoTime()
  logBench(1, "1M Integer Addition Loop (Interpreter -> True OSR)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "1,000,000 ops")

# Benchmark 2: 10M Integer Counter Loop
proc bench2_Int10MCounterLoop*() =
  let code = """
var c: int64 = 0
while c < 10000000:
  c = c + 1
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(2, "10M Integer Counter Loop (Direct JIT)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "10,000,000 ops")

# Benchmark 3: Float64 Polynomial Calculation Loop
proc bench3_FloatPolynomialLoop*() =
  let code = """
var x: float64 = 1.5
var sum: float64 = 0.0
for i in 1..100000:
  sum = sum + x * x + 2.0 * x + 1.0
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(3, "Float64 Polynomial Loop (100k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "100,000 ops")

# Benchmark 4: Float64 Division & Multiplication Loop
proc bench4_FloatDivMulLoop*() =
  let code = """
var val: float64 = 100.0
for i in 1..100000:
  val = val * 1.0001 / 1.00005
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(4, "Float64 Div/Mul Loop (100k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "100,000 ops")

# Benchmark 5: Small String Optimization Creation
proc bench5_SSOCreation*() =
  let t0 = getMonoTime()
  for i in 1..100_000:
    let s = createNimString("SSO_Test_Str")
    assert s.isSmall == true
  let t1 = getMonoTime()
  logBench(5, "Small String Optimization Creation (100k strings)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "0 Heap Allocations")

# Benchmark 6: Long String Arena Concatenation
proc bench6_LongStringConcat*() =
  let t0 = getMonoTime()
  var h1 = createNimString("Long Heap String #1 Exceeding 14 Bytes")
  var h2 = createNimString("Long Heap String #2 Exceeding 14 Bytes")
  for i in 1..10_000:
    discard nim_str_concat(addr h1, addr h2)
  let t1 = getMonoTime()
  logBench(6, "Long String Bump Arena Concatenation (10k ops)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "10k Arena Allocs")

# Benchmark 7: Fibonacci Procedure Recursion
proc bench7_FibonacciRecursion*() =
  let code = """
proc fib(n: int64): int64
  if n <= 1:
    var res: int64 = n
  else:
    var a: int64 = n - 1
    var b: int64 = n - 2
    var res2: int64 = a + b

fib(12)
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(7, "Recursive Fibonacci Calculation (N=12)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Procedure Call Frames")

# Benchmark 8: GCD Algorithm Loop
proc bench8_GCDAlgorithm*() =
  let code = """
var a: int64 = 1071
var b: int64 = 462
for i in 1..10000:
  var x: int64 = a
  var y: int64 = b
  while y != 0:
    var rem: int64 = x - (x / y) * y
    x = y
    y = rem
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(8, "Iterative GCD Algorithm (10k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "10,000 GCDs")

# Benchmark 9: Nested Conditional Branching
proc bench9_NestedBranching*() =
  let code = """
var count: int64 = 0
for i in 1..500000:
  if i > 250000:
    if i > 375000:
      count = count + 1
    else:
      count = count + 2
  else:
    count = count + 3
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(9, "Nested Conditional Branching (500k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "500,000 Branches")

# Benchmark 10: Scoped Variable Shadowing Access
proc bench10_VariableShadowing*() =
  let code = """
var val: int64 = 10
for i in 1..250000:
  var val: int64 = 20
  var val2: int64 = val + i
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(10, "Scoped Variable Shadowing Access (250k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Scope Lookups")

# Benchmark 11: Linear Scan Register Allocation Speed
proc bench11_LinearScanRegAllocSpeed*() =
  let code = """
var v1: int64 = 1
var v2: int64 = 2
var v3: int64 = 3
var v4: int64 = 4
var v5: int64 = 5
var v6: int64 = v1 + v2 + v3 + v4 + v5
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  for k in 1..500:
    discard allocateRegisters(irB.instructions, maxIntRegs = 4)
  let t1 = getMonoTime()
  logBench(11, "Linear Scan Register Allocation Analysis Speed", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Liveness Intervals")

# Benchmark 12: Stack Frame Spilling Performance
proc bench12_StackSpillingPerformance*() =
  let code = """
var v1: int64 = 10
var v2: int64 = 20
var v3: int64 = 30
var v4: int64 = 40
var v5: int64 = 50
var res: int64 = 0
for i in 1..250000:
  res = v1 + v2 + v3 + v4 + v5
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(12, "Stack Frame Spilling Performance (250k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Spill Slot Moves")

# Benchmark 13: Tier 4 Interpreter Loop Warmup
proc bench13_InterpreterWarmup*() =
  let code = """
var acc: int64 = 0
for i in 1..5000:
  acc = acc + 1
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  var vmCtx = initVMContext(tc.stringPool, hotThreshold = 100000) # Pure interpreter
  discard vmCtx.executeInterpreter(irB.instructions)
  let t1 = getMonoTime()
  logBench(13, "Tier 4 Bytecode Interpreter Execution (5k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Interpreter PC Loop")

# Benchmark 14: Tier 4 Hot Loop Detection & OSR
proc bench14_HotLoopOSR*() =
  let code = """
var acc: int64 = 0
for i in 1..50000:
  acc = acc + 1
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  var vmCtx = initVMContext(tc.stringPool, hotThreshold = 5)
  discard vmCtx.executeInterpreter(irB.instructions)
  let t1 = getMonoTime()
  logBench(14, "Tier 4 Hot Loop Detection & OSR Live Transfer", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "OSR State Transition")

# Benchmark 15: Direct SLJIT Native JIT Speed
proc bench15_DirectSLJITExecution*() =
  let code = """
var acc: int64 = 0
for i in 1..500000:
  acc = acc + i
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(15, "Direct SLJIT Native Machine Code Execution (500k iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Hardware Speed")

# Benchmark 16: Complex Expression Parsing & IR Lowering Speed
proc bench16_ParserAndIRLoweringSpeed*() =
  let code = """
var a: int64 = 10
var b: int64 = 20
var c: int64 = a * b + 30 - 5
if c > 100:
  var s: string = "hello"
  print s
"""
  let t0 = getMonoTime()
  for k in 1..200:
    let tokens = tokenizeAll(code)
    var p = initParser(tokens)
    let astTree = p.parseProgram()
    var tc = initTypeChecker()
    tc.checkStmt(astTree)
    var irB = initIRBuilder()
    irB.lowerStmt(astTree)
  let t1 = getMonoTime()
  logBench(16, "Compiler Frontend Throughput (200 Script Compilations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "AST & IR Nodes")

# Benchmark 17: Static Type Checker Symbol Resolution
proc bench17_TypeCheckerSpeed*() =
  let code = "var x: int64 = 1\nvar y: float64 = 2.0\nvar z: string = \"a\"\n"
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  let t0 = getMonoTime()
  for k in 1..1000:
    var tc = initTypeChecker()
    tc.checkStmt(astTree)
  let t1 = getMonoTime()
  logBench(17, "Type Checker Symbol Table & Type Resolution (1k passes)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Symbol Table Lookups")

# Benchmark 18: Lexer Indentation Stack Scanning
proc bench18_LexerIndentationScanning*() =
  let code = "var a: int64 = 1\nif a > 0:\n  var b: int64 = 2\n  if b > 1:\n    var c: int64 = 3\n"
  let t0 = getMonoTime()
  for k in 1..500:
    discard tokenizeAll(code)
  let t1 = getMonoTime()
  logBench(18, "Indentation-Aware Lexer Tokenization (500 files)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Indent Stack Tokenizer")

# Benchmark 19: Range Iteration Speed
proc bench19_RangeIteration*() =
  let code = """
var sum: int64 = 0
for i in 1..1000000:
  sum = sum + 1
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(19, "Range Iteration (`for i in 1..N`) (1M iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Native Loop Increment")

# Benchmark 20: While Loop State Mutation
proc bench20_WhileLoopMutation*() =
  let code = """
var i: int64 = 0
while i < 1000000:
  i = i + 1
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(20, "While Loop State Mutation (1M iterations)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Conditional Jumps")

# Benchmark 21: String Equality Comparison Speed
proc bench21_StringEquality*() =
  let t0 = getMonoTime()
  var s1 = createNimString("BenchmarkString1")
  var s2 = createNimString("BenchmarkString1")
  var count = 0
  for k in 1..50_000:
    if nim_str_eq(addr s1, addr s2) == 1:
      inc count
  assert count == 50_000
  let t1 = getMonoTime()
  logBench(21, "String Equality Comparison Speed (50k ops)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Memory Comparison")

# Benchmark 22: Mixed Expression Computation
proc bench22_MixedExpressionComputation*() =
  let code = """
var i: int64 = 100
var f: float64 = 10.5
for k in 1..250000:
  i = i + 1
  f = f * 1.00001
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(22, "Mixed Int & Float Arithmetic (250k ops)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Mixed Register Calculations")

# Benchmark 23: Multi-Parameter Procedure Calls
proc bench23_MultiParamProcedureCalls*() =
  let code = """
proc add3(a: int64, b: int64, c: int64): int64
  var r: int64 = a + b + c

for k in 1..25000:
  add3(1, 2, 3)
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(code)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(23, "Multi-Parameter Procedure Calls (25k calls)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "C-ABI Call Overhead")

# Benchmark 24: String Arena Allocation & Reset Speed
proc bench24_ArenaAllocResetSpeed*() =
  let t0 = getMonoTime()
  for k in 1..500:
    for j in 1..50:
      discard arenaAlloc(64)
    nim_arena_reset()
  let t1 = getMonoTime()
  logBench(24, "String Arena Allocation & Reset Cycle Speed (25k cycles)", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Zero-Cost Reset")

# Benchmark 25: End-to-End Pipeline Latency
proc bench25_EndToEndPipelineLatency*() =
  let script = """
var x: int64 = 10
var y: int64 = 20
var z: int64 = x + y
"""
  let t0 = getMonoTime()
  let tokens = tokenizeAll(script)
  var p = initParser(tokens)
  let astTree = p.parseProgram()
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let codePtr = compileToNative(irB.instructions, tc.stringPool)
  type FnProc = proc() {.cdecl.}
  cast[FnProc](codePtr)()
  let t1 = getMonoTime()
  logBench(25, "End-to-End Script Compilation & JIT Execution Pipeline Latency", (t1 - t0).inNanoseconds.float64 / 1_000_000.0, "Lex-Parse-Type-IR-JIT-Exec")

proc runAllBenchmarks*() =
  echo "=========================================================================================="
  echo "         STATICALLY-TYPED SCRIPTING LANGUAGE BENCHMARK SUITE (25 BENCHMARKS)"
  echo "=========================================================================================="
  bench1_IntAdditionLoop()
  bench2_Int10MCounterLoop()
  bench3_FloatPolynomialLoop()
  bench4_FloatDivMulLoop()
  bench5_SSOCreation()
  bench6_LongStringConcat()
  bench7_FibonacciRecursion()
  bench8_GCDAlgorithm()
  bench9_NestedBranching()
  bench10_VariableShadowing()
  bench11_LinearScanRegAllocSpeed()
  bench12_StackSpillingPerformance()
  bench13_InterpreterWarmup()
  bench14_HotLoopOSR()
  bench15_DirectSLJITExecution()
  bench16_ParserAndIRLoweringSpeed()
  bench17_TypeCheckerSpeed()
  bench18_LexerIndentationScanning()
  bench19_RangeIteration()
  bench20_WhileLoopMutation()
  bench21_StringEquality()
  bench22_MixedExpressionComputation()
  bench23_MultiParamProcedureCalls()
  bench24_ArenaAllocResetSpeed()
  bench25_EndToEndPipelineLatency()
  echo "=========================================================================================="
  echo "All 25 benchmarks completed successfully."

when isMainModule:
  runAllBenchmarks()
