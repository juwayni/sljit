import std/[algorithm, tables]
import ir, ast, sljit_bindings

type
  RegLocKind* = enum
    rlReg,
    rlStackSlot

  RegLoc* = object
    case kind*: RegLocKind
    of rlReg:
      physReg*: int32
    of rlStackSlot:
      stackOffset*: int

  LiveInterval* = object
    vregId*: VRegId
    dataType*: DataType
    startInst*: int
    endInst*: int

  RegAllocResult* = object
    locations*: Table[VRegId, RegLoc]
    spillStackSize*: int

proc updateReg(tbl: var Table[VRegId, LiveInterval], vreg: VirtualReg, idx: int) =
  if vreg.id <= 0: return
  if not tbl.hasKey(vreg.id):
    tbl[vreg.id] = LiveInterval(vregId: vreg.id, dataType: vreg.dataType, startInst: idx, endInst: idx)
  else:
    if idx < tbl[vreg.id].startInst: tbl[vreg.id].startInst = idx
    if idx > tbl[vreg.id].endInst: tbl[vreg.id].endInst = idx

proc computeLiveIntervals*(instructions: seq[IRInstruction]): Table[VRegId, LiveInterval] =
  result = initTable[VRegId, LiveInterval]()

  # Track label indices and loop back-edges
  var labelPos = initTable[int, int]()
  var loopBackEdges: seq[tuple[startInst: int, backInst: int]] = @[]

  for idx, inst in instructions:
    if inst.op == opLabel:
      labelPos[inst.labelIdx] = idx
    elif inst.op == opJumpBack:
      if labelPos.hasKey(inst.labelIdx):
        let startIdx = labelPos[inst.labelIdx]
        loopBackEdges.add((startInst: startIdx, backInst: idx))

    result.updateReg(inst.dst, idx)
    result.updateReg(inst.src1, idx)
    result.updateReg(inst.src2, idx)
    for arg in inst.args:
      result.updateReg(arg, idx)

  # Extend live intervals for loop-carried variables
  for loop in loopBackEdges:
    for vregId, interval in result.mpairs:
      # If variable is live at or before loop start and used/live inside loop, extend endInst to loop back-edge
      if interval.startInst <= loop.backInst and interval.endInst >= loop.startInst:
        interval.endInst = max(interval.endInst, loop.backInst)

proc allocateRegisters*(instructions: seq[IRInstruction], maxIntRegs = 4, maxFloatRegs = 4): RegAllocResult =
  let intervalsTable = computeLiveIntervals(instructions)
  var intervals: seq[LiveInterval] = @[]
  for v, interval in intervalsTable:
    intervals.add(interval)

  intervals.sort(proc(a, b: LiveInterval): int = cmp(a.startInst, b.startInst))

  var locs = initTable[VRegId, RegLoc]()

  # Saved registers (S0..S3) are preserved across C function calls (icall)
  var availableInts = [SLJIT_S0, SLJIT_S1, SLJIT_S2, SLJIT_S3]
  var intFreeRegs: seq[int32] = @[]
  let numInts = min(maxIntRegs, 4)
  for i in countdown(numInts - 1, 0):
    intFreeRegs.add(availableInts[i])

  var availableFloats = [SLJIT_FR0, SLJIT_FR1, SLJIT_FR2, SLJIT_FR3]
  var floatFreeRegs: seq[int32] = @[]
  let numFloats = min(maxFloatRegs, 4)
  for i in countdown(numFloats - 1, 0):
    floatFreeRegs.add(availableFloats[i])

  var activeInt: seq[tuple[interval: LiveInterval, reg: int32]] = @[]
  var activeFloat: seq[tuple[interval: LiveInterval, reg: int32]] = @[]

  var nextStackSlot = 0

  for interval in intervals:
    let isFloat = (interval.dataType == dtFloat64)

    # Expire old active intervals
    if isFloat:
      var newActive: seq[tuple[interval: LiveInterval, reg: int32]] = @[]
      for a in activeFloat:
        if a.interval.endInst < interval.startInst:
          floatFreeRegs.add(a.reg)
        else:
          newActive.add(a)
      activeFloat = newActive
    else:
      var newActive: seq[tuple[interval: LiveInterval, reg: int32]] = @[]
      for a in activeInt:
        if a.interval.endInst < interval.startInst:
          intFreeRegs.add(a.reg)
        else:
          newActive.add(a)
      activeInt = newActive

    if isFloat:
      if floatFreeRegs.len > 0:
        let reg = floatFreeRegs.pop()
        locs[interval.vregId] = RegLoc(kind: rlReg, physReg: reg)
        activeFloat.add((interval: interval, reg: reg))
      else:
        var maxIdx = -1
        var maxEnd = interval.endInst
        for i, a in activeFloat:
          if a.interval.endInst > maxEnd:
            maxEnd = a.interval.endInst
            maxIdx = i

        if maxIdx >= 0:
          let victim = activeFloat[maxIdx]
          activeFloat.delete(maxIdx)
          let offset = nextStackSlot * 8
          inc nextStackSlot
          locs[victim.interval.vregId] = RegLoc(kind: rlStackSlot, stackOffset: offset)

          locs[interval.vregId] = RegLoc(kind: rlReg, physReg: victim.reg)
          activeFloat.add((interval: interval, reg: victim.reg))
        else:
          let offset = nextStackSlot * 8
          inc nextStackSlot
          locs[interval.vregId] = RegLoc(kind: rlStackSlot, stackOffset: offset)

    else:
      if intFreeRegs.len > 0:
        let reg = intFreeRegs.pop()
        locs[interval.vregId] = RegLoc(kind: rlReg, physReg: reg)
        activeInt.add((interval: interval, reg: reg))
      else:
        var maxIdx = -1
        var maxEnd = interval.endInst
        for i, a in activeInt:
          if a.interval.endInst > maxEnd:
            maxEnd = a.interval.endInst
            maxIdx = i

        if maxIdx >= 0:
          let victim = activeInt[maxIdx]
          activeInt.delete(maxIdx)
          let offset = nextStackSlot * 8
          inc nextStackSlot
          locs[victim.interval.vregId] = RegLoc(kind: rlStackSlot, stackOffset: offset)

          locs[interval.vregId] = RegLoc(kind: rlReg, physReg: victim.reg)
          activeInt.add((interval: interval, reg: victim.reg))
        else:
          let offset = nextStackSlot * 8
          inc nextStackSlot
          locs[interval.vregId] = RegLoc(kind: rlStackSlot, stackOffset: offset)

  result = RegAllocResult(locations: locs, spillStackSize: (nextStackSlot + 1) * 8)
