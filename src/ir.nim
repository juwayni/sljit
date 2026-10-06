import std/tables
import ast

type
  VRegId* = int

  VirtualReg* = object
    id*: VRegId
    dataType*: DataType

  IROpcode* = enum
    opLoadIntConst,
    opLoadFloatConst,
    opLoadStrConst,
    opLoadVar,
    opStoreVar,
    opAdd,
    opSub,
    opMul,
    opDiv,
    opConcatStr,
    opCmpEq,
    opCmpNeq,
    opCmpLt,
    opCmpLe,
    opCmpGt,
    opCmpGe,
    opJump,
    opJumpIfZero,
    opJumpIfNotZero,
    opJumpBack,
    opLabel,
    opPrint,
    opCall,
    opReturn,
    opProcEntry,
    opProcExit

  IRInstruction* = object
    op*: IROpcode
    dst*: VirtualReg
    src1*: VirtualReg
    src2*: VirtualReg
    intImm*: int64
    floatImm*: float64
    strImm*: string
    strIndex*: int
    varName*: string
    labelIdx*: int
    loopId*: int
    procName*: string
    args*: seq[VirtualReg]
    printType*: DataType

  IRBuilder* = object
    instructions*: seq[IRInstruction]
    nextVRegId*: int
    nextLabelId*: int
    nextLoopId*: int
    scopes*: seq[Table[string, VirtualReg]]
    procEntryPoints*: Table[string, int] # Proc name -> label index

proc initIRBuilder*(): IRBuilder =
  IRBuilder(
    instructions: @[],
    nextVRegId: 1,
    nextLabelId: 1,
    nextLoopId: 1,
    scopes: @[initTable[string, VirtualReg]()],
    procEntryPoints: initTable[string, int]()
  )

proc enterScope*(ir: var IRBuilder) =
  ir.scopes.add(initTable[string, VirtualReg]())

proc exitScope*(ir: var IRBuilder) =
  if ir.scopes.len > 1:
    discard ir.scopes.pop()

proc declareVar*(ir: var IRBuilder, name: string, vreg: VirtualReg) =
  let lastIdx = ir.scopes.len - 1
  ir.scopes[lastIdx][name] = vreg

proc lookupVar*(ir: IRBuilder, name: string): tuple[found: bool, vreg: VirtualReg] =
  for i in countdown(ir.scopes.len - 1, 0):
    if ir.scopes[i].hasKey(name):
      return (true, ir.scopes[i][name])
  return (false, VirtualReg())

proc newVReg*(ir: var IRBuilder, dt: DataType): VirtualReg =
  result = VirtualReg(id: ir.nextVRegId, dataType: dt)
  inc ir.nextVRegId

proc newLabel*(ir: var IRBuilder): int =
  result = ir.nextLabelId
  inc ir.nextLabelId

proc newLoopId*(ir: var IRBuilder): int =
  result = ir.nextLoopId
  inc ir.nextLoopId

proc emit*(ir: var IRBuilder, inst: IRInstruction) =
  ir.instructions.add(inst)

proc lowerExpr*(ir: var IRBuilder, node: AstNode): VirtualReg
proc lowerStmt*(ir: var IRBuilder, node: AstNode)

proc lowerExpr*(ir: var IRBuilder, node: AstNode): VirtualReg =
  case node.kind
  of nkIntLit:
    let dst = ir.newVReg(dtInt64)
    ir.emit(IRInstruction(op: opLoadIntConst, dst: dst, intImm: node.intVal))
    return dst

  of nkFloatLit:
    let dst = ir.newVReg(dtFloat64)
    ir.emit(IRInstruction(op: opLoadFloatConst, dst: dst, floatImm: node.floatVal))
    return dst

  of nkStringLit:
    let dst = ir.newVReg(dtString)
    ir.emit(IRInstruction(op: opLoadStrConst, dst: dst, strImm: node.strVal, strIndex: node.strIndex))
    return dst

  of nkVarRef:
    let (found, vreg) = ir.lookupVar(node.varName)
    if found:
      return vreg
    else:
      let dst = ir.newVReg(node.evalType)
      ir.declareVar(node.varName, dst)
      ir.emit(IRInstruction(op: opLoadVar, dst: dst, varName: node.varName))
      return dst

  of nkBinaryOp:
    let leftVReg = ir.lowerExpr(node.left)
    let rightVReg = ir.lowerExpr(node.right)
    let dst = ir.newVReg(node.evalType)

    var opc: IROpcode
    case node.op
    of "+":
      opc = if node.evalType == dtString: opConcatStr else: opAdd
    of "-": opc = opSub
    of "*": opc = opMul
    of "/": opc = opDiv
    of "==": opc = opCmpEq
    of "!=": opc = opCmpNeq
    of "<":  opc = opCmpLt
    of "<=": opc = opCmpLe
    of ">":  opc = opCmpGt
    of ">=": opc = opCmpGe
    else:
      raise newException(ValueError, "Unsupported binary operator in IR generation: " & node.op)

    ir.emit(IRInstruction(op: opc, dst: dst, src1: leftVReg, src2: rightVReg))
    return dst

  of nkCall:
    var argVRegs: seq[VirtualReg] = @[]
    for arg in node.args:
      argVRegs.add(ir.lowerExpr(arg))
    let dst = ir.newVReg(node.evalType)
    ir.emit(IRInstruction(op: opCall, dst: dst, procName: node.fnName, args: argVRegs))
    return dst

  else:
    raise newException(ValueError, "Cannot lower node to IR expression: " & $node.kind)

proc lowerStmt*(ir: var IRBuilder, node: AstNode) =
  if node == nil: return

  case node.kind
  of nkVarDecl:
    let vreg = ir.newVReg(node.declaredType)
    ir.declareVar(node.declName, vreg)
    if node.initExpr != nil:
      let initVReg = ir.lowerExpr(node.initExpr)
      ir.emit(IRInstruction(op: opStoreVar, dst: vreg, src1: initVReg, varName: node.declName))

  of nkAssign:
    let valVReg = ir.lowerExpr(node.valExpr)
    let (found, existingVReg) = ir.lookupVar(node.targetName)
    var targetVReg: VirtualReg
    if found:
      targetVReg = existingVReg
    else:
      targetVReg = ir.newVReg(node.valExpr.evalType)
      ir.declareVar(node.targetName, targetVReg)
    ir.emit(IRInstruction(op: opStoreVar, dst: targetVReg, src1: valVReg, varName: node.targetName))

  of nkIf:
    let condVReg = ir.lowerExpr(node.cond)
    let elseLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: elseLabel))
    ir.enterScope()
    ir.lowerStmt(node.thenBlock)
    ir.exitScope()
    ir.emit(IRInstruction(op: opJump, labelIdx: endLabel))

    ir.emit(IRInstruction(op: opLabel, labelIdx: elseLabel))
    if node.elseBlock != nil:
      ir.enterScope()
      ir.lowerStmt(node.elseBlock)
      ir.exitScope()

    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))

  of nkWhile:
    let loopId = ir.newLoopId()
    let startLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    ir.emit(IRInstruction(op: opLabel, labelIdx: startLabel))
    let condVReg = ir.lowerExpr(node.whileCond)
    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: endLabel))

    ir.enterScope()
    ir.lowerStmt(node.whileBody)
    ir.exitScope()
    ir.emit(IRInstruction(op: opJumpBack, labelIdx: startLabel, loopId: loopId))

    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))

  of nkFor:
    let loopId = ir.newLoopId()
    let startLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    ir.enterScope()
    let iterVReg = ir.newVReg(dtInt64)
    ir.declareVar(node.forVar, iterVReg)

    let startVReg = ir.lowerExpr(node.forStart)
    let endVReg = ir.lowerExpr(node.forEnd)

    ir.emit(IRInstruction(op: opStoreVar, dst: iterVReg, src1: startVReg, varName: node.forVar))

    ir.emit(IRInstruction(op: opLabel, labelIdx: startLabel))

    let condVReg = ir.newVReg(dtInt64)
    ir.emit(IRInstruction(op: opCmpLe, dst: condVReg, src1: iterVReg, src2: endVReg))
    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: endLabel))

    ir.lowerStmt(node.forBody)

    let oneVReg = ir.newVReg(dtInt64)
    ir.emit(IRInstruction(op: opLoadIntConst, dst: oneVReg, intImm: 1))
    ir.emit(IRInstruction(op: opAdd, dst: iterVReg, src1: iterVReg, src2: oneVReg))

    ir.emit(IRInstruction(op: opJumpBack, labelIdx: startLabel, loopId: loopId))
    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))
    ir.exitScope()

  of nkProcDecl:
    let entryLabel = ir.newLabel()
    let skipLabel = ir.newLabel()

    ir.procEntryPoints[node.procName] = entryLabel

    # Skip procedure body during top-level linear execution flow
    ir.emit(IRInstruction(op: opJump, labelIdx: skipLabel))

    ir.emit(IRInstruction(op: opLabel, labelIdx: entryLabel))
    ir.emit(IRInstruction(op: opProcEntry, procName: node.procName))

    ir.enterScope()
    var paramVRegs: seq[VirtualReg] = @[]
    for p in node.procParams:
      let pvreg = ir.newVReg(p.paramType)
      ir.declareVar(p.name, pvreg)
      paramVRegs.add(pvreg)

    ir.lowerStmt(node.procBody)
    ir.exitScope()

    ir.emit(IRInstruction(op: opProcExit, procName: node.procName))
    ir.emit(IRInstruction(op: opLabel, labelIdx: skipLabel))

  of nkBlock:
    ir.enterScope()
    for stmt in node.stmts:
      ir.lowerStmt(stmt)
    ir.exitScope()

  of nkPrint:
    let valVReg = ir.lowerExpr(node.expr)
    ir.emit(IRInstruction(op: opPrint, src1: valVReg, printType: node.expr.evalType))

  of nkExprStmt:
    discard ir.lowerExpr(node.expr)

  else:
    discard
