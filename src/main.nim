import std/os
import sljit_bindings, lexer, parser, typechecker, ir, optimizer, vm, codegen

proc runCode*(code: string, hotThreshold = 10, forceJit = false) =
  echo "=================================================="
  echo "--- Lexing & Tokenization ---"
  let tokens = tokenizeAll(code)
  echo "Generated ", tokens.len, " tokens."

  echo "--- Parsing AST ---"
  var pObj = initParser(tokens)
  let astTree = pObj.parseProgram()

  echo "--- Static Type Checking & Symbol Resolution ---"
  var tc = initTypeChecker()
  tc.checkStmt(astTree)
  echo "Static string pool size: ", tc.stringPool.len

  echo "--- IR Lowering & SSA Middle-End Optimization ---"
  var irB = initIRBuilder()
  irB.lowerStmt(astTree)
  let optInstructions = optimizeIR(irB.instructions)
  echo "Generated ", irB.instructions.len, " raw IR insts -> ", optInstructions.len, " SSA-optimized IR insts."

  if forceJit:
    echo "--- Direct SLJIT Native Compilation & Execution ---"
    let codePtr = compileToNative(optInstructions, tc.stringPool)
    type NativeProc = proc() {.cdecl.}
    let fn = cast[NativeProc](codePtr)
    fn()
  else:
    echo "--- Tiered VM Execution (Interpreter -> Hot Loop OSR JIT) ---"
    var vmCtx = initVMContext(tc.stringPool, hotThreshold = hotThreshold, jitCallback = compileToNative)
    discard vmCtx.executeInterpreter(optInstructions)
  echo "=================================================="

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and fileExists(args[0]):
    let fileCode = readFile(args[0])
    runCode(fileCode)
  else:
    let sampleProgram = """
var sum: int64 = 0
for i in 1..25:
  var inv: int64 = 10 * 2
  sum = sum + i + inv
print sum

var greeting: string = "Language Engine: "
var target: string = "Statically Typed + SSA Optimizer + SLJIT JIT!"
var msg: string = greeting + target
print msg
"""
    echo "Executing Sample Statically-Typed Nim-like Language Program:"
    runCode(sampleProgram, hotThreshold = 5)
