# Runtime CPU dispatch on x86_64 (P7)

An x86_64 build without AVX2 selects its kernels at run time.
One binary for `-Dcpu=baseline` then runs the AVX-512 kernels on AVX-512 hosts and the AVX2 kernels on AVX2 hosts.
Other hosts run the generic kernels.
This document gives the design, the tests, the limits, and the fleet commands.
GitHub issue #1 gives the motivation: handoff ships x86_64 with `-Dcpu=baseline`.

## Scope

Dispatch is active when all of these conditions are true:

- The target is x86_64 Linux with the ELF object format.
- The target CPU does not have AVX2. Examples are `baseline`, `x86_64`, and `x86_64_v2`.
- The build option `-Dx86-dispatch` is true. This is the default.

Every other build keeps the comptime kernel selection of `src/root.zig`.
An AVX2 or AVX-512 `-Dcpu` build contains no dispatch code.
Its codegen probe `.text` is byte-identical to the build before P7 (see "Local evidence").

A consumer disables dispatch with the dependency option:

```zig
const fastmem = b.dependency("fastmem", .{ .target = target, .@"x86-dispatch" = false });
```

## Levels

A level is the `-Dcpu` of one kernel object.
The object of a level contains the kernels of a comptime build for that CPU.

| Level | Required features | Selected on | Tuning row of `src/x86_64/tuning.zig` |
|---|---|---|---|
| `generic` | none | hosts without the full x86-64-v3 set | the generic Zig kernels, compiled for the consumer CPU |
| `x86_64_v3` | x86-64-v3 | AVX2 hosts. Also Skylake-SP, Cascade Lake, Cooper Lake, and Ice Lake. | 32-byte vectors, no REP, no NT |
| `x86_64_v4` | x86-64-v4 | AVX-512 hosts of other models | 64-byte vectors, no REP, no NT |
| `sapphirerapids` | x86-64-v4 | Intel family 6, model 0x8f (c7i) | REP and NT thresholds of c7i |
| `graniterapids` | x86-64-v4 | Intel family 6, model 0xad (c8i) | REP and NT thresholds of c8i |
| `znver4` | x86-64-v4 | AMD family 0x19, Zen 4 model ranges (c7a) | NT threshold, `tiered` |
| `znver5` | x86-64-v4 | AMD family 0x1a (c8a) | NT threshold, `compact` |

The x86-64-v3 check reads these features:

- CPUID.1:ECX: SSE3, SSSE3, FMA, CX16, SSE4.1, SSE4.2, MOVBE, POPCNT, XSAVE, OSXSAVE, AVX, F16C.
- CPUID.7.0:EBX: BMI1, AVX2, BMI2.
- CPUID.80000001H:ECX: LAHF/SAHF, LZCNT.
- XCR0: the SSE and AVX state bits.

The x86-64-v4 check adds AVX512F, AVX512DQ, AVX512CD, AVX512BW, and AVX512VL.
It also adds the opmask, ZMM_Hi256, and Hi16_ZMM bits of XCR0.
The dispatcher executes XGETBV only when OSXSAVE is set.
A model level also requires the full x86-64-v4 set.
Thus a hypervisor that masks AVX-512 on a Sapphire Rapids host gets `x86_64_v3`.

### Why the dispatcher reads the model

The per-model rows contain the only knobs that can make a kernel slower than the untuned row: REP thresholds and NT thresholds.
The fleet measured each row on its own model (`docs/slop/results/p3-x86c.md`, `docs/slop/results/p3-x86d.md`).
A dispatched host therefore runs the same kernel as a `-Dcpu=<model>` build.
An unknown AVX-512 model gets `x86_64_v4`, which has no REP and no NT stores.
That row cannot select REP on AMD, and it cannot start NT stores below the cache size.
This is the most conservative table.
The model numbers mirror the Zig 0.16 host detection (`lib/std/zig/system/x86.zig`, MIT).
`src/x86_64/cpuid.zig` contains the table and the synthetic-CPUID tests.

The dispatcher does not read the CPUID stepping.
Thus Cooper Lake (model 0x55) gets the 32-byte row, but a comptime `cooperlake` build gets 64-byte vectors.
The NT thresholds describe the fleet instance sizes, as in the comptime builds.

## Build structure

Zig 0.16 has no per-function target features (`docs/slop/fastmem-plan.md`, Facts).
One compilation cannot contain baseline code and AVX2 code.
Thus `build.zig` compiles each level as a separate object.

- The root of each object is `src/x86_64/level.zig`.
- The object compiles with `-Dcpu=<level>`, ReleaseFast, LLVM, PIC, `no_builtin`, and `omit_frame_pointer`.
- The object exports the complete `_memmove` and `_memset` kernels, plus `_name`.
- It also exports `_memmove_above128` and `_memset_above128` for the dispatch pointers.
- Each name starts with `fastmem_x86_<id>_<level>`.
- All five symbols have hidden visibility. They never reach `.dynsym`.
- The fastmem module receives the six objects through `Module.addObject`.
- The level objects get the `fastmem_options` of the public module.
  Thus `tuning.zig` applies the same per-model variant and experiment selection as in a comptime build for that CPU.

### Symbol names

`<id>` is a 16-digit hex id of the package instance (`instanceId` in `build.zig`).
Zig creates one `std.Build` for each pair of build root and user options.
The id hashes the same pair.
A fetched package uses its build root relative to the global cache, so its id does not depend on the cache location.
The resolvers and the generic entries also carry the id: `fastmem_x86_<id>_resolve_memcpy`, `fastmem_x86_<id>_generic_memcpy`.

Hidden visibility does not prevent collisions inside one link.
Two fastmem package copies in one executable therefore need different names.
The id also makes the generated `fastmem_options` files of two copies differ.
Without that, two identical options files share one cache path, and Zig rejects the compilation: "file exists in modules 'fastmem_options' and 'fastmem_options0'".

`Module.addObject` propagates in Zig 0.16.
`std.Build.Step.Compile` collects the link objects of every module in its module graph.
Thus an executable that imports `b.dependency("fastmem", ...).module("fastmem")` links the objects.
An object artifact (`zig build-obj`) merges them into its relocatable output.
A static library adds them as archive members.
A compiled consumer package proved the dependency path (see "Local evidence").

`Fastmem.configure` in `build.zig` applies the rule to every module of `src/root.zig`.
It sets the `fastmem_options` flags `x86_dispatch` and `x86_test_hooks`, and the `x86_instance` id.
`src/x86_64/dispatch.zig` applies the same rule at comptime, with that flag as the last condition.
Thus a module without the objects never references their symbols.

## Entry points

`src/x86_64/dispatch.zig` holds one function pointer for each operation: copy, move, and set.
Each pointer starts at a resolver function, as a lazy PLT entry does.

1. The first call through any pointer reads CPUID and XCR0. Only a size above 128 bytes reaches a pointer.
2. The resolver selects the level and stores all three pointers.
3. The resolver tail-calls the kernel of the selected level.

Every later call loads the pointer and makes one indirect jump.
There is no global constructor.
Two threads can resolve at the same time.
They store the same values, so the race is benign.
The loads and stores are monotonic atomics, which make the race defined.

`exportSymbols()` exports the C-ABI entries `abi.memcpy`, `abi.memmove`, and `abi.memset` as `memcpy`, `memmove`, and `memset`.
Each entry handles 0 to 128 bytes itself and never reads a pointer for these sizes.
The small classes compile in the fastmem module for the consumer CPU: SSE2 on baseline.
Thus they are the same code for every level.

| Size | Class | Instructions to `ret` (copy / set) |
|---|---|---|
| 0 | return from the tiny class | 6 / 6 |
| 1 to 3 | three bytes (`compact.bytes`) | 14 / 11 |
| 4 to 15 | four 4-byte moves (`compact.quad`) | 21 / 20 |
| 16 to 63 | four 16-byte moves (`compact.quad`) | 23 / 25 |
| 64 to 128 | eight 16-byte moves | 26 / 22 |

Copy retains the compact classes in the table.
Move uses scalar endpoint pairs through 16 bytes and vector endpoint pairs through 32 bytes.
Move uses four SSE2 endpoints from 33 through 63 bytes.
Both operations load every source byte before the first store.
The entry tests the tiny class first, then the 128-byte limit.
Only the tiny class tests zero.
The large path costs six instructions:

```text
cmpq   $3, %rdx
jbe    tiny
cmpq   $0x80, %rdx
jbe    small
movq   copy_fn(%rip), %rax
jmpq   *%rax
```

The first fleet version jumped through the pointer at every size.
The G6 run 20260925T184717Z-p7-dispatch-g6 measured that at 0 to 16 bytes: copy against glibc went from 0.91 to 1.34 on c7i and from 0.85 to 1.53 on c8i.
LLVM 21 does not fold the load into the jump (see "Zig 0.16 limitations").

The model pointers select the internal entries with the `above128` suffix.
These entries reuse the medium classes and large kernels, with `n > 128` as a precondition.
They omit the scalar ladder that the baseline entry already excludes.
The complete kernels remain available for the instruction-equivalence gate.

Above 128 bytes, x86 copy and move use the same bounded level entry.
Their complete comptime entries differ at small sizes.
At the `generic` level, `memcpy` uses the forward-only generic copy.

### Recursion

The resolver runs inside the first memory call of the process.
It must not call `memcpy`, `memmove`, or `memset`, because the pointer still points to the resolver.
Every function on the resolver path uses `@disableIntrinsics()`, in addition to the module `no_builtin`.
The generic kernels call the generic implementations directly, not the public API.

The export audit (`src/export/check.py`) follows direct branches only.
The stubs jump through pointers, so the audit also starts at every `fastmem_x86_*` function.
`dispatch.zig` exports the resolvers and the generic entries with hidden `fastmem_x86_<id>_*` names for this purpose.
The audit found one real recursion during development.
In a Debug build without module `no_builtin`, `Info.select` called `memcpy` for a struct copy.

## Inline layer

A dispatch build cannot inline AVX2 code into baseline code.
Thus the inline operations use their x86 classes up to 128 bytes.
Copy uses `move.small`. Move uses `move.moveSmall`. Set uses `set.small`.
128 bytes is the inline limit of the `x86_64_v3` comptime build.
The ladder compiles for the consumer CPU: SSE2 on baseline.
Larger sizes call through the pointer directly, without the stub.
A comptime size of 128 bytes or less makes no call.

## Introspection and test hooks

- `fastmem.dispatch.level()` returns the selected level, or null without dispatch.
- `fastmem.dispatch.kernelName()` returns the kernel name of the level.
- `fastmem.dispatch.detect()` returns the CPUID facts.
- `fastmem.dispatch.force(level)` selects a level. The CPU must support it.
- `fastmem-tests --x86-level LEVEL` runs the guard suite at one level.

`force` is a test hook. It compiles only when `fastmem_options.x86_test_hooks` is true.
Only fastmem's own test modules set it: the unit tests, the `test-dispatch` unit tests, and `fastmem-tests`.
`fastmem-tests` gets a private copy of the public module with the hooks. Its kernels are the same.
The public module never sets the flag.
A consumer that calls `force` gets this compile error:

```text
error: fastmem.dispatch.force is a test hook; the public fastmem module does not provide it
```

## Tests

`zig build test` includes `zig build test-dispatch`.
That step does these checks:

1. `src/x86_64/check_dispatch.py` inspects the baseline codegen probe.
   It follows each C-ABI entry and runtime inline probe with every size from 0 to 128.
   Each such path must return without a pointer read, a symbol reference, an indirect branch, or an AVX instruction.
   Sizes above 128 must end in the indirect jump through the pointer of the operation.
   The trace covers each immediate comparison boundary and the maximum unsigned length.
   The resolver tables must contain only bounded model entries.
   The bounded entries must omit comparisons against sizes through 128.
   It checks that fixed sizes 1 to 128 make no call and that 129 to 256 use the pointer.
   It checks that every `fastmem_x86_*` symbol is GLOBAL HIDDEN.
2. The same script compares each level object with the comptime codegen probe of the same CPU.
   The kernel functions and every function that they branch to must be instruction-identical.
   A negative check proves that two different levels differ.
   A table of the REP and NT use of each level, stated independently of `tuning.zig`, must match the large paths.
   No level uses REP for a forward overlap: `rep_fwd_gap_min` is null in every row.
3. `src/x86_64/run_dispatch.py` runs the unit tests in ReleaseFast and Debug under seven qemu CPU models.
   The unit tests force every level that the CPU supports.
4. The same script runs `dispatch-probe` under the seven models and checks the selected level.
5. A resolver-trap build (`x86_resolver_trap`, `src/x86_64/dispatch_small.zig`) executes `ud2` in every resolver.
   Under qemu `max` and `Westmere`, it copies, moves, and fills 0 to 128 bytes at three offsets through the C-ABI entries and the inline layer, and both overlap directions through `memmove`.
   Then it prints "small ok", and its first 129-byte call must die with SIGILL.
   The fixture does not call `exportSymbols()`: before `main`, the Zig start code zeroes the TLS area with a memset above 128 bytes, which traps.
   The exported symbols have the addresses of the C-ABI entries (`src/export/check.py`).
6. The unit tests move 12 MiB + 4 KiB with a 4113-byte gap in both directions at every supported level.
   The size is above the AMD NT threshold and the Intel REP threshold.

The export matrix adds an `x86_64-dispatch` row: baseline x86_64 in every link mode.
The collision tests add a baseline x86_64 row.

`zig build test-export-packages` (part of `test-export`) checks the package boundary:

1. Two compile-fail fixtures call `force` through a public module: the public module of the build, and a ReleaseFast baseline x86_64 consumer. Both must fail with the test-hook error.
2. `src/export/two_packages.py` copies the package twice and builds `src/export/two_packages/`.
   The consumer depends on both copies by path. Copy a exports the memory symbols, and copy b serves explicit calls.
   The script checks that the link contains two instance ids with eight dispatch entries each, and it runs the executable.
`src/x86_64/cpuid.zig` tests the selection with synthetic CPUID values of the four fleet hosts and of other models.

## Harness

- A dispatching `bench-fastmem` records the `dispatch` meta object: level, kernel, vendor, family, and model.
  A comptime-selected build emits no `dispatch` field.
  Its meta code is the code of the build before P7, so that the `.text` of the target-CPU binaries does not change.
- The capability comes from the binary. A dispatching binary exports its resolvers, and the codegen evidence in `meta.codegen` names them.
  Analysis requires the `dispatch` object exactly when the evidence names a resolver.
  Analysis rejects a meta record without codegen evidence when a level is expected.
- `bench run --cpu baseline` records the expected level of each x86 target in `dispatch_levels`.
  The expected level is the `zig_cpu` of the target.
  Analysis rejects a raw file with a different level.
- The build step rejects a revision with runtime dispatch (its `build.zig` declares `x86-dispatch`) whose G6 x86 binary has no resolvers.
  A revision without the feature builds a binary without resolvers. No level applies to it, and the report says so.
- `report.md` prints the dispatch state of each variant.
- `bench test` fails the baseline variant when the guard summary names a different level.
- `bench.toml` keeps `baseline_cpu = "x86_64"` on the x86 targets.

## P7b diagnosis and candidates, 2026-09-25

Base: `61e3ba4`. Worktree: `/Users/matt/code/fastmem-zig-p7b`, branch `p7b`.
The code commits are `f43ea0f`, `6e10fda`, `8eefdf9`, and `8c268df`.
These changes have local correctness and codegen evidence, not fleet performance acceptance.
G6 remains pending.

The input runs reside in the P7 worktree:

```text
/Users/matt/code/worktrees/fastmem-zig/pi-worktree-dc8aa4d2-57ea-4929-8422-b718f40e6324-s0-0/bench-results/20260925T223947Z-p7-dispatch-g6
/Users/matt/code/worktrees/fastmem-zig/pi-worktree-dc8aa4d2-57ea-4929-8422-b718f40e6324-s0-0/bench-results/20260925T234846Z-c8a-fwd-comptime
```

The first run compares pre-P7 baseline builds with P7 baseline builds.
Its `v1` binaries contain the P7 kernels.
The second run contains the comptime `znver5` kernel in `v0`.
The interpretation follows the layout cautions in `docs/slop/results/small-path-aarch64d.md`.
Instruction counts establish paths, not cycle savings.

### Zero and byte sizes on all four x86 targets

The old entry tests the 128-byte limit, 16-byte class, and four-byte class before zero.
`f43ea0f` moved zero first and the byte class second.
The review fix `027bc7e` tests `n <= 3` first and tests zero only inside that class.
All byte loads still precede every store, so overlapping moves retain their original source bytes.

The following counts include the first store, or the return for zero.
The compiler-rt counts come from the baseline `c8a/bin/v1/bench-fastmem` binary, not a target-CPU build.

| Entry | Old fastmem, zero | New fastmem, zero | compiler-rt, zero | Old first store, 1–3 | New first store, 1–3 | compiler-rt first store, 1–3 |
|---|---:|---:|---:|---:|---:|---:|
| copy | 10 | 6 | 11 | 15 | 10 | 11 |
| move | 10 | 6 | 8 | 15 | 10 | 13 |
| set | 10 | 6 | 4 | 10 | 5 | 11 |

Compiler-rt copy starts at `0x10a68a0`, move at `0x10a6610`, and set at `0x10a6580`.
Only its memset has the immediate zero return in this binary.
The baseline memcpy also pays its frame prologue and epilogue.
The instruction trace counts the memset alignment nop before its byte loop.

The new byte paths contain 14 instructions for copy/move and 11 for set.
The zero path contains six instructions, with two comparisons and two conditional branches.
The gate enforces these budgets in `src/x86_64/check_dispatch.py`.
The review fix removes the zero test from sizes 4–128 and from the pointer path.
The 4–15 class returns to its pre-P7b instruction count.
The 16–128 classes lose two instructions, but remain one or two above their pre-P7b counts.
These counts do not establish cycle parity.

### c8a copy/aligned/192 and c7a backward-gap15/511,768

The original P7 pointer enters the complete model kernel.
That kernel repeats size decisions that the baseline stub already made.
`8eefdf9` gives the pointer a bounded entry instead.
It preserves every comptime kernel and the complete level kernels.

The bounded move entry starts with this class decision on both AMD models:

```asm
cmpq $0x101, %rdx
jae  larger
vmovdqu64 (%rsi), %zmm16
vmovdqu64 0x40(%rsi), %zmm17
vmovdqu64 -0x80(%rsi,%rdx), %zmm18
vmovdqu64 -0x40(%rsi,%rdx), %zmm19
```

The 192-byte class now takes 12 instructions through return inside the level entry.
The 511-byte class takes 22.
The 768-byte AMD path takes four instructions before the original large kernel.
These counts exclude the six-instruction baseline stub.

The 511-byte case does **not** use a backward loop.
It loads eight ZMM vectors before its first store, irrespective of overlap direction.
The 768-byte case reaches `backward` because the positive destination distance is less than the length.
Thus the bounded entry addresses redundant dispatch, not an alleged common backward-loop defect.
Its effect on the listed confidence intervals remains unmeasured.

### c8a 64–256 KiB disjoint copies

The NT threshold is `0xc00001`, so none of these rows uses NT stores.
In the P7 binary, the aligned address difference passes `testl $0xf00, %ecx` at `0x10231de`.
That selects the backward loop at `0x1023220`, although forward traversal is legal.
Compiler-rt copy uses its forward loop at `0x10a6980`.

The raw medians below describe all recorded samples, not confidence intervals.
The table does not replace the whole-interval acceptance rule.

| c8a P7 row | compiler-rt ns | fastmem ns | glibc ns | compiler-rt instructions | fastmem instructions |
|---|---:|---:|---:|---:|---:|
| copy/aligned/65536 | 678.4 | 880.0 | 815.6 | 12,338 | 2,867 |
| copy/aligned/262144 | 2319.9 | 3468.2 | 3047.6 | 49,202 | 11,315 |
| move/disjoint/262144 | 2752.3 | 3467.1 | 3058.4 | 57,397 | 11,315 |

Both backward implementations lose to compiler-rt despite fewer instructions.
This supports a direction/class hypothesis rather than a dispatch-instruction explanation.
It does not exclude a layout contribution or prove a microarchitectural cause.

`8c268df` selects `forwardSource` for disjoint `znver5` sizes from 65536 bytes until NT takes precedence.
The new `copy_source_min` tuning field is null on every other model.
The benchmark must decide whether this policy beats the old alias heuristic on Zen 5.
Other disjoint profiles remain regression risks, especially the 4K-alias profiles.

### c8a 64 MiB forward overlaps

The comptime run confirms that the dispatcher does not cause this loss.
Its compiler-rt medians span 1.389–1.417 ms for the fixed gaps.
Fastmem spans 2.225–2.480 ms.
The half-length gap measures 2.138 ms for compiler-rt and 2.764 ms for fastmem.

An overlap excludes NT stores before the 4K-alias test.
It also excludes reverse traversal, which overwrites unread source bytes.
REP remains disabled on AMD.
The old path is therefore the temporal forward loop, not NT or the backward alias path.
See `docs/slop/research/x86_64-design.md`, sections 1.4–1.6.

LLVM expands the old four-vector source loop into a 2 KiB iteration.
The comptime compiler-rt loop at `0x10ac890` uses aligned source loads and a 512-byte iteration.
Its load/store pairs alternate instead of four loads before four stores.
The different alignment alone cannot explain the gap4096 case, where both pointers align.
The precise hardware mechanism remains unknown.

`6e10fda` introduces the source-aligned temporal candidate above `0xc00000` bytes on Zen 5 forward overlaps.
The final implementation uses a non-inline `forwardSource` function shared with the disjoint candidate.
LLVM emits eight load/store pairs per iteration:

```asm
vmovaps (%rsi,%rax), %zmm2
vmovups %zmm2, (%rdi,%rax)
# Seven more pairs at offsets 64 through 448.
addq $0x200, %rax
cmpq %rcx, %rax
jb   loop
```

The function saves both endpoints before the loop.
The loop starts at the next source-vector boundary and never reads beyond the source interval.
The saved endpoints cover the prefix and suffix without overlap hazards.
No new path uses NT or REP.
Both baseline and comptime Zen 5 builds select this function.

### Review fixes

Opus accepted the candidates with four P2 fixes and no P0 or P1 findings.
Its independent models passed the following case counts:

- 139,836 baseline entry cases.
- 338,249 bounded-entry cases per level.
- 5,478,957 source-loop cases.

`5202bbc` restores tail transfers from `largeKernel` to `forwardSource`.
Both functions use the same C-ABI signature and return the destination.
The explicit tail-call requirement prevents LLVM from substituting the known destination after a normal call.
The original void call graph remains on models without a source loop, so their code bytes remain identical.

The Zen 5 entry now starts with the distance test, without any push:

```asm
movq %rdi, %rax
subq %rsi, %rax
je   return_dst
cmpq %rdx, %rax
jae  forward_safe
```

The source-loop selections use conditional tail jumps.
Stack saves occur only inside the NT path.
The codegen gate follows each path from a stack save and requires an NT store before any return or external transfer.
It rejects the original P7b object with `non-NT large path saves registers`.

`675f523` enables `temporal_call` when either source threshold is non-null.
The forward-only override now passes `test-dispatch` on all levels.
`9e2edf6` requires both Zen 5 source-loop selectors and aligned full-width loads inside every source loop.
The gate also requires temporal full-width stores and excludes NT, REP, and fences from that function.
Three disassembly mutations fail: absent selectors, unaligned loop loads, and NT stores.

`027bc7e` isolates the zero test inside the tiny class and adds instruction budgets for every class through 128 bytes.
Each pointer accessor now documents its `n > 128` precondition and the ReleaseFast undefined behavior for invalid calls.
`b405294` applies `align(t.abi_alignment)` to both bounded entries.
The `medium_first` dispatch gate passes with that alignment.

### Local evidence and limits

The host is aarch64. QEMU executes AVX2, not AVX-512.
The local guards cannot replace the model-level fleet guards.

| Check | Result |
|---|---|
| `zig build test test-dispatch test-export codegen-x86 --summary all`, after review | 348/348 steps, 36/36 tests pass |
| `zig build`, after review | Pass |
| `zig build test-dispatch codegen-x86 --summary all` | 61/61 steps pass |
| Baseline v3 guard after tiny entry | 28,047,836 cases pass |
| Baseline v3 guard after review fixes | 28,047,836 cases pass, 342 seconds |
| Baseline v3 guard with both source thresholds at 512 | 28,047,836 cases pass |
| Complete level kernels versus comptime kernels | Same instructions and branch destinations, except padding |
| `ziglint src/` | 18 existing findings outside changed files |
| `test-dispatch -Dx86-fwd-source-min=12582913` | Pass |
| `test-dispatch -Dx86-variant=medium_first` | Pass |

The bounded-entry gate traces every small length and every immediate-comparison interval above 128.
It checks the resolver tables, fixed-size inline calls, and runtime inline paths.
The original full-kernel equivalence check remains active.
The new helper requires explicit temporal-loop inlining on Zen 5 to keep both compilation contexts identical.
Those loops remain inside non-inline kernels, not the public inline layer.

The final codegen probe `.text` equals the `61e3ba4` probe on these CPUs:

| CPU | SHA-256 |
|---|---|
| sapphirerapids | `052226caf653ecb969e7e6cc9a9e23fd42ba468cf9ee9f3ef872e8746ea30816` |
| graniterapids | `b91eecc0b2b9d75eb3481a5467ad4f0439b73621939492483a659c3eb484e6a2` |
| znver4 | `2e6e50252cd4655212d6cfd54e09001b72afee85d2359657103b3418d3313af9` |
| x86_64_v3 | `809c8e20fc4217df7a42dfda776cd00ad9c25c46c4a7bcc5e87a06225cc1ea13` |
| x86_64_v4 | `dc0582797311298fd6348db2d67887fc2b4078ab7714533c348f8c42db2e9ca7` |

The unchanged probe includes `x86_64.move.kernel` and all its reachable code.
The post-review probe also matches the pre-review `eec1dd7` probe on all five CPUs in the table.
Zen 5 changes intentionally.
No AWS instance was launched by this lane.

## Zig 0.16 limitations

Each item comes from a compiled experiment.

- No per-function target features. The design uses separate objects for each level.
- The self-hosted x86_64 backend (Debug) rejects `@call(.always_tail, ...)`.
  The error is "unable to perform tail call".
  The stubs and resolvers use a normal call in that backend.
- LLVM 21 does not fold the pointer load into `jmp *mem`.
  The result is the same for `.always_tail`, for a plain call, and for plain, monotonic, and unordered loads.
  `zig cc -O2 -fomit-frame-pointer` on the equivalent C code gives the same two instructions.
  A naked assembly stub can give one instruction. P7 does not use one: it adds an exported data symbol and a second code path for the self-hosted backend.
- `Module.addObject` adds an include directory for each object. The compile command repeats `-I` six times. This has no effect.

## Limits

- Only x86_64 Linux ELF targets dispatch. Other x86_64 targets keep the generic kernels.
- The tuning overrides (`-Dx86-vec` and others) apply to every level object.
  For example, `-Dx86-vec=64` fails the `x86_64_v3` object.
- The dispatch inline limit is fixed at 128 bytes. `-Dx86-inline-max` does not change it.
- qemu TCG does not execute AVX-512. The local runs execute only `generic` and `x86_64_v3`.
  The fleet runs execute the model levels.
- `force` accepts a model level on another model when the CPU has x86-64-v4.
  The kernel is then correct, but its thresholds belong to the other model.

## Local evidence, 2026-09-25

The host is launchpad (aarch64). qemu-x86_64 11.1.1 runs the x86 binaries.
The first table is the state after the review fixes, merged with main 8d43448 (`-Dx86-experiment=auto`).

| Check | Result |
|---|---|
| `zig build test test-dispatch test-export codegen-x86`, after the small-size fix | 348 of 348 steps, 36 of 36 unit tests |
| Resolver-trap build under qemu `max` and `Westmere` | 0 to 128 B pass, 129 B traps |
| Guard suite, baseline musl, after the small-size fix | `x86_64_v3` and `generic`: 28,047,836 cases each, pass |
| `zig build test` | 318 of 318 steps, 36 of 36 unit tests |
| `bench-fastmem` `.text`, main 8d43448 and P7, `-Drev=cmp` | identical for sapphirerapids, graniterapids, znver4, znver5, and x86_64_v3 |
| Codegen probe `.text`, main 8d43448 and P7 | identical for the same five CPUs |
| `test-export-packages` | both hook fixtures fail to compile; two instances link and run (`x86_64_v3` under qemu) |
| Harness | 232 passed, 11 skipped |

The earlier evidence, before the review fixes:

| Check | Result |
|---|---|
| `check_dispatch.py` | stubs two instructions, 9 bytes each. Six level objects identical to the comptime kernels. |
| Codegen probe `.text`, before and after P7 | identical for sapphirerapids, graniterapids, znver4, znver5, and x86_64_v3 |
| aarch64 `asm-all` instructions, Linux | identical. macOS: only the `setFallback` symbol name differs. |
| `test-export-arm-bytes` | all four CPUs match GOLDEN |
| `dispatch-probe` under qemu `max`, `Haswell` | `x86_64_v3` |
| `dispatch-probe` under qemu `SapphireRapids`, `EPYC-Genoa` | `x86_64_v3`: model 143 and family 25 model 17, AVX-512 masked by TCG |
| `dispatch-probe` under qemu `Westmere`, `max,-bmi2`, `max,-movbe` | `generic` |
| Unit tests, ReleaseFast and Debug, seven qemu models | 31 of 31 each |
| Consumer package through `b.dependency`, `exportSymbols()`, x86_64-linux-musl baseline | correct for 0 to 5000 bytes. `x86_64_v3` under `max`, `generic` under `Westmere`. |

The guard-suite results are in "Guard suite under qemu".

## Guard suite under qemu

The binary is `fastmem-tests` for `-Dtarget=x86_64-linux-musl -Dcpu=x86_64`, ReleaseFast.
The musl target gives a static binary that qemu runs without an x86 sysroot.
The maximum size is 1 MiB, the default of a baseline build.

| qemu CPU | Level | Build options | Cases | Result | Time |
|---|---|---|---:|---|---:|
| `max` | `x86_64_v3`, detected | none, after the review fixes and the main merge | 28,047,836 | pass | 352 s |
| `max` | `x86_64_v3`, detected | none | 28,047,836 | pass | 435 s |
| `max` | `generic`, `--x86-level generic` | none | 28,047,836 | pass | 432 s |
| `Westmere` | `generic`, detected | none | 28,047,836 | pass | 389 s |
| `max` | `x86_64_v3`, detected | `-Dx86-rep-movsb-min=512 -Dx86-rep-stosb-min=512 -Dx86-nt-min=4096 -Dx86-memset-nt-min=4096` | 28,047,836 | pass | 604 s |

The last row runs the REP and NT paths of the level object through the dispatch stubs.
It does not test AVX-512 instructions.

## Fleet commands

The parent owns fleet execution and performance acceptance.
These commands use existing instances and launch none.

### Procedure

1. Select the P7b worktree.

```sh
cd /Users/matt/code/fastmem-zig-p7b
```

2. Run the target and baseline correctness matrix.

```sh
nix develop /Users/matt/code/fastmem-zig-p7b -c just bench-test \
  --target c7i --target c8i --target c7a --target c8a \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
```

3. Compare baseline builds with main on all four x86 targets.

```sh
nix develop /Users/matt/code/fastmem-zig-p7b -c just bench-run \
  --rev main --rev WORKTREE --cpu baseline \
  --target c7i --target c8i --target c7a --target c8a \
  --suite standard --rounds 5 --label p7b-g6
```

4. Compare large forward overlaps with baseline c8a builds.

```sh
nix develop /Users/matt/code/fastmem-zig-p7b -c just bench-run \
  --rev main --rev WORKTREE --cpu baseline --target c8a \
  --suite large --filter move/fwd --rounds 5 --label p7b-fwd-baseline
```

5. Compare the same rows with comptime c8a builds.

```sh
nix develop /Users/matt/code/fastmem-zig-p7b -c just bench-run \
  --rev main --rev WORKTREE --cpu target --target c8a \
  --suite large --filter move/fwd --rounds 5 --label p7b-fwd-comptime
```

6. Analyze each run.

```sh
nix develop /Users/matt/code/fastmem-zig-p7b -c just b analyze <run-dir>
```

7. Apply the whole-interval rule to each G6 row.
8. Reject candidates with significant regressions in other profiles.
