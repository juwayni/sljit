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
    opReturn

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
    args*: seq[VirtualReg]
    printType*: DataType

  IRBuilder* = object
    instructions*: seq[IRInstruction]
    nextVRegId*: int
    nextLabelId*: int
    nextLoopId*: int
    varToVReg*: Table[string, VirtualReg]

proc initIRBuilder*(): IRBuilder =
  IRBuilder(
    instructions: @[],
    nextVRegId: 1,
    nextLabelId: 1,
    nextLoopId: 1,
    varToVReg: initTable[string, VirtualReg]()
  )

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
    if ir.varToVReg.hasKey(node.varName):
      return ir.varToVReg[node.varName]
    else:
      let dst = ir.newVReg(node.evalType)
      ir.varToVReg[node.varName] = dst
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
    ir.emit(IRInstruction(op: opCall, dst: dst, varName: node.fnName, args: argVRegs))
    return dst

  else:
    raise newException(ValueError, "Cannot lower node to IR expression: " & $node.kind)

proc lowerStmt*(ir: var IRBuilder, node: AstNode) =
  if node == nil: return

  case node.kind
  of nkVarDecl:
    let vreg = ir.newVReg(node.declaredType)
    ir.varToVReg[node.declName] = vreg
    if node.initExpr != nil:
      let initVReg = ir.lowerExpr(node.initExpr)
      ir.emit(IRInstruction(op: opStoreVar, dst: vreg, src1: initVReg, varName: node.declName))

  of nkAssign:
    let valVReg = ir.lowerExpr(node.valExpr)
    var targetVReg: VirtualReg
    if ir.varToVReg.hasKey(node.targetName):
      targetVReg = ir.varToVReg[node.targetName]
    else:
      targetVReg = ir.newVReg(node.valExpr.evalType)
      ir.varToVReg[node.targetName] = targetVReg
    ir.emit(IRInstruction(op: opStoreVar, dst: targetVReg, src1: valVReg, varName: node.targetName))

  of nkIf:
    let condVReg = ir.lowerExpr(node.cond)
    let elseLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: elseLabel))
    ir.lowerStmt(node.thenBlock)
    ir.emit(IRInstruction(op: opJump, labelIdx: endLabel))

    ir.emit(IRInstruction(op: opLabel, labelIdx: elseLabel))
    if node.elseBlock != nil:
      ir.lowerStmt(node.elseBlock)

    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))

  of nkWhile:
    let loopId = ir.newLoopId()
    let startLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    ir.emit(IRInstruction(op: opLabel, labelIdx: startLabel))
    let condVReg = ir.lowerExpr(node.whileCond)
    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: endLabel))

    ir.lowerStmt(node.whileBody)
    ir.emit(IRInstruction(op: opJumpBack, labelIdx: startLabel, loopId: loopId))

    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))

  of nkFor:
    let loopId = ir.newLoopId()
    let startLabel = ir.newLabel()
    let endLabel = ir.newLabel()

    let iterVReg = ir.newVReg(dtInt64)
    ir.varToVReg[node.forVar] = iterVReg

    let startVReg = ir.lowerExpr(node.forStart)
    let endVReg = ir.lowerExpr(node.forEnd)

    ir.emit(IRInstruction(op: opStoreVar, dst: iterVReg, src1: startVReg, varName: node.forVar))

    ir.emit(IRInstruction(op: opLabel, labelIdx: startLabel))

    # Condition: iterVReg <= endVReg
    let condVReg = ir.newVReg(dtInt64)
    ir.emit(IRInstruction(op: opCmpLe, dst: condVReg, src1: iterVReg, src2: endVReg))
    ir.emit(IRInstruction(op: opJumpIfZero, src1: condVReg, labelIdx: endLabel))

    ir.lowerStmt(node.forBody)

    # Increment iterVReg by 1
    let oneVReg = ir.newVReg(dtInt64)
    ir.emit(IRInstruction(op: opLoadIntConst, dst: oneVReg, intImm: 1))
    ir.emit(IRInstruction(op: opAdd, dst: iterVReg, src1: iterVReg, src2: oneVReg))

    ir.emit(IRInstruction(op: opJumpBack, labelIdx: startLabel, loopId: loopId))
    ir.emit(IRInstruction(op: opLabel, labelIdx: endLabel))

  of nkBlock:
    for stmt in node.stmts:
      ir.lowerStmt(stmt)

  of nkPrint:
    let valVReg = ir.lowerExpr(node.expr)
    ir.emit(IRInstruction(op: opPrint, src1: valVReg, printType: node.expr.evalType))

  of nkExprStmt:
    discard ir.lowerExpr(node.expr)

  else:
    discard
