# x86 small ABI entry: P3-x86b

Status: local checks pass except the pending full Debug guard run under qemu. Hardware correctness and performance remain acceptance gates.
The baseline is `36c960f`. The fleet evidence that motivates this change is `docs/slop/results/x86-g2-v1.md`.

## Entry diagnosis

The old copy/move kernel has no stack frame or `vzeroupper` on its scalar paths.
Its small-size cost comes from the descending dispatch ladder and a separate ABI wrapper jump.
For one byte, eight conditional branches precede the load.
The old set kernel uses a masked ZMM store for small sizes away from page boundaries.
It also shares the zero-length return with a vector cleanup block.

The new ABI names directly alias the x86 kernels. Sizes through 16 bytes use scalar head/tail operations.
Sizes 17–32 use XMM head/tail operations. These paths contain neither a frame nor `vzeroupper`.
The default high-register variant keeps all classes through 512 bytes in the entry.
The pure-Zig variant separates the medium classes, so LLVM cannot merge scalar returns with vector cleanup.

The table counts executed instructions through the first destination store, inclusive. It excludes the caller and padding instructions.
The glibc count includes `endbr64`. The old fastmem count includes its ABI wrapper jump.

| Entry | 1 B | 4 B | 8 B | 15 B |
|---|---:|---:|---:|---:|
| Old fastmem copy/move, all four fleet CPUs | 20 | 19 | 17 | 17 |
| New fastmem copy/move, all four fleet CPUs | 12 | 11 | 9 | 9 |
| Old fastmem set, page-safe masked path | 18 | 18 | 18 | 18 |
| New fastmem set, Sapphire/Granite Rapids | 11 | 11 | 10 | 10 |
| New fastmem set, Zen 4/5 | 12 | 11 | 11 | 11 |
| glibc copy/move, Sapphire Rapids | 17 | 15 | 13 | 13 |
| glibc set, page-safe masked path | 12 | 12 | 12 | 12 |
| compiler-rt memcpy, Sapphire Rapids | 11 | 14 | 14 | 14 |
| compiler-rt memmove, Sapphire Rapids | 13 | 15 | 15 | 15 |
| compiler-rt memset, Sapphire Rapids | 10 | 10 | 14 | 10 |

Zen schedules some return-register moves before the store. The new one-byte set path still totals 13 instructions on every fleet CPU.
The new copy/move totals are 14, 14, 12, and 12 instructions for the four sizes.
Each return moves the destination to RAX once. No argument shuffle precedes the scalar copy loads.
compiler-rt memcpy uses a frame at these sizes. Its memmove delays the frame until 16 bytes.
compiler-rt memset uses byte stores, with a separate eight-byte unrolled loop.

Sources:

- `src/x86_64/check_codegen.py`: executable path traversal and instruction budgets.
- `.bench-cache/p3-x86b/baseline-entry-counts.json`: counts from the original objects.
- `.bench-cache/p3-x86b/final-codegen.jsonl`: counts from the new objects.
- Original glibc object: `.bench-cache/glibc/libc-x86_64-linux-gnu.so.6` in the main checkout.
- glibc copy/move: entry `0x196380`, scalar blocks `0x1963b7`, `0x1963d0`, and `0x196432`.
- glibc set: entry `0x196c00`, masked block `0x196bc0`.
- Original compiler-rt binary: main checkout `.bench-cache/build/97994961ef06579582e940c19fd6307d2601767878702d43b483f24562313a00/bin/bench-fastmem`.
- compiler-rt entries: memcpy `0x10a2350`, memmove `0x10a1fc0`, and memset `0x10a1f30`.

The glibc observations describe behavior only. This change contains no glibc source or disassembly.
Instruction counts do not establish timing parity.

## Variants and scope

| Build option | ABI classes 33–512 B | Purpose |
|---|---|---|
| `-Dx86-variant=high_regs` (default) | Independent head/tail fragments in registers 16–23 | Remove vector cleanup and the masked-store page test |
| `-Dx86-variant=entry` | Existing Zig vectors and optional small set mask | Isolate the scalar entry improvement |

High-register fragments require LLVM, AVX-512BW, AVX-512VL, and 64-byte tuning.
Debug and AVX2 retain the pure-Zig medium classes. The inline layer retains its original classes in both variants.
The entry-only revision is `f1638dc`. The current worktree selects `high_regs` by default.

The high-register variant targets copy 33–256 and set 65–256 without a `vzeroupper` cost.
The tail transfer above the straight-line classes removes the entry push/call/pop sequence and the redundant set cleanup.
These changes also target mixed distributions. No timing claim accompanies them.

Large-loop algorithms and thresholds remain unchanged by default. The C return adapters change their call boundaries and register allocation.
The NT prefetch condition and per-store address calculations remain unchanged. They do not affect the requested small-size gaps.
Skylake-X, Cascade Lake, and both Ice Lake models now select 32-byte vectors.

`-Dx86-rep-fwd-gap-min=4096` permits REP for forward overlap with gaps of at least 4096 bytes, inside the existing REP size window.
The default remains vector-only for forward overlap. Values below 256 cause a compile error.
The binary adds only two move profiles: `fwd-gap4096` and `fwd-half`.
The latter uses `n / 2`. Small sizes can describe disjoint or identical ranges rather than overlap.

## Local validation

| Check | Result |
|---|---|
| Native `zig build test`, Debug/ReleaseSafe/ReleaseFast | 27 tests pass in each mode |
| Native `zig build -Doptimize=ReleaseFast` | 11 build steps pass |
| Harness tests | 206 pass, including native binary integration |
| Ruff and type checks | Pass |
| Codegen, both variants | Pass on Sapphire Rapids, Granite Rapids, Zen 4, Zen 5, and x86_64_v3 |
| Codegen with the 4096-byte REP gap override | Pass on all five CPUs |
| Older Intel assembly | YMM present and ZMM absent on all four selected models |
| aarch64 Neoverse-V2 assembly | All 164 instruction lines match the baseline |
| x86_64_v3 ReleaseFast unit tests under qemu | 25 pass |
| x86_64_v3 units with REP threshold/gap overrides | 25 pass |
| Full x86_64_v3 ReleaseFast guard suite under qemu | 28,047,836 cases pass, 359 seconds |
| Full x86_64_v3 Debug guard suite under qemu | Pending, PID 2042871 |
| `ziglint src/` | Only existing warnings outside modified files |

The qemu binaries use `x86_64-linux-musl` with libc linkage. The full matrix reaches 1 MiB.
AVX-512 execution requires the fleet because this qemu build supports AVX2 only.
The supervisor approved the pending Debug run and will read its result later.
Its result is `.bench-cache/p3-x86b/qemu-debug.json` in this worktree. Its exit status goes to `.bench-cache/p3-x86b/qemu-debug.exit`.
All 2,049 decoded x86 instructions in that binary match the later Debug build after address normalization.

## Fleet procedure

Run hardware correctness for all three modes:

```sh
W=/Users/matt/code/worktrees/fastmem-zig/pi-worktree-126009ee-2359-462a-bdfe-1ba3a5e6a739-s0-0
cd "$W"
nix develop "$W" -c just b test \
  --target c7i --target c8i --target c7a --target c8a \
  --optimize ReleaseFast --optimize Debug --optimize ReleaseSafe
```

Run the standard five-round comparison:

```sh
nix develop "$W" -c just b run \
  --target c7i --target c8i --target c7a --target c8a \
  --rev main --rev WORKTREE --suite standard --rounds 5 \
  --label p3-x86b-small-entry
```

For the entry-only comparison, add `--rev f1638dc` to the same command.

## Residual risks

Hardware G1 and G2 remain pending. The high-register fragments need guard coverage on AVX-512 hardware.
A branchy scalar set can lose against masking on random small distributions. The fleet must decide that tradeoff.
The pure-Zig variant retains a medium-entry tail jump. The high-register variant does not.
The REP forward-gap choice remains an explicit experiment, not a new default.
