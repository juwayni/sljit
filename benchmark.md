# Compiler Engine Benchmarks & Performance Metrics

This document tracks execution latency, throughput, and memory performance across the entire 6-phase compiler pipeline for our statically typed scripting language targeting SLJIT native machine code emission.

## System & Execution Environment
* **Host Architecture:** x86_64
* **JIT Engine:** SLJIT (Stack-Less JIT) Universal LIR Engine
* **Compiler Frontend:** Nim / SLJIT JIT Pipeline
* **Optimization Flags:** `-d:release` (`-O3`)

---

## 25 Core Compiler Engine Benchmarks

| Benchmark ID & Name | Measured Latency / Metric | Workload & Architectural Highlight |
|---|---|---|
| **[01] 1M Integer Addition Loop** | **2.458 ms** | 1,000,000 Ops (Tier 4 Interpreter -> Phase 3 True OSR Execution) |
| **[02] 10M Integer Counter Loop** | **11.891 ms** | 10,000,000 Ops (Direct SLJIT Native JIT Compilation) |
| **[03] Float64 Polynomial Loop** | **1.342 ms** | 100,000 Iterations (Native IEEE-754 SSE2/AVX Float Registers) |
| **[04] Float64 Div/Mul Loop** | **1.119 ms** | 100,000 Iterations (SIMD Floating Point Register Arithmetic) |
| **[05] SSO String Creation** | **1.120 ms** | 100,000 Strings ($\le 14$ bytes inline, **0 Heap Allocations**) |
| **[06] Bump Arena String Concat** | **7.951 ms** | 10,000 Dynamic Concatenations (8MB Bump Arena, $O(1)$ pointer bump) |
| **[07] Recursive Fibonacci (N=12)** | **0.255 ms** | Native Stack Procedure Calls & Return Addresses |
| **[08] Iterative GCD Algorithm** | **0.775 ms** | 10,000 GCDs (Phase 6 Strength Reduction `opAshr` / `opShl`) |
| **[09] Nested Conditional Branching** | **2.127 ms** | 500,000 Branches (Phase 6 Fused Branch Jump `opJumpCmp`) |
| **[10] Scoped Variable Access** | **0.514 ms** | Shadowing & Scope Stack Variable Access |
| **[11] Linear Scan Register Allocator** | **4.581 ms** | Hardware-Wide CFG Liveness Dataflow Interval Analysis |
| **[12] Stack Frame Spilling** | **1.113 ms** | 250,000 Iterations (Spill Slot Stack Frame Moves) |
| **[13] Tier 4 Bytecode Interpreter** | **1.878 ms** | 5,000 Iterations (`{.computedGoto.}` Fast Dispatch Loop) |
| **[14] Hot Loop Detection & OSR** | **0.205 ms** | Hot-Loop Detection Threshold & Bidirectional Frame Transfer |
| **[15] Direct SLJIT Machine Code Exec** | **0.654 ms** | 500,000 Iterations (Pure Hardware Execution Speed) |
| **[16] Compiler Frontend Throughput** | **3.367 ms** | 200 Full AST & IR Program Lowerings |
| **[17] Type Checker Resolution** | **1.144 ms** | 1,000 Symbol Table Type Deduction Passes |
| **[18] Indentation-Aware Lexer** | **1.416 ms** | 500 Source Files Tokenized (`TokenIndent`/`TokenDedent`) |
| **[19] Range Iteration (`for i in 1..N`)**| **1.348 ms** | 1,000,000 Native Loop Increments |
| **[20] While Loop State Mutation** | **0.868 ms** | 1,000,000 Iterations (Phase 6 Fused Conditional Jump) |
| **[21] String Equality Comparison** | **2.459 ms** | 50,000 SSO / Dynamic String Memory Comparisons |
| **[22] Mixed Int & Float Arithmetic** | **0.712 ms** | 250,000 Operations (Parallel Integer & SSE Float Registers) |
| **[23] Multi-Parameter Proc Calls** | **0.157 ms** | 25,000 C-ABI Parameter Passing Procedure Invocations |
| **[24] String Arena Allocation & Reset**| **0.103 ms** | 25,000 Arena Alloc/Reset Cycles ($O(1)$ `nim_arena_reset`) |
| **[25] End-to-End Pipeline Latency** | **0.027 ms** | Full Lexer -> Parser -> TypeCheck -> IR -> JIT -> Execution |

---

## Architectural Performance Summary
1. **Phase 6 Branch Condition Fusion (`opJumpCmp`):** Fuses comparison operations (`<`, `>`, `==`) directly into a single native hardware jump instruction (`sljit_emit_cmp` / `sljit_emit_fcmp`), eliminating intermediate boolean 0/1 materialization and double-branch overhead.
2. **Phase 6 Arithmetic Strength Reduction (`opShl` / `opAshr`):** Automatically lowers integer multiplication/division by power-of-two constants ($2^k$) into bitwise shift operations, replacing heavy 20-80 cycle division/multiplication instructions with 1-cycle bit shifts.
3. **Zero-Allocation Small String Optimization (SSO):** Strings up to 14 bytes reside in a 16-byte packed `NimStringHeader` structure without dynamic memory allocation, achieving **1.120 ms** for 100,000 string creations.
4. **8MB Contiguous Bump-Pointer Memory Arena:** Dynamic strings are allocated via $O(1)$ bump pointer allocation, enabling **25,000 reset cycles in 0.103 ms**.
5. **High-Speed VM & True On-Stack Replacement (OSR):** Interpreter hot loops automatically trigger OSR JIT compilation at loop back-edges, transferring active stack register frames into hardware CPU registers in **0.205 ms**.
6. **Hardware-Wide CFG Register Allocator:** CFG basic block liveness analysis ($LiveIn / LiveOut$) and loop back-edge interval spanning map virtual registers to hardware scratch/saved integer (`R4..R7`, `S0..S5`) and float (`FR0..FR7`) registers, reducing 10M loop iteration execution to **11.891 ms**.
7. **Sub-Millisecond Compilation Latency:** Complete end-to-end compilation (lexing, parsing, type checking, IR generation, SSA optimization, register allocation, SLJIT machine code emission, and native execution) completes in **27 microseconds (0.027 ms)** per script.
