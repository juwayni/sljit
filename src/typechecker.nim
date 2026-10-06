import std/tables
import ast

type
  SymbolInfo* = object
    dataType*: DataType
    isProc*: bool
    procParams*: seq[DataType]
    procRetType*: DataType

  SymbolTable* = object
    scopes*: seq[Table[string, SymbolInfo]]

  TypeChecker* = object
    symbols*: SymbolTable
    stringPool*: seq[string]

proc initTypeChecker*(): TypeChecker =
  TypeChecker(
    symbols: SymbolTable(scopes: @[initTable[string, SymbolInfo]()]),
    stringPool: @[]
  )

proc enterScope*(tc: var TypeChecker) =
  tc.symbols.scopes.add(initTable[string, SymbolInfo]())

proc exitScope*(tc: var TypeChecker) =
  if tc.symbols.scopes.len > 1:
    discard tc.symbols.scopes.pop()

proc declareSymbol*(tc: var TypeChecker, name: string, info: SymbolInfo) =
  let idx = tc.symbols.scopes.len - 1
  if tc.symbols.scopes[idx].hasKey(name):
    raise newException(ValueError, "Compile Error: Redeclaration of symbol '" & name & "' in same scope.")
  tc.symbols.scopes[idx][name] = info

proc lookupSymbol*(tc: TypeChecker, name: string): SymbolInfo =
  for i in countdown(tc.symbols.scopes.len - 1, 0):
    if tc.symbols.scopes[i].hasKey(name):
      return tc.symbols.scopes[i][name]
  raise newException(ValueError, "Compile Error: Undeclared symbol '" & name & "'.")

proc addStringLiteral*(tc: var TypeChecker, strVal: string): int =
  for idx, s in tc.stringPool:
    if s == strVal:
      return idx
  result = tc.stringPool.len
  tc.stringPool.add(strVal)

proc checkExpr*(tc: var TypeChecker, node: AstNode): DataType
proc checkStmt*(tc: var TypeChecker, node: AstNode)

proc checkExpr*(tc: var TypeChecker, node: AstNode): DataType =
  if node == nil: return dtVoid

  case node.kind
  of nkIntLit:
    node.evalType = dtInt64
    return dtInt64

  of nkFloatLit:
    node.evalType = dtFloat64
    return dtFloat64

  of nkStringLit:
    node.strIndex = tc.addStringLiteral(node.strVal)
    node.evalType = dtString
    return dtString

  of nkVarRef:
    let sym = tc.lookupSymbol(node.varName)
    node.evalType = sym.dataType
    return sym.dataType

  of nkBinaryOp:
    let leftType = tc.checkExpr(node.left)
    let rightType = tc.checkExpr(node.right)

    if node.op in ["+", "-", "*", "/"]:
      if leftType == dtInt64 and rightType == dtInt64:
        node.evalType = dtInt64
        return dtInt64
      elif leftType == dtFloat64 and rightType == dtFloat64:
        node.evalType = dtFloat64
        return dtFloat64
      elif node.op == "+" and leftType == dtString and rightType == dtString:
        node.evalType = dtString
        return dtString
      else:
        raise newException(ValueError, "Compile Error: Type mismatch for arithmetic operator '" & node.op & "': got " & $leftType & " and " & $rightType)

    elif node.op in ["==", "!=", "<", "<=", ">", ">="]:
      if (leftType == rightType) and leftType in {dtInt64, dtFloat64, dtString}:
        node.evalType = dtInt64 # Booleans represented as int64 (1 or 0)
        return dtInt64
      else:
        raise newException(ValueError, "Compile Error: Type mismatch for comparison operator '" & node.op & "': got " & $leftType & " and " & $rightType)

    else:
      raise newException(ValueError, "Compile Error: Unknown binary operator '" & node.op & "'")

  of nkCall:
    let sym = tc.lookupSymbol(node.fnName)
    if not sym.isProc:
      raise newException(ValueError, "Compile Error: '" & node.fnName & "' is not a callable procedure.")
    if node.args.len != sym.procParams.len:
      raise newException(ValueError, "Compile Error: Procedure '" & node.fnName & "' expects " & $sym.procParams.len & " arguments, got " & $node.args.len)
    for i in 0..<node.args.len:
      let argType = tc.checkExpr(node.args[i])
      if argType != sym.procParams[i]:
        raise newException(ValueError, "Compile Error: Argument " & $(i+1) & " to procedure '" & node.fnName & "' expects " & $sym.procParams[i] & ", got " & $argType)
    node.evalType = sym.procRetType
    return sym.procRetType

  else:
    raise newException(ValueError, "Compile Error: Node kind " & $node.kind & " is not an expression.")

proc checkStmt*(tc: var TypeChecker, node: AstNode) =
  if node == nil: return

  case node.kind
  of nkVarDecl:
    if node.initExpr != nil:
      let initType = tc.checkExpr(node.initExpr)
      if initType != node.declaredType:
        raise newException(ValueError, "Compile Error: Cannot initialize variable '" & node.declName & "' of type " & $node.declaredType & " with expression of type " & $initType)
    tc.declareSymbol(node.declName, SymbolInfo(dataType: node.declaredType, isProc: false))

  of nkAssign:
    let sym = tc.lookupSymbol(node.targetName)
    let valType = tc.checkExpr(node.valExpr)
    if valType != sym.dataType:
      raise newException(ValueError, "Compile Error: Cannot assign expression of type " & $valType & " to variable '" & node.targetName & "' of type " & $sym.dataType)

  of nkIf:
    let condType = tc.checkExpr(node.cond)
    if condType != dtInt64:
      raise newException(ValueError, "Compile Error: 'if' condition must evaluate to int64, got " & $condType)
    tc.enterScope()
    tc.checkStmt(node.thenBlock)
    tc.exitScope()
    if node.elseBlock != nil:
      tc.enterScope()
      tc.checkStmt(node.elseBlock)
      tc.exitScope()

  of nkWhile:
    let condType = tc.checkExpr(node.whileCond)
    if condType != dtInt64:
      raise newException(ValueError, "Compile Error: 'while' condition must evaluate to int64, got " & $condType)
    tc.enterScope()
    tc.checkStmt(node.whileBody)
    tc.exitScope()

  of nkFor:
    let startType = tc.checkExpr(node.forStart)
    let endType = tc.checkExpr(node.forEnd)
    if startType != dtInt64 or endType != dtInt64:
      raise newException(ValueError, "Compile Error: 'for' loop bounds must evaluate to int64.")
    tc.enterScope()
    tc.declareSymbol(node.forVar, SymbolInfo(dataType: dtInt64, isProc: false))
    tc.checkStmt(node.forBody)
    tc.exitScope()

  of nkProcDecl:
    var paramTypes: seq[DataType] = @[]
    for p in node.procParams:
      paramTypes.add(p.paramType)
    tc.declareSymbol(node.procName, SymbolInfo(
      dataType: dtVoid,
      isProc: true,
      procParams: paramTypes,
      procRetType: node.procReturnType
    ))
    tc.enterScope()
    for p in node.procParams:
      tc.declareSymbol(p.name, SymbolInfo(dataType: p.paramType, isProc: false))
    tc.checkStmt(node.procBody)
    tc.exitScope()

  of nkBlock:
    tc.enterScope()
    for stmt in node.stmts:
      tc.checkStmt(stmt)
    tc.exitScope()

  of nkExprStmt:
    discard tc.checkExpr(node.expr)

  of nkPrint:
    let t = tc.checkExpr(node.expr)
    if t notin {dtInt64, dtFloat64, dtString}:
      raise newException(ValueError, "Compile Error: Cannot print expression of type " & $t)

  else:
    discard tc.checkExpr(node)
