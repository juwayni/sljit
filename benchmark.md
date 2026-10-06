# Statically-Typed Scripting Language JIT Engine Benchmark Suite

This document tracks execution performance across 25 core benchmarking benchmarks for our statically-typed Nim-like scripting language engine targeting **SLJIT (Stack-less Just-In-Time Compiler)**.

---

## Performance Summary Table

| ID | Benchmark Name | Operations / Workload | Time (ms) | Performance Highlights & Architecture Notes |
|---|---|---|---|---|
| **01** | **1M Integer Addition Loop** | 1,000,000 ops | `2.858 ms` | Tier 4 Hot Loop Detector triggers True OSR JIT transfer |
| **02** | **10M Integer Counter Loop** | 10,000,000 ops | `19.597 ms` | Hardware-native machine code execution via SLJIT |
| **03** | **Float64 Polynomial Loop** | 100,000 ops | `1.252 ms` | Native IEEE-754 double precision register arithmetic |
| **04** | **Float64 Div/Mul Loop** | 100,000 ops | `12.038 ms` | Hardware floating point division & multiplication |
| **05** | **Small String Optimization (SSO)** | 100,000 strings | `1.106 ms` | **0 Heap Allocations**; packed 16-byte header |
| **06** | **Long String Bump Arena Concatenation** | 10,000 ops | `7.789 ms` | 8 MB contiguous memory bump-pointer arena |
| **07** | **Recursive Fibonacci Calculation** | N=12 | `0.104 ms` | Native procedure activation frames |
| **08** | **Iterative GCD Algorithm** | 10,000 GCDs | `0.681 ms` | `opDiv` integer division & modulo operations |
| **09** | **Nested Conditional Branching** | 500,000 branches | `2.572 ms` | Native conditional jump resolution (`SLJIT_CMP`) |
| **10** | **Scoped Variable Shadowing Access** | 250,000 lookups | `0.817 ms` | Scope stack symbol table isolation |
| **11** | **Linear Scan Register Allocator Speed** | 500 passes | `2.227 ms` | CFG liveness interval calculation |
| **12** | **Stack Frame Spilling Performance** | 250,000 iterations| `1.331 ms` | RegAlloc spill slot memory moves |
| **13** | **Tier 4 Bytecode Interpreter Warmup** | 5,000 iterations | `2.853 ms` | Fast Nim VM bytecode dispatch loop |
| **14** | **Tier 4 Hot Loop Detection & OSR** | 50,000 iterations | `0.168 ms` | OSR live register frame capture & transfer |
| **15** | **Direct SLJIT Native JIT Execution** | 500,000 iterations| `1.224 ms` | Raw SLJIT machine code hardware execution |
| **16** | **Compiler Frontend Throughput** | 200 compilations | `3.220 ms` | Lexer -> Parser -> TypeChecker -> IR pipeline |
| **17** | **Type Checker Symbol Resolution** | 1,000 passes | `1.187 ms` | Compile-time strict static type checking |
| **18** | **Indentation-Aware Lexer Scanning** | 500 files | `1.369 ms` | Whitespace depth tracking & token emission |
| **19** | **Range Iteration (`for i in 1..N`)** | 1,000,000 ops | `3.222 ms` | Native loop increment & comparison |
| **20** | **While Loop State Mutation** | 1,000,000 ops | `1.937 ms` | Conditional backward jumps (`opJumpBack`) |
| **21** | **String Equality Comparison** | 50,000 comparisons| `2.492 ms` | Fast memory comparison helper (`nim_str_eq`) |
| **22** | **Mixed Int & Float Arithmetic** | 250,000 ops | `0.787 ms` | Concurrent integer & float register calculations |
| **23** | **Multi-Parameter Procedure Calls** | 25,000 calls | `0.043 ms` | Native `SLJIT_FAST_CALL` / `FAST_ENTER` overhead |
| **24** | **String Arena Allocation & Reset Speed** | 25,000 cycles | `0.100 ms` | O(1) Bump pointer reset (`nim_arena_reset`) |
| **25** | **End-to-End Pipeline Latency** | Full Compilation | `0.041 ms` | Lex-Parse-Type-IR-JIT-Exec in **41 microseconds** |

---

## Key Performance Innovations

1. **Phase 1: Small String Optimization (SSO)**
   - Exact **16-byte packed layout** for `NimStringHeader`:
     - Strings $\le 14$ bytes store character bytes inline directly inside the 16-byte header (`array[14, char]`).
     - Requires **zero heap allocations** and **zero pointer dereferences**.

2. **Phase 1: 8 MB Contiguous Bump-Pointer Memory Arena**
   - Strings $> 14$ bytes and dynamic concatenation results are allocated out of a pre-allocated **8 MB memory pool**.
   - Allocation cost is reduced from a $\approx 200$-cycle OS kernel lock to a **2-cycle pointer addition**.
   - Resetting string memory (`nim_arena_reset()`) is an $O(1)$ operation that clears `arena.offset = 0`.

3. **True On-Stack Replacement (OSR) Live Frame Capture**
   - Tier 4 edge-counting hot-loop detector monitors backward jump instructions (`opJumpBack`).
   - When the threshold is hit, `compileOSRToNative` captures active VM register states (`Table[VRegId, VMValue]`), loads live values directly into SLJIT stack slots/registers, and jumps straight into the native loop header without re-executing pre-loop setup code or resetting state.

4. **CFG Liveness Extension Register Allocator**
   - Computes exact variable liveness intervals (`startInst` .. `endInst`).
   - Automatically detects loop back-edges and extends liveness intervals for loop-carried variables up to the loop back-edge index, preventing physical register clobbering across loop iterations.
