type
  NimStringHeader* {.packed.} = object
    data*: ptr char
    len*: int64

  VMValueKind* = enum
    vkInt,
    vkFloat,
    vkString

  VMValue* = object
    case kind*: VMValueKind
    of vkInt:
      intVal*: int64
    of vkFloat:
      floatVal*: float64
    of vkString:
      strVal*: ptr NimStringHeader

var globalStringAllocations*: seq[pointer] = @[]

proc trackAlloc*(p: pointer) =
  if p != nil:
    globalStringAllocations.add(p)

proc nim_arena_reset*() {.cdecl, exportc.} =
  for p in globalStringAllocations:
    if p != nil:
      dealloc(p)
  globalStringAllocations.setLen(0)

proc createNimString*(s: string): NimStringHeader =
  if s.len == 0:
    return NimStringHeader(data: nil, len: 0)
  let p = cast[ptr char](alloc0(s.len + 1))
  trackAlloc(p)
  copyMem(p, cstring(s), s.len)
  result = NimStringHeader(data: p, len: s.len)

proc nimStringToString*(s: NimStringHeader): string =
  if s.len <= 0 or s.data == nil:
    return ""
  result = newString(s.len)
  copyMem(addr result[0], s.data, s.len)

# Helper functions for SLJIT JIT / C calling convention ({.cdecl.})
proc nim_str_concat*(s1: ptr NimStringHeader, s2: ptr NimStringHeader): ptr NimStringHeader {.cdecl, exportc.} =
  let resHeader = cast[ptr NimStringHeader](alloc0(sizeof(NimStringHeader)))
  trackAlloc(resHeader)

  let len1 = if s1 != nil: s1.len else: 0
  let len2 = if s2 != nil: s2.len else: 0
  let totalLen = len1 + len2
  resHeader.len = totalLen

  if totalLen > 0:
    let buf = cast[ptr char](alloc0(totalLen + 1))
    trackAlloc(buf)
    if len1 > 0 and s1.data != nil:
      copyMem(buf, s1.data, len1)
    if len2 > 0 and s2.data != nil:
      let dst = cast[ptr char](cast[uint](buf) + cast[uint](len1))
      copyMem(dst, s2.data, len2)
    resHeader.data = buf
  else:
    resHeader.data = nil

  return resHeader

proc nim_str_print*(s: ptr NimStringHeader) {.cdecl, exportc.} =
  if s != nil and s.len > 0 and s.data != nil:
    let str = nimStringToString(s[])
    echo str
  else:
    echo ""

proc nim_int_print*(val: int64) {.cdecl, exportc.} =
  echo val

proc nim_float_print*(val: float64) {.cdecl, exportc.} =
  echo val

proc nim_str_eq*(s1: ptr NimStringHeader, s2: ptr NimStringHeader): int64 {.cdecl, exportc.} =
  if s1 == s2: return 1
  if s1 == nil or s2 == nil: return 0
  if s1.len != s2.len: return 0
  if s1.len == 0: return 1
  if cmpMem(s1.data, s2.data, s1.len) == 0:
    return 1
  return 0
