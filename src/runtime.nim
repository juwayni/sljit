type
  NimStringHeader* {.packed.} = object
    case isSmall*: bool
    of true:
      smallLen*: uint8
      inlineChars*: array[14, char] # 14 bytes inline string data (1+1+14 = 16 bytes)
    of false:
      pad*: array[3, byte]
      heapLen*: int32
      data*: ptr UncheckedArray[char]

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

const ArenaSize = 8 * 1024 * 1024 # 8 MB contiguous memory pool

type
  MemoryArena* = object
    buffer*: ptr UncheckedArray[char]
    offset*: int
    capacity*: int

var globalArena*: MemoryArena
var globalStringAllocations*: seq[pointer] = @[]

proc initGlobalArena*() =
  if globalArena.buffer == nil:
    globalArena.capacity = ArenaSize
    globalArena.buffer = cast[ptr UncheckedArray[char]](alloc0(ArenaSize))
    globalArena.offset = 0

proc arenaAlloc*(size: int): ptr UncheckedArray[char] =
  if globalArena.buffer == nil:
    initGlobalArena()
  let alignedSize = (size + 7) and not 7 # 8-byte alignment
  if globalArena.offset + alignedSize > globalArena.capacity:
    let p = alloc0(alignedSize)
    globalStringAllocations.add(p)
    return cast[ptr UncheckedArray[char]](p)
  result = cast[ptr UncheckedArray[char]](addr globalArena.buffer[globalArena.offset])
  globalArena.offset += alignedSize

proc trackAlloc*(p: pointer) =
  if p != nil:
    globalStringAllocations.add(p)

proc nim_arena_reset*() {.cdecl, exportc.} =
  globalArena.offset = 0
  for p in globalStringAllocations:
    if p != nil:
      dealloc(p)
  globalStringAllocations.setLen(0)

proc createNimString*(s: string): NimStringHeader =
  if s.len <= 14:
    result = NimStringHeader(isSmall: true, smallLen: uint8(s.len))
    if s.len > 0:
      copyMem(addr result.inlineChars[0], cstring(s), s.len)
  else:
    let buf = arenaAlloc(s.len + 1)
    copyMem(buf, cstring(s), s.len)
    result = NimStringHeader(isSmall: false, heapLen: int32(s.len), data: buf)

proc nimStringToString*(s: NimStringHeader): string =
  if s.isSmall:
    let l = int(s.smallLen)
    if l <= 0: return ""
    result = newString(l)
    copyMem(addr result[0], unsafeAddr s.inlineChars[0], l)
  else:
    let l = int(s.heapLen)
    if l <= 0 or s.data == nil: return ""
    result = newString(l)
    copyMem(addr result[0], s.data, l)

# Helper functions for SLJIT JIT / C calling convention ({.cdecl.})
proc nim_str_concat*(s1: ptr NimStringHeader, s2: ptr NimStringHeader): ptr NimStringHeader {.cdecl, exportc.} =
  let resHeader = cast[ptr NimStringHeader](arenaAlloc(sizeof(NimStringHeader)))

  var str1 = ""
  var str2 = ""
  if s1 != nil: str1 = nimStringToString(s1[])
  if s2 != nil: str2 = nimStringToString(s2[])

  let combined = str1 & str2
  resHeader[] = createNimString(combined)
  return resHeader

proc nim_str_print*(s: ptr NimStringHeader) {.cdecl, exportc.} =
  if s != nil:
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
  let str1 = nimStringToString(s1[])
  let str2 = nimStringToString(s2[])
  if str1 == str2: return 1
  return 0
