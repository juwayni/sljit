import std/parseutils

type
  TokenKind* = enum
    tkEof,
    tkNewLine,
    tkIndent,
    tkDedent,

    # Keywords
    tkVar,
    tkProc,
    tkIf,
    tkElse,
    tkWhile,
    tkFor,
    tkIn,

    # Primitive Types
    tkTypeInt64,
    tkTypeFloat64,
    tkTypeString,

    # Literals
    tkIntLit,
    tkFloatLit,
    tkStringLit,
    tkIdent,

    # Operators & Punctuation
    tkColon,       # :
    tkAssign,      # =
    tkEq,          # ==
    tkNeq,         # !=
    tkLt,          # <
    tkLe,          # <=
    tkGt,          # >
    tkGe,          # >=
    tkPlus,        # +
    tkMinus,       # -
    tkStar,        # *
    tkSlash,       # /
    tkLParen,      # (
    tkRParen,      # )
    tkComma,       # ,
    tkDotDot       # ..

  Token* = object
    kind*: TokenKind
    val*: string
    intVal*: int64
    floatVal*: float64
    line*: int
    col*: int

  Lexer* = object
    src*: string
    pos*: int
    line*: int
    col*: int
    indentStack*: seq[int]
    atLineStart*: bool
    pendingTokens*: seq[Token]

proc initLexer*(src: string): Lexer =
  result = Lexer(
    src: src,
    pos: 0,
    line: 1,
    col: 1,
    indentStack: @[0],
    atLineStart: true,
    pendingTokens: @[]
  )

proc peekChar(lex: Lexer, offset = 0): char =
  let idx = lex.pos + offset
  if idx >= lex.src.len: '\0'
  else: lex.src[idx]

proc advanceChar(lex: var Lexer): char =
  if lex.pos < lex.src.len:
    result = lex.src[lex.pos]
    inc lex.pos
    if result == '\n':
      inc lex.line
      lex.col = 1
    else:
      inc lex.col
  else:
    result = '\0'

proc lexNextToken*(lex: var Lexer): Token =
  if lex.pendingTokens.len > 0:
    let tok = lex.pendingTokens[0]
    lex.pendingTokens.delete(0)
    return tok

  while lex.pos < lex.src.len:
    if lex.atLineStart:
      lex.atLineStart = false
      var indent = 0
      while lex.peekChar() in {' ', '\t'}:
        if lex.peekChar() == '\t':
          indent += 2
        else:
          indent += 1
        discard lex.advanceChar()

      # Blank line or comment check
      if lex.peekChar() == '#' or lex.peekChar() in {'\r', '\n'}:
        if lex.peekChar() == '#':
          while lex.peekChar() notin {'\r', '\n', '\0'}:
            discard lex.advanceChar()
        if lex.peekChar() in {'\r', '\n'}:
          if lex.peekChar() == '\r': discard lex.advanceChar()
          if lex.peekChar() == '\n': discard lex.advanceChar()
        lex.atLineStart = true
        continue

      let currentIndent = lex.indentStack[^1]
      if indent > currentIndent:
        lex.indentStack.add(indent)
        return Token(kind: tkIndent, val: "INDENT", line: lex.line, col: lex.col)
      elif indent < currentIndent:
        while lex.indentStack.len > 1 and lex.indentStack[^1] > indent:
          discard lex.indentStack.pop()
          lex.pendingTokens.add(Token(kind: tkDedent, val: "DEDENT", line: lex.line, col: lex.col))
        if lex.indentStack[^1] != indent:
          raise newException(ValueError, "Indentation error at line " & $lex.line)
        if lex.pendingTokens.len > 0:
          let tok = lex.pendingTokens[0]
          lex.pendingTokens.delete(0)
          return tok

    let ch = lex.peekChar()

    if ch in {' ', '\t', '\r'}:
      discard lex.advanceChar()
      continue

    if ch == '\n':
      discard lex.advanceChar()
      lex.atLineStart = true
      return Token(kind: tkNewLine, val: "\n", line: lex.line - 1, col: lex.col)

    if ch == '#':
      while lex.peekChar() notin {'\r', '\n', '\0'}:
        discard lex.advanceChar()
      continue

    let curLine = lex.line
    let curCol = lex.col

    # Range operator ..
    if ch == '.' and lex.peekChar(1) == '.':
      discard lex.advanceChar()
      discard lex.advanceChar()
      return Token(kind: tkDotDot, val: "..", line: curLine, col: curCol)

    # Numbers (Int & Float)
    if ch in {'0'..'9'}:
      var numStr = ""
      var isFloat = false
      while lex.peekChar() in {'0'..'9'}:
        numStr.add(lex.advanceChar())
      if lex.peekChar() == '.' and lex.peekChar(1) in {'0'..'9'}:
        isFloat = true
        numStr.add(lex.advanceChar()) # '.'
        while lex.peekChar() in {'0'..'9'}:
          numStr.add(lex.advanceChar())
      if isFloat:
        var val: float64
        discard parseFloat(numStr, val)
        return Token(kind: tkFloatLit, val: numStr, floatVal: val, line: curLine, col: curCol)
      else:
        var val: int64
        discard parseBiggestInt(numStr, val)
        return Token(kind: tkIntLit, val: numStr, intVal: val, line: curLine, col: curCol)

    # Identifiers & Keywords
    if ch in {'a'..'z', 'A'..'Z', '_'}:
      var id = ""
      while lex.peekChar() in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        id.add(lex.advanceChar())
      case id
      of "var":     return Token(kind: tkVar, val: id, line: curLine, col: curCol)
      of "proc":    return Token(kind: tkProc, val: id, line: curLine, col: curCol)
      of "if":      return Token(kind: tkIf, val: id, line: curLine, col: curCol)
      of "else":    return Token(kind: tkElse, val: id, line: curLine, col: curCol)
      of "while":   return Token(kind: tkWhile, val: id, line: curLine, col: curCol)
      of "for":     return Token(kind: tkFor, val: id, line: curLine, col: curCol)
      of "in":      return Token(kind: tkIn, val: id, line: curLine, col: curCol)
      of "int64":   return Token(kind: tkTypeInt64, val: id, line: curLine, col: curCol)
      of "float64": return Token(kind: tkTypeFloat64, val: id, line: curLine, col: curCol)
      of "string":  return Token(kind: tkTypeString, val: id, line: curLine, col: curCol)
      else:         return Token(kind: tkIdent, val: id, line: curLine, col: curCol)

    # String literals
    if ch == '"':
      discard lex.advanceChar()
      var strVal = ""
      while lex.peekChar() notin {'"', '\0'}:
        if lex.peekChar() == '\\':
          discard lex.advanceChar()
          let nxt = lex.advanceChar()
          case nxt
          of 'n': strVal.add('\n')
          of 't': strVal.add('\t')
          of '"': strVal.add('"')
          of '\\': strVal.add('\\')
          else: strVal.add(nxt)
        else:
          strVal.add(lex.advanceChar())
      if lex.peekChar() == '"':
        discard lex.advanceChar()
      return Token(kind: tkStringLit, val: strVal, line: curLine, col: curCol)

    # Punctuation & Operators
    case ch
    of ':':
      discard lex.advanceChar()
      return Token(kind: tkColon, val: ":", line: curLine, col: curCol)
    of '=':
      discard lex.advanceChar()
      if lex.peekChar() == '=':
        discard lex.advanceChar()
        return Token(kind: tkEq, val: "==", line: curLine, col: curCol)
      return Token(kind: tkAssign, val: "=", line: curLine, col: curCol)
    of '!':
      discard lex.advanceChar()
      if lex.peekChar() == '=':
        discard lex.advanceChar()
        return Token(kind: tkNeq, val: "!=", line: curLine, col: curCol)
      raise newException(ValueError, "Unexpected character '!' at line " & $curLine)
    of '<':
      discard lex.advanceChar()
      if lex.peekChar() == '=':
        discard lex.advanceChar()
        return Token(kind: tkLe, val: "<=", line: curLine, col: curCol)
      return Token(kind: tkLt, val: "<", line: curLine, col: curCol)
    of '>':
      discard lex.advanceChar()
      if lex.peekChar() == '=':
        discard lex.advanceChar()
        return Token(kind: tkGe, val: ">=", line: curLine, col: curCol)
      return Token(kind: tkGt, val: ">", line: curLine, col: curCol)
    of '+':
      discard lex.advanceChar()
      return Token(kind: tkPlus, val: "+", line: curLine, col: curCol)
    of '-':
      discard lex.advanceChar()
      return Token(kind: tkMinus, val: "-", line: curLine, col: curCol)
    of '*':
      discard lex.advanceChar()
      return Token(kind: tkStar, val: "*", line: curLine, col: curCol)
    of '/':
      discard lex.advanceChar()
      return Token(kind: tkSlash, val: "/", line: curLine, col: curCol)
    of '(':
      discard lex.advanceChar()
      return Token(kind: tkLParen, val: "(", line: curLine, col: curCol)
    of ')':
      discard lex.advanceChar()
      return Token(kind: tkRParen, val: ")", line: curLine, col: curCol)
    of ',':
      discard lex.advanceChar()
      return Token(kind: tkComma, val: ",", line: curLine, col: curCol)
    else:
      discard lex.advanceChar()
      raise newException(ValueError, "Unexpected character '" & ch & "' at line " & $curLine)

  # Clear remaining indent levels at EOF
  if lex.indentStack.len > 1:
    while lex.indentStack.len > 1:
      discard lex.indentStack.pop()
      lex.pendingTokens.add(Token(kind: tkDedent, val: "DEDENT", line: lex.line, col: lex.col))
    let tok = lex.pendingTokens[0]
    lex.pendingTokens.delete(0)
    return tok

  return Token(kind: tkEof, val: "EOF", line: lex.line, col: lex.col)

proc tokenizeAll*(src: string): seq[Token] =
  var lex = initLexer(src)
  while true:
    let tok = lex.lexNextToken()
    result.add(tok)
    if tok.kind == tkEof:
      break
