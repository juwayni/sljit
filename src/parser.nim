import lexer, ast

type
  Parser* = object
    tokens*: seq[Token]
    pos*: int

proc initParser*(tokens: seq[Token]): Parser =
  Parser(tokens: tokens, pos: 0)

proc peek(p: Parser, offset = 0): Token =
  let idx = p.pos + offset
  if idx >= p.tokens.len:
    Token(kind: tkEof, val: "EOF")
  else:
    p.tokens[idx]

proc advance(p: var Parser): Token =
  if p.pos < p.tokens.len:
    result = p.tokens[p.pos]
    inc p.pos
  else:
    result = Token(kind: tkEof, val: "EOF")

proc match(p: var Parser, kind: TokenKind): bool =
  if p.peek().kind == kind:
    discard p.advance()
    return true
  return false

proc expect(p: var Parser, kind: TokenKind, msg: string): Token =
  if p.peek().kind == kind:
    return p.advance()
  raise newException(ValueError, "Parse Error at line " & $p.peek().line & ": " & msg & ", got " & $p.peek().kind & " (" & p.peek().val & ")")

proc skipNewLines(p: var Parser) =
  while p.peek().kind == tkNewLine:
    discard p.advance()

proc parseExpr(p: var Parser): AstNode

proc parsePrimary(p: var Parser): AstNode =
  let tok = p.peek()
  case tok.kind
  of tkIntLit:
    discard p.advance()
    return AstNode(kind: nkIntLit, intVal: tok.intVal, evalType: dtInt64)
  of tkFloatLit:
    discard p.advance()
    return AstNode(kind: nkFloatLit, floatVal: tok.floatVal, evalType: dtFloat64)
  of tkStringLit:
    discard p.advance()
    return AstNode(kind: nkStringLit, strVal: tok.val, strIndex: -1, evalType: dtString)
  of tkIdent:
    let idTok = p.advance()
    if p.peek().kind == tkLParen:
      # Function call
      discard p.advance() # '('
      var args: seq[AstNode] = @[]
      if p.peek().kind != tkRParen:
        args.add(p.parseExpr())
        while p.match(tkComma):
          args.add(p.parseExpr())
      discard p.expect(tkRParen, "Expected ')' after argument list")
      return AstNode(kind: nkCall, fnName: idTok.val, args: args, evalType: dtUnknown)
    else:
      return AstNode(kind: nkVarRef, varName: idTok.val, evalType: dtUnknown)
  of tkLParen:
    discard p.advance()
    let expr = p.parseExpr()
    discard p.expect(tkRParen, "Expected ')' after expression")
    return expr
  else:
    raise newException(ValueError, "Unexpected token in expression at line " & $tok.line & ": " & $tok.kind & " (" & tok.val & ")")

proc parseMulDiv(p: var Parser): AstNode =
  var left = p.parsePrimary()
  while p.peek().kind in {tkStar, tkSlash}:
    let opTok = p.advance()
    let right = p.parsePrimary()
    left = AstNode(kind: nkBinaryOp, op: opTok.val, left: left, right: right, evalType: dtUnknown)
  return left

proc parseAddSub(p: var Parser): AstNode =
  var left = p.parseMulDiv()
  while p.peek().kind in {tkPlus, tkMinus}:
    let opTok = p.advance()
    let right = p.parseMulDiv()
    left = AstNode(kind: nkBinaryOp, op: opTok.val, left: left, right: right, evalType: dtUnknown)
  return left

proc parseCompare(p: var Parser): AstNode =
  var left = p.parseAddSub()
  while p.peek().kind in {tkEq, tkNeq, tkLt, tkLe, tkGt, tkGe}:
    let opTok = p.advance()
    let right = p.parseAddSub()
    left = AstNode(kind: nkBinaryOp, op: opTok.val, left: left, right: right, evalType: dtUnknown)
  return left

proc parseExpr(p: var Parser): AstNode =
  return p.parseCompare()

proc parseType(p: var Parser): DataType =
  let tok = p.peek()
  case tok.kind
  of tkTypeInt64:
    discard p.advance()
    return dtInt64
  of tkTypeFloat64:
    discard p.advance()
    return dtFloat64
  of tkTypeString:
    discard p.advance()
    return dtString
  else:
    raise newException(ValueError, "Expected data type specifier (int64, float64, string) at line " & $tok.line)

proc parseStmt(p: var Parser): AstNode
proc parseBlock(p: var Parser): AstNode =
  p.skipNewLines()
  discard p.expect(tkIndent, "Expected indented block")
  var stmts: seq[AstNode] = @[]
  while p.peek().kind notin {tkDedent, tkEof}:
    p.skipNewLines()
    if p.peek().kind in {tkDedent, tkEof}: break
    stmts.add(p.parseStmt())
    p.skipNewLines()
  discard p.expect(tkDedent, "Expected dedent at end of block")
  return AstNode(kind: nkBlock, stmts: stmts, evalType: dtVoid)

proc parseStmt(p: var Parser): AstNode =
  p.skipNewLines()
  let tok = p.peek()

  if tok.kind == tkVar:
    discard p.advance() # 'var'
    let idTok = p.expect(tkIdent, "Expected variable name after 'var'")
    discard p.expect(tkColon, "Expected ':' after variable name")
    let dt = p.parseType()
    var initNode: AstNode = nil
    if p.match(tkAssign):
      initNode = p.parseExpr()
    return AstNode(kind: nkVarDecl, declName: idTok.val, declaredType: dt, initExpr: initNode, evalType: dtVoid)

  elif tok.kind == tkIf:
    discard p.advance() # 'if'
    let cond = p.parseExpr()
    discard p.expect(tkColon, "Expected ':' after if condition")
    p.skipNewLines()
    let thenBlk = p.parseBlock()
    var elseBlk: AstNode = nil
    p.skipNewLines()
    if p.peek().kind == tkElse:
      discard p.advance() # 'else'
      discard p.expect(tkColon, "Expected ':' after 'else'")
      p.skipNewLines()
      elseBlk = p.parseBlock()
    return AstNode(kind: nkIf, cond: cond, thenBlock: thenBlk, elseBlock: elseBlk, evalType: dtVoid)

  elif tok.kind == tkWhile:
    discard p.advance() # 'while'
    let cond = p.parseExpr()
    discard p.expect(tkColon, "Expected ':' after while condition")
    p.skipNewLines()
    let body = p.parseBlock()
    return AstNode(kind: nkWhile, whileCond: cond, whileBody: body, evalType: dtVoid)

  elif tok.kind == tkFor:
    discard p.advance() # 'for'
    let varTok = p.expect(tkIdent, "Expected variable name in for loop")
    discard p.expect(tkIn, "Expected 'in' after variable in for loop")
    let startExpr = p.parseExpr()
    if p.peek().kind == tkDotDot or p.peek().val == "..":
      discard p.advance()
    else:
      discard p.expect(tkColon, "Expected ':' or range in for loop")
    let endExpr = p.parseExpr()
    if p.peek().kind == tkColon:
      discard p.advance()
    p.skipNewLines()
    let body = p.parseBlock()
    return AstNode(kind: nkFor, forVar: varTok.val, forStart: startExpr, forEnd: endExpr, forBody: body, evalType: dtVoid)

  elif tok.kind == tkProc:
    discard p.advance() # 'proc'
    let nameTok = p.expect(tkIdent, "Expected proc name")
    discard p.expect(tkLParen, "Expected '(' after proc name")
    var params: seq[tuple[name: string, paramType: DataType]] = @[]
    if p.peek().kind != tkRParen:
      while true:
        let pName = p.expect(tkIdent, "Expected param name")
        discard p.expect(tkColon, "Expected ':' after param name")
        let pType = p.parseType()
        params.add((name: pName.val, paramType: pType))
        if not p.match(tkComma): break
    discard p.expect(tkRParen, "Expected ')' after proc parameters")
    var retType = dtVoid
    if p.match(tkColon):
      retType = p.parseType()
    p.skipNewLines()
    let body = p.parseBlock()
    return AstNode(kind: nkProcDecl, procName: nameTok.val, procParams: params, procReturnType: retType, procBody: body, evalType: dtVoid)

  elif tok.kind == tkIdent and tok.val == "print":
    discard p.advance()
    let e = p.parseExpr()
    return AstNode(kind: nkPrint, expr: e, evalType: dtVoid)

  elif tok.kind == tkIdent:
    if p.peek(1).kind == tkAssign:
      let idTok = p.advance()
      discard p.advance() # '='
      let valExpr = p.parseExpr()
      return AstNode(kind: nkAssign, targetName: idTok.val, valExpr: valExpr, evalType: dtVoid)
    else:
      let e = p.parseExpr()
      return AstNode(kind: nkExprStmt, expr: e, evalType: dtVoid)

  else:
    let e = p.parseExpr()
    return AstNode(kind: nkExprStmt, expr: e, evalType: dtVoid)

proc parseProgram*(p: var Parser): AstNode =
  var stmts: seq[AstNode] = @[]
  while p.peek().kind != tkEof:
    p.skipNewLines()
    if p.peek().kind == tkEof: break
    stmts.add(p.parseStmt())
    p.skipNewLines()
  return AstNode(kind: nkBlock, stmts: stmts, evalType: dtVoid)
