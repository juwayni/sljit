type
  DataType* = enum
    dtUnknown,
    dtVoid,
    dtInt64,
    dtFloat64,
    dtString

  NodeKind* = enum
    # Expressions
    nkIntLit,
    nkFloatLit,
    nkStringLit,
    nkVarRef,
    nkBinaryOp,
    nkCall,

    # Statements
    nkVarDecl,
    nkAssign,
    nkIf,
    nkWhile,
    nkFor,
    nkProcDecl,
    nkBlock,
    nkExprStmt,
    nkPrint

  AstNode* = ref object
    evalType*: DataType
    case kind*: NodeKind
    of nkIntLit:
      intVal*: int64
    of nkFloatLit:
      floatVal*: float64
    of nkStringLit:
      strVal*: string
      strIndex*: int # Index in static string literal table
    of nkVarRef:
      varName*: string
    of nkBinaryOp:
      op*: string
      left*: AstNode
      right*: AstNode
    of nkCall:
      fnName*: string
      args*: seq[AstNode]
    of nkVarDecl:
      declName*: string
      declaredType*: DataType
      initExpr*: AstNode
    of nkAssign:
      targetName*: string
      valExpr*: AstNode
    of nkIf:
      cond*: AstNode
      thenBlock*: AstNode
      elseBlock*: AstNode
    of nkWhile:
      whileCond*: AstNode
      whileBody*: AstNode
    of nkFor:
      forVar*: string
      forStart*: AstNode
      forEnd*: AstNode
      forBody*: AstNode
    of nkProcDecl:
      procName*: string
      procParams*: seq[tuple[name: string, paramType: DataType]]
      procReturnType*: DataType
      procBody*: AstNode
    of nkBlock:
      stmts*: seq[AstNode]
    of nkExprStmt, nkPrint:
      expr*: AstNode

proc `$`*(dt: DataType): string =
  case dt
  of dtUnknown: "unknown"
  of dtVoid: "void"
  of dtInt64: "int64"
  of dtFloat64: "float64"
  of dtString: "string"
