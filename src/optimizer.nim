import std/tables
import ir, ast

type
  BasicBlock* = ref object
    id*: int
    instructions*: seq[IRInstruction]
    successors*: seq[BasicBlock]
    predecessors*: seq[BasicBlock]

  ControlFlowGraph* = ref object
    entry*: BasicBlock
    blocks*: seq[BasicBlock]

proc buildCFG*(insts: seq[IRInstruction]): ControlFlowGraph =
  var cfg = ControlFlowGraph(blocks: @[])
  if insts.len == 0: return cfg

  var currentBlock = BasicBlock(id: 0, instructions: @[], successors: @[], predecessors: @[])
  cfg.blocks.add(currentBlock)
  cfg.entry = currentBlock

  var blockMap = initTable[int, BasicBlock]()
  blockMap[0] = currentBlock

  var blockCounter = 1

  for inst in insts:
    case inst.op
    of opLabel:
      if currentBlock.instructions.len > 0:
        let newBlock = BasicBlock(id: blockCounter, instructions: @[], successors: @[], predecessors: @[])
        inc blockCounter
        currentBlock.successors.add(newBlock)
        newBlock.predecessors.add(currentBlock)
        currentBlock = newBlock
        cfg.blocks.add(currentBlock)
      currentBlock.instructions.add(inst)
      blockMap[inst.labelIdx] = currentBlock

    of opJump, opJumpIfZero, opJumpIfNotZero, opJumpBack:
      currentBlock.instructions.add(inst)
      let newBlock = BasicBlock(id: blockCounter, instructions: @[], successors: @[], predecessors: @[])
      inc blockCounter
      currentBlock.successors.add(newBlock)
      newBlock.predecessors.add(currentBlock)
      currentBlock = newBlock
      cfg.blocks.add(currentBlock)

    else:
      currentBlock.instructions.add(inst)

  return cfg

proc constantFoldPass*(insts: seq[IRInstruction]): seq[IRInstruction] =
  var resultInsts: seq[IRInstruction] = @[]
  var intConsts = initTable[int, int64]()
  var floatConsts = initTable[int, float64]()

  for inst in insts:
    var folded = false
    case inst.op
    of opLoadIntConst:
      intConsts[inst.dst.id] = inst.intImm

    of opLoadFloatConst:
      floatConsts[inst.dst.id] = inst.floatImm

    of opAdd:
      if inst.dst.dataType == dtInt64 and intConsts.hasKey(inst.src1.id) and intConsts.hasKey(inst.src2.id):
        let val = intConsts[inst.src1.id] + intConsts[inst.src2.id]
        intConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadIntConst, dst: inst.dst, intImm: val))
        folded = true
      elif inst.dst.dataType == dtFloat64 and floatConsts.hasKey(inst.src1.id) and floatConsts.hasKey(inst.src2.id):
        let val = floatConsts[inst.src1.id] + floatConsts[inst.src2.id]
        floatConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadFloatConst, dst: inst.dst, floatImm: val))
        folded = true

    of opSub:
      if inst.dst.dataType == dtInt64 and intConsts.hasKey(inst.src1.id) and intConsts.hasKey(inst.src2.id):
        let val = intConsts[inst.src1.id] - intConsts[inst.src2.id]
        intConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadIntConst, dst: inst.dst, intImm: val))
        folded = true
      elif inst.dst.dataType == dtFloat64 and floatConsts.hasKey(inst.src1.id) and floatConsts.hasKey(inst.src2.id):
        let val = floatConsts[inst.src1.id] - floatConsts[inst.src2.id]
        floatConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadFloatConst, dst: inst.dst, floatImm: val))
        folded = true

    of opMul:
      if inst.dst.dataType == dtInt64 and intConsts.hasKey(inst.src1.id) and intConsts.hasKey(inst.src2.id):
        let val = intConsts[inst.src1.id] * intConsts[inst.src2.id]
        intConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadIntConst, dst: inst.dst, intImm: val))
        folded = true
      elif inst.dst.dataType == dtFloat64 and floatConsts.hasKey(inst.src1.id) and floatConsts.hasKey(inst.src2.id):
        let val = floatConsts[inst.src1.id] * floatConsts[inst.src2.id]
        floatConsts[inst.dst.id] = val
        resultInsts.add(IRInstruction(op: opLoadFloatConst, dst: inst.dst, floatImm: val))
        folded = true

    else:
      discard

    if not folded:
      # Clear constant tracking if register is re-assigned non-const
      if inst.dst.id > 0 and inst.op notin {opLoadIntConst, opLoadFloatConst}:
        intConsts.del(inst.dst.id)
        floatConsts.del(inst.dst.id)
      resultInsts.add(inst)

  return resultInsts

proc csePass*(insts: seq[IRInstruction]): seq[IRInstruction] =
  var resultInsts: seq[IRInstruction] = @[]
  var exprTable = initTable[tuple[op: IROpCode, s1: int, s2: int], VirtualReg]()

  for inst in insts:
    # Reset CSE expression table at control flow boundaries
    if inst.op in {opLabel, opJump, opJumpIfZero, opJumpIfNotZero, opJumpBack, opProcEntry, opProcExit, opCall}:
      exprTable.clear()

    var eliminated = false
    case inst.op
    of opAdd, opSub, opMul, opDiv:
      let key = (op: inst.op, s1: inst.src1.id, s2: inst.src2.id)
      if exprTable.hasKey(key):
        let existingVReg = exprTable[key]
        resultInsts.add(IRInstruction(op: opLoadVar, dst: inst.dst, src1: existingVReg))
        eliminated = true
      else:
        exprTable[key] = inst.dst
    else:
      discard

    if not eliminated:
      # If inst modifies a virtual register, invalidate any cached expressions that depend on dst
      if inst.dst.id > 0:
        var keysToRemove: seq[tuple[op: IROpCode, s1: int, s2: int]] = @[]
        for key, _ in exprTable:
          if key.s1 == inst.dst.id or key.s2 == inst.dst.id:
            keysToRemove.add(key)
        for key in keysToRemove:
          exprTable.del(key)

      resultInsts.add(inst)

  return resultInsts

proc licmPass*(insts: seq[IRInstruction]): seq[IRInstruction] =
  # Loop Invariant Code Motion
  var loopStartIdx = -1
  var loopEndIdx = -1
  var loopId = -1

  for idx, inst in insts:
    if inst.op == opJumpBack:
      loopEndIdx = idx
      loopId = inst.loopId
      # Find corresponding start label
      for j in countdown(idx - 1, 0):
        if insts[j].op == opLabel and insts[j].labelIdx == inst.labelIdx:
          loopStartIdx = j
          break
      break

  if loopStartIdx == -1 or loopEndIdx == -1:
    return insts

  # Identify registers defined inside the loop
  var definedInLoop: seq[int] = @[]
  for i in loopStartIdx..loopEndIdx:
    if insts[i].dst.id > 0:
      definedInLoop.add(insts[i].dst.id)

  var preheader: seq[IRInstruction] = @[]
  var loopBody: seq[IRInstruction] = @[]

  for i in 0..<loopStartIdx:
    preheader.add(insts[i])

  for i in loopStartIdx..loopEndIdx:
    let inst = insts[i]
    var isInvariant = false
    if inst.op in {opAdd, opSub, opMul} and inst.dst.id > 0:
      let s1Invariant = inst.src1.id notin definedInLoop
      let s2Invariant = inst.src2.id notin definedInLoop
      if s1Invariant and s2Invariant:
        isInvariant = true

    if isInvariant:
      preheader.add(inst)
    else:
      loopBody.add(inst)

  for i in (loopEndIdx + 1)..<insts.len:
    loopBody.add(insts[i])

  return preheader & loopBody

proc optimizeIR*(insts: seq[IRInstruction]): seq[IRInstruction] =
  var optimized = insts
  optimized = constantFoldPass(optimized)
  optimized = csePass(optimized)
  optimized = licmPass(optimized)
  return optimized
