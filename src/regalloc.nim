import std/[algorithm, tables, sets]
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
    numScratches*: int32
    numSaveds*: int32

  # CFG Basic Block for Liveness Analysis
  RegAllocBlock = ref object
    id: int
    startInst: int
    endInst: int
    uses: HashSet[VRegId]
    defs: HashSet[VRegId]
    liveIn: HashSet[VRegId]
    liveOut: HashSet[VRegId]
    succs: seq[RegAllocBlock]
    preds: seq[RegAllocBlock]

proc updateInterval(tbl: var Table[VRegId, LiveInterval], vregId: VRegId, startI: int, endI: int, vregTypes: Table[VRegId, DataType]) =
  if vregId <= 0: return
  let dt = vregTypes.getOrDefault(vregId, dtInt64)
  if not tbl.hasKey(vregId):
    tbl[vregId] = LiveInterval(vregId: vregId, dataType: dt, startInst: startI, endInst: endI)
  else:
    tbl[vregId].startInst = min(tbl[vregId].startInst, startI)
    tbl[vregId].endInst = max(tbl[vregId].endInst, endI)

proc computeLiveIntervals*(instructions: seq[IRInstruction]): Table[VRegId, LiveInterval] =
  result = initTable[VRegId, LiveInterval]()
  if instructions.len == 0: return

  # Track virtual register data types
  var vregTypes = initTable[VRegId, DataType]()
  proc recordType(vreg: VirtualReg) =
    if vreg.id > 0: vregTypes[vreg.id] = vreg.dataType

  for inst in instructions:
    recordType(inst.dst)
    recordType(inst.src1)
    recordType(inst.src2)
    for arg in inst.args: recordType(arg)

  # 1. Build CFG Basic Blocks
  var blocks: seq[RegAllocBlock] = @[]
  var labelToBlock = initTable[int, RegAllocBlock]()

  var currentBlock = RegAllocBlock(
    id: 0,
    startInst: 0,
    endInst: 0,
    uses: initHashSet[VRegId](),
    defs: initHashSet[VRegId](),
    liveIn: initHashSet[VRegId](),
    liveOut: initHashSet[VRegId](),
    succs: @[],
    preds: @[]
  )
  blocks.add(currentBlock)

  for idx, inst in instructions:
    if inst.op == opLabel:
      if currentBlock.startInst < idx:
        currentBlock.endInst = idx - 1
        let nextBlock = RegAllocBlock(
          id: blocks.len,
          startInst: idx,
          endInst: idx,
          uses: initHashSet[VRegId](),
          defs: initHashSet[VRegId](),
          liveIn: initHashSet[VRegId](),
          liveOut: initHashSet[VRegId](),
          succs: @[],
          preds: @[]
        )
        currentBlock.succs.add(nextBlock)
        nextBlock.preds.add(currentBlock)
        currentBlock = nextBlock
        blocks.add(currentBlock)
      labelToBlock[inst.labelIdx] = currentBlock

    # Record uses and defs inside current block
    proc useReg(vreg: VirtualReg) =
      if vreg.id > 0:
        if vreg.id notin currentBlock.defs:
          currentBlock.uses.incl(vreg.id)

    proc defReg(vreg: VirtualReg) =
      if vreg.id > 0:
        currentBlock.defs.incl(vreg.id)

    useReg(inst.src1)
    useReg(inst.src2)
    for arg in inst.args: useReg(arg)
    defReg(inst.dst)

    currentBlock.endInst = idx

    if inst.op in {opJump, opJumpIfZero, opJumpIfNotZero, opJumpBack}:
      if idx + 1 < instructions.len:
        let nextBlock = RegAllocBlock(
          id: blocks.len,
          startInst: idx + 1,
          endInst: idx + 1,
          uses: initHashSet[VRegId](),
          defs: initHashSet[VRegId](),
          liveIn: initHashSet[VRegId](),
          liveOut: initHashSet[VRegId](),
          succs: @[],
          preds: @[]
        )
        if inst.op in {opJumpIfZero, opJumpIfNotZero}:
          currentBlock.succs.add(nextBlock)
          nextBlock.preds.add(currentBlock)
        currentBlock = nextBlock
        blocks.add(currentBlock)

  # Resolve CFG Jumps & Back-edges
  for idx, inst in instructions:
    if inst.op in {opJump, opJumpIfZero, opJumpIfNotZero, opJumpBack}:
      if labelToBlock.hasKey(inst.labelIdx):
        let targetBlk = labelToBlock[inst.labelIdx]
        for blk in blocks:
          if idx >= blk.startInst and idx <= blk.endInst:
            if targetBlk notin blk.succs:
              blk.succs.add(targetBlk)
            if blk notin targetBlk.preds:
              targetBlk.preds.add(blk)
            break

  # 2. Backward Dataflow Liveness Analysis
  # LiveIn(B) = Use(B) u (LiveOut(B) \ Def(B))
  # LiveOut(B) = Union_{S in Succ(B)} LiveIn(S)
  var changed = true
  while changed:
    changed = false
    for i in countdown(blocks.len - 1, 0):
      let blk = blocks[i]

      var newLiveOut = initHashSet[VRegId]()
      for succ in blk.succs:
        for v in succ.liveIn:
          newLiveOut.incl(v)

      var newLiveIn = blk.uses
      for v in newLiveOut:
        if v notin blk.defs:
          newLiveIn.incl(v)

      if newLiveIn != blk.liveIn or newLiveOut != blk.liveOut:
        blk.liveIn = newLiveIn
        blk.liveOut = newLiveOut
        changed = true

  # 3. Construct Live Intervals from Liveness Analysis & Loop Back-Edges
  for blk in blocks:
    for v in blk.liveIn:
      result.updateInterval(v, blk.startInst, blk.endInst, vregTypes)
    for v in blk.liveOut:
      result.updateInterval(v, blk.startInst, blk.endInst, vregTypes)

  for idx, inst in instructions:
    if inst.dst.id > 0: result.updateInterval(inst.dst.id, idx, idx, vregTypes)
    if inst.src1.id > 0: result.updateInterval(inst.src1.id, idx, idx, vregTypes)
    if inst.src2.id > 0: result.updateInterval(inst.src2.id, idx, idx, vregTypes)
    for arg in inst.args:
      if arg.id > 0: result.updateInterval(arg.id, idx, idx, vregTypes)

  # Ensure loop variables live across backward edges span from loop header to back-edge jump
  for idx, inst in instructions:
    if inst.op == opJumpBack and labelToBlock.hasKey(inst.labelIdx):
      let targetBlk = labelToBlock[inst.labelIdx]
      let loopHeaderInst = targetBlk.startInst
      let backEdgeInst = idx
      for vregId, interval in result.mpairs:
        if interval.startInst <= backEdgeInst and interval.endInst >= loopHeaderInst:
          interval.startInst = min(interval.startInst, loopHeaderInst)
          interval.endInst = max(interval.endInst, backEdgeInst)

proc allocateRegisters*(instructions: seq[IRInstruction], maxIntRegs = 7, maxFloatRegs = 4): RegAllocResult =
  let intervalsTable = computeLiveIntervals(instructions)
  var intervals: seq[LiveInterval] = @[]
  for v, interval in intervalsTable:
    intervals.add(interval)

  intervals.sort(proc(a, b: LiveInterval): int = cmp(a.startInst, b.startInst))

  var locs = initTable[VRegId, RegLoc]()

  # Hardware-wide register pool:
  # S0..S2, S4, S5 (saved registers; S3 reserved for FAST_CALL return address)
  # R4, R5 (scratch registers; R0..R3 reserved for C-ABI call arguments/scratch)
  var availableInts = [
    SLJIT_S0, SLJIT_S1, SLJIT_S2, SLJIT_S4, SLJIT_S5,
    SLJIT_R4, SLJIT_R5
  ]
  var intFreeRegs: seq[int32] = @[]
  let numInts = min(maxIntRegs, availableInts.len)
  for i in countdown(numInts - 1, 0):
    intFreeRegs.add(availableInts[i])

  var availableFloats = [
    SLJIT_FR0, SLJIT_FR1, SLJIT_FR2, SLJIT_FR3
  ]
  var floatFreeRegs: seq[int32] = @[]
  let numFloats = min(maxFloatRegs, availableFloats.len)
  for i in countdown(numFloats - 1, 0):
    floatFreeRegs.add(availableFloats[i])

  var activeInt: seq[tuple[interval: LiveInterval, reg: int32]] = @[]
  var activeFloat: seq[tuple[interval: LiveInterval, reg: int32]] = @[]

  var nextStackSlot = 0

  for interval in intervals:
    let isFloat = (interval.dataType == dtFloat64)

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

  result = RegAllocResult(
    locations: locs,
    spillStackSize: (nextStackSlot + 1) * 8,
    numScratches: 6, # R0..R5
    numSaveds: 6    # S0..S5
  )
