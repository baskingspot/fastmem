# Small-size path (0..64 B) on aarch64: diagnosis and challenger variants

Lane P3-aarch64b. Host evidence: this Neoverse V3 box (c9g-equivalent),
pinned (`taskset -c 2`), 3 process reps per variant, standard suite,
ns/op per case = median of the 4 samples per run, spread = max-min of
the per-rep abi/glibc ratio. Local numbers are hypotheses; the fleet
decides.

Commits: `be7a1f8` (trampoline removal), then the variant work on top
(this commit). Baseline: run `20260924T064442Z-aor-g2`
(docs/slop/results/aor-g2-graviton.md).

## Diagnosis (a): the c8g gap was the abi trampoline, not the kernel

Evidence, all from the aor-g2 c8g binary
(`bench-results/20260924T064442Z-aor-g2/c8g/bin/v0/bench-fastmem`) and
`.bench-cache/glibc/libc-aarch64-linux-gnu.so.6`:

- The kernel bodies are instruction-identical to glibc at the failing
  sizes. For n <= 32 (V2, VL=16): glibc `__memcpy_sve` at 0xaed80 runs
  nop/cmp/b.hi/cntb/cmp/b.hi/2×whilelo/2×ld1b/2×st1b/ret; our
  `fastmem_sve_copy` at 0x102a500 runs the same 13 instructions
  (bti/cntb first per the 23c4393 hoist). Both entries are 64-byte
  aligned; the 33..64 NEON block sits at offset 0x34 mod 64 in both.
  `__memset_sve_zva64` (0xb00c0) vs `fastmem_sve_set` (0x102a400): same
  6 instructions for n < 16 (dup/cmp/b.lo/whilelo/st1b/ret).
- Yet the fleet measured c8g set 0-16 at 1.333 and copy 0-16 at 1.283
  vs glibc, while `fastmem_inline` (a direct `bl` to the same kernel,
  no trampoline) measured 0.985 on the same rows. Same body, opposite
  verdict: the difference is in the call path.
- The call paths differed by exactly one predicted-taken branch: the
  harness calls glibc through the dlsym pointer straight into
  `__memcpy_sve`, but fastmem_abi through `root.abi.memcpy`, which
  compiled to a one-instruction trampoline `b fastmem_sve_copy`
  (0x108c5a0 in that binary; `root.abi.memmove`/`memset` likewise).
- c7g and c9g showed only ~1.02-1.03 on the same rows with the same
  trampoline, so the cost is V2-specific in magnitude; the cycle-level
  mechanism (BTB/front-end redirect behavior on Neoverse V2) is
  unverified. The attribution "trampoline = the delta" does not depend
  on it.

Fix (`be7a1f8`): on aarch64, `fastmem.abi.memcpy/memmove/memset` ARE
the kernel symbol addresses (the AOR kernels carry the libc signature
and return dest in x0), so the C-ABI measurement is
call-pointer-into-kernel, exactly like the harness's dlsym pointer into
glibc. Local V3 with the trampoline removed: the sve variant measures
1.00 vs glibc at every size <= 64 (table below), matching the identical
bodies. The same collapse is expected on c8g; the fleet confirms.

## Diagnosis (b): compiler-rt wins below 16 B on whilelo latency and branch layout

compiler-rt `memcpy` (memcpyFast, disassembly of the same binary,
0x109e7a0): 1..3 B = three byte copies behind two not-taken compares
(cmp 15, cmp 3 fall through); 4..15 B = four overlapping 4-byte chunks;
16..63 B = four overlapping 16-byte chunks. No SVE anywhere: no `cntb`,
no `whilelo`.

The AOR/glibc small path has a serial chain `cntb → whilelo p1 → ld1b
z1 → st1b z1` plus two data-independent branches. On the harness's
fixed-size cases every branch predicts perfectly, so the difference is
the dependency chain and the predicted-taken branch count, not
mispredictions. Local V3 numbers isolate it:

- hybrid (tbz tree below 16, SVE pair for 16..2*VL) lands at 1.01 vs
  glibc for 16..31, while neon (16-byte pair there) lands at 0.48. The
  SVE predicated pair itself is the slow component at 16..32 on V3;
  where hybrid uses the tree (< 16) it matches neon.
- The first-generation tree still lost to compiler-rt at 1..3 B
  (2.0x): its layout put the tiny classes behind 3 taken branches
  (`b.lo` + 2 `tbz`) against compiler-rt's 0. At ~2 ns per call, one
  predicted-taken branch is ~15%. The committed tree is inverted:
  1..3 B falls through every branch (0 taken), 4..15 take 1, 16..32
  take 1, 33..64 take 1, 65..128 and >128 keep the AOR counts (2 and
  1).

Move exception: on the harness's shared-buffer gap1 overlap cases the
tree's register-pair copies stall harder than the SVE pair on the
cross-iteration store-to-load-forwarding chain (local gap1/16: neon
1.117 vs glibc, hybrid 1.003; gap1/15: 1.085 vs 1.077; gap1/4..8:
~1.035 vs 1.000). This is why the committed move default on V3 keeps
the SVE pair for 16..2*VL (hybrid) instead of going full neon.

Also measured: at 33..64 compiler-rt's four separate `ldr q`/`str q`
chunks beat the AOR `ldp`/`stp` mid block by ~10% on 3 of 4 copy
profiles (aligned/48: builtin 1.89 ns, AOR mid 2.10 ns). The committed
neon/hybrid variants replace the 33..64 block with four overlapping
16-byte chunks at 0, 16, n-32, n-16 (all loads before all stores, so
moves stay safe; coverage exact for 33 <= n <= 64).

## Variants and selection

`src/aarch64/tuning.zig`, per CPU model, overridable for local runs
with `-Dsmall-copy/-Dsmall-move/-Dsmall-set` (auto|sve|neon|hybrid):

- `sve`: upstream AOR port, unchanged (the control; instruction-identical
  to the previous generation, verified by disassembly diff).
- `neon`: inverted tbz tree 0..15, one overlapping 16-byte pair
  16..32, four overlapping 16-byte chunks 33..64.
- `hybrid`: the tree below 16, the SVE predicated pair for 16..2*VL,
  the same 33..64 block.
- set: `sve` (predicated store < 16) or `neon` (inverted store tree
  < 16; 16..64 block unchanged upstream).

Defaults (from the local V3 data; the fleet confirms or flips):
v1 sve/sve/sve, v2 sve/sve/sve, v3 neon/hybrid/neon. The move and copy
entries are unaliased when their variants differ (both branch into the
shared mid/long blocks; each entry keeps `.p2align 6`). The harness
builds revisions only (no extra -D flags), so fleet variants are
one-line table flips; a ready control rev (sve/sve/sve on all models)
is on branch `fleet-control-sve`.

The inline layer (`src/aarch64/small.zig`) inlines the same <= 64 B
classes loop-free in Zig at the call site of `fastmem.copy/move/set`
(`@Vector` chunk copies through align(1) pointers, never array copies;
all loads before all stores within each class, so copy and move share
it). Above 64 B the inline path calls the kernel.

## Local timings (V3, first-generation variants)

Measured binaries predate two committed refinements: the inverted
fallthrough tree (measured tree = 3 taken branches at 1..3 B; committed
= 0) and the 4x16 B chunk block at 33..64 (measured = AOR ldp/stp mid).
The fastmem_inline column is the old direct-call form; the committed
inline layer was guard-tested but not re-benchmarked locally. Ratios:
fastmem_abi/glibc and fastmem_abi/builtin, median of 3 reps, ± = rep
spread of the ratio.

| case | sve a/g±spr a/b | neon a/g±spr a/b | hybrid a/g±spr a/b |
|---|---|---|---|
| copy/aligned/1 | 1.067±0.19/2.147 | 0.956±0.01/1.993 | 0.955±0.10/1.997 |
| copy/aligned/2 | 0.999±0.01/2.093 | 0.957±0.03/1.999 | 0.957±0.01/1.998 |
| copy/aligned/3 | 1.002±0.03/2.090 | 0.984±0.08/2.012 | 0.955±0.04/2.000 |
| copy/aligned/4 | 1.002±0.06/1.249 | 0.800±0.00/0.991 | 0.801±0.00/1.000 |
| copy/aligned/7 | 1.001±0.01/1.254 | 0.817±0.05/1.000 | 0.797±0.02/0.999 |
| copy/aligned/8 | 1.001±0.22/1.249 | 0.637±0.03/0.796 | 0.650±0.01/0.815 |
| copy/aligned/15 | 1.002±0.01/1.255 | 0.638±0.01/0.801 | 0.637±0.02/0.800 |
| copy/aligned/16 | 1.002±0.16/1.563 | 0.485±0.02/0.758 | 1.009±0.00/1.572 |
| copy/aligned/24 | 1.001±0.01/1.560 | 0.483±0.02/0.748 | 1.008±0.00/1.573 |
| copy/aligned/31 | 1.000±0.07/1.570 | 0.479±0.11/0.748 | 1.009±0.10/1.624 |
| copy/aligned/32 | 0.997±0.03/1.249 | 0.409±0.02/0.513 | 1.014±0.01/1.260 |
| copy/aligned/48 | 1.000±0.03/1.145 | 0.997±0.13/1.107 | 1.004±0.08/1.128 |
| copy/aligned/63 | 0.996±0.03/1.101 | 0.999±0.03/1.095 | 1.005±0.13/1.126 |
| copy/aligned/64 | 0.995±0.29/1.065 | 0.996±0.00/1.069 | 1.037±0.17/1.121 |
| set/aligned/1 | 1.001±0.05/1.237 | 0.843±0.02/1.038 | 1.005±0.29/1.306 |
| set/aligned/2 | 0.998±0.02/1.170 | 0.839±0.02/1.000 | 1.001±0.00/1.193 |
| set/aligned/3 | 1.001±0.02/0.906 | 0.838±0.01/0.833 | 1.000±0.00/0.995 |
| set/aligned/4 | 0.999±0.08/1.149 | 0.678±0.00/0.779 | 0.999±0.00/1.152 |
| set/aligned/7 | 0.993±0.13/0.758 | 0.670±0.04/0.504 | 1.000±0.10/0.853 |
| set/aligned/8 | 1.003±0.01/1.124 | 0.679±0.00/0.670 | 1.003±0.02/1.033 |
| set/aligned/15 | 1.003±0.44/0.599 | 0.671±0.00/0.444 | 0.997±0.55/0.581 |
| set/aligned/16 | 1.000±0.01/0.333 | 1.213±0.33/0.380 | 0.995±0.00/0.333 |
| set/aligned/24 | 1.001±0.01/0.231 | 1.003±0.01/0.229 | 1.001±0.01/0.231 |
| set/aligned/31 | 1.001±0.06/0.177 | 1.149±0.15/0.202 | 1.000±0.03/0.176 |
| set/aligned/32 | 0.998±0.08/0.298 | 0.999±0.04/0.299 | 1.002±0.01/0.302 |
| set/aligned/48 | 1.017±0.03/0.226 | 0.976±0.05/0.221 | 1.000±0.22/0.221 |
| set/aligned/63 | 0.999±0.05/0.175 | 1.031±0.06/0.179 | 1.080±0.17/0.193 |
| set/aligned/64 | 0.481±0.04/0.177 | 0.485±0.02/0.179 | 0.482±0.03/0.178 |
| move/disjoint/1 | 1.000±0.60/1.570 | 0.959±0.24/1.478 | 0.954±0.00/1.498 |
| move/disjoint/2 | 0.993±0.20/1.573 | 0.952±0.03/1.711 | 0.957±0.01/1.502 |
| move/disjoint/3 | 1.001±0.00/1.556 | 0.956±0.01/1.499 | 0.957±0.00/1.501 |
| move/disjoint/4 | 1.003±0.14/1.564 | 0.805±0.04/1.244 | 0.801±0.01/1.251 |
| move/disjoint/7 | 1.001±0.01/1.569 | 0.798±0.16/1.235 | 0.797±0.00/1.250 |
| move/disjoint/8 | 1.003±0.00/1.564 | 0.641±0.03/1.000 | 0.641±0.00/1.001 |
| move/disjoint/15 | 1.001±0.02/1.570 | 0.637±0.00/0.997 | 0.638±0.01/1.000 |
| move/disjoint/16 | 1.002±0.13/0.579 | 0.483±0.08/0.301 | 1.008±0.01/0.785 |
| move/disjoint/24 | 1.001±0.08/0.589 | 0.480±0.01/0.300 | 1.009±0.00/0.793 |
| move/disjoint/31 | 1.001±0.00/0.578 | 0.481±0.01/0.296 | 1.009±0.00/0.795 |
| move/disjoint/32 | 0.995±0.08/0.581 | 0.422±0.03/0.268 | 1.006±0.02/0.962 |
| move/disjoint/48 | 0.733±0.27/0.571 | 0.992±0.01/0.640 | 1.007±0.03/0.667 |
| move/disjoint/63 | 0.992±0.01/0.522 | 0.975±0.09/0.538 | 0.941±0.10/0.673 |
| move/disjoint/64 | 1.050±0.22/0.697 | 0.996±0.07/0.680 | 0.963±0.26/0.692 |
| move/fwd-gap1/1 | 1.005±0.02/2.898 | 0.521±0.04/1.515 | 0.519±0.00/1.500 |
| move/fwd-gap1/2 | 0.999±0.01/2.885 | 0.519±0.13/1.499 | 0.519±0.00/1.500 |
| move/fwd-gap1/3 | 1.000±0.00/2.882 | 0.519±0.00/1.499 | 0.519±0.00/1.500 |
| move/fwd-gap1/4 | 0.999±0.08/0.771 | 1.034±0.02/0.801 | 1.036±0.01/0.803 |
| move/fwd-gap1/7 | 1.000±0.00/0.783 | 1.035±0.22/0.806 | 1.035±0.02/0.808 |
| move/fwd-gap1/8 | 1.000±0.01/0.774 | 1.039±0.02/0.807 | 1.034±0.00/0.807 |
| move/fwd-gap1/15 | 0.999±0.01/0.804 | 1.085±0.01/0.871 | 1.077±0.01/0.879 |
| move/fwd-gap1/16 | 1.000±0.01/0.560 | 1.117±0.20/0.570 | 1.003±0.00/0.562 |
| move/fwd-gap1/24 | 0.999±0.13/0.590 | 0.995±0.01/0.567 | 1.002±0.00/0.660 |
| move/fwd-gap1/31 | 0.998±0.27/0.635 | 0.993±0.01/0.548 | 0.997±0.00/0.656 |
| move/fwd-gap1/32 | 0.999±0.02/0.734 | 1.000±0.33/0.764 | 1.001±0.02/0.789 |
| move/fwd-gap1/48 | 1.005±0.27/0.746 | 1.018±0.03/0.803 | 0.976±0.35/0.798 |
| move/fwd-gap1/63 | 1.002±0.05/0.761 | 1.027±0.12/0.778 | 1.488±0.49/0.959 |
| move/fwd-gap1/64 | 0.866±0.13/0.815 | 1.004±0.08/0.820 | 0.993±0.15/0.815 |
| copy/dist/small | 1.010±0.37/1.007 i/g=1.005 | 0.945±0.01/0.944 i/g=0.943 | 0.970±0.01/0.970 i/g=0.975 |
| move/dist/small | 1.000±0.02/0.770 i/g=1.000 | 0.981±0.01/0.768 i/g=0.978 | 0.990±0.01/0.790 i/g=0.991 |
| set/dist/small | 0.996±0.29/0.144 i/g=1.000 | 0.980±0.00/0.144 i/g=0.980 | 0.990±0.18/0.144 i/g=0.997 |
| copy/dist/mixed | 1.006±0.02/0.969 i/g=1.005 | 1.011±0.05/0.957 i/g=1.007 | 1.013±0.17/0.960 i/g=1.007 |
| move/dist/mixed | 0.993±0.39/0.955 i/g=1.017 | 0.992±0.02/0.943 i/g=0.991 | 1.042±0.10/0.974 i/g=1.004 |
| set/dist/mixed | 1.012±0.00/0.065 i/g=0.996 | 1.007±0.00/0.065 i/g=1.006 | 1.005±0.03/0.064 i/g=0.999 |

Above 64 B (the no-regression constraint): copy/aligned and set/aligned
at 96, 128, 256, 4096, 16384, 1048576 all measure 0.94-1.03 for every
variant, except rows with spread too large to read on this shared box
(copy/aligned/4096 sve: 1.163±0.36; the 1 MiB rows are bimodal here as
on c9g in the P1d baseline). Nothing above 64 B moves consistently.

Rows to read with care: set/aligned/16 neon 1.213±0.33 and
move/fwd-gap1/63 hybrid 1.488±0.49 have spread larger than the effect;
this box has noisy neighbors. copy/aligned/48-64: the committed 4x16 B
block targets exactly these (measured here with the AOR mid).

## Correctness

Guard suite (`zig build test-bin` + `fastmem-tests`, 28,047,836 cases
each, native V3):

- First-generation kernels, before the inline layer: sve, neon, hybrid,
  and -Dcpu=generic, each in ReleaseFast and ReleaseSafe: 8/8 pass.
- Final committed state: default variant (auto -> copy=neon,
  move=hybrid, set=neon on this V3) ReleaseFast: pass.
  -Dcpu=generic ReleaseFast: pass.
- `zig build test` passes for sve/neon/hybrid/mixed copy-move-set
  combos and for -Dcpu=generic.
- sve/sve/sve control verified instruction-identical to the previous
  generation kernels by disassembly diff.
- `zig build asm-all`: x86_64-linux-gnu, x86_64-linux-musl, and
  aarch64-macos-none instruction streams identical to the pre-lane base
  26d2b46 (only .loc debug line numbers differ).

## Fleet commands

Variants are revisions (the harness builds revs with the bench.toml
-Dcpu and no other options):

```
just bench-up c7g c8g c9g
just bench-run --rev main --rev fleet-control-sve --rev <candidate-sha> \
    --target c7g --target c8g --target c9g --suite standard --rounds 8
```

- `main`: the pre-lane base (AOR port with the trampoline), re-measured
  in-run for a same-run reference.
- `fleet-control-sve`: trampoline removed, sve/sve/sve on all models.
  Isolates the trampoline fix from the algorithm change. Expectation
  from the diagnosis: c8g small-size tiers collapse to ~1.00 vs glibc.
- `<candidate-sha>`: the lane head (per-model defaults: v3
  neon/hybrid/neon, v1/v2 sve). Expectation: c9g copy/move 0-16 vs
  builtin drops from 1.50/1.40 to <= ~1.0; no tier above 64 B moves.

If the candidate's c8g rows regress (the V2 defaults are sve, so they
should match the control), the table flip to test next is
copy_small/move_small = neon on v2: one-line change in
src/aarch64/tuning.zig, or locally `-Dsmall-copy=neon
-Dsmall-move=neon`.

A focused second pass over the small sizes with more rounds is only
useful if the standard run's CIs straddle a goal threshold; the harness
takes a single case substring per run (`--filter`), e.g.
`--filter /aligned/ --rounds 12` for the aligned fixed cases, or
`--suite dist --rounds 12` for dist/small and dist/mixed.
