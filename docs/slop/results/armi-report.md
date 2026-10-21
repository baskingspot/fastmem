# armi: Graviton small-size gaps (scorecard open gaps 3 and 5)

Lane armi, 2026-09-29. Base: main `efa4fc0`. Branch `armi`, two commits:

- `a7c0c79` — **v1mid**: V1 comptime-VL heads and mid entry (2*VL = 64).
- `c313009` — **set-split**: the generic memset 4..15 class split at 8.

This host is Neoverse V3 with glibc 2.42; the fleet runs glibc 2.40 on
c7g (V1) / c8g (V2) / c9g (V3). V1/V2 timing is unverifiable locally;
the claims below are instruction-level mechanism plus fleet
expectation. Local A/B of the generic set on this V3 host is flat at
the timer's ~0.9 ns quantum (both builds 0.504x glibc at 1..15), so it
proves only "no V3 regression", not the V2 win.

## Variant 1: v1mid (gap: c7g move 96..128 B G2 tier = 1.02, case rows 1.10-1.21)

Hypothesis. The failing rows (move disjoint/fwd-gap4096/fwd-half
96..128 at 1.10-1.21x glibc, run 20260927T162241Z-final-standard) pay
two things glibc's `__memmove_sve` entry does not: the tree-first
`cmp 16/b.hs` (one taken branch) and — inside the shared SVE mid block —
`cmp 64/b.hi`, which on V1 is **always taken**: every head reaches
`cpy32_128` only with n > 2*VL, and 2*VL = 64 on V1's 256-bit SVE. That
dead compare + taken branch is removable without touching any small
path. armh's hybrid_ft removed the head branch instead and paid +16.7%
on every 0..15 row (fleet run 20260928T130025Z-armh); v1mid removes the
mid-block one, which no row below 65 bytes executes.

Change (neoverse_v1 builds only, `vl32 = tuning.on_neoverse_v1`):

- head_sve / head_hybrid ge16: `cmp x2, 128; b.hi long; cmp x2, 64;
  b.hi mid; cntb x6; <pair>` — the 2*VL test against the comptime 64,
  cntb sunk onto the pair path (its only consumer). The pair path
  (0..64) executes the same instruction count as main; everything above
  64 drops one instruction.
- mid_sve: the entry block drops `cmp 64/b.hi` and the dead 33..64
  fall-through. 65..128 goes from 24 instructions/3 taken branches to
  22/2 at 97..128 (glibc runs 21/2) and 22/4 to 20/3 at 65..96.

Assumption, stated once: a neoverse_v1 build runs on 256-bit SVE
hardware. Every Neoverse V1 in existence is Graviton3 (256-bit); the
guard matrix runs the V1 build under qemu `sve-max-vq=2` (VL = 32 B).
On hypothetical 128-bit-VL hardware running a V1 build, 33..64 would
misroute into the 65..128 mid block — the same assumption the tuning
table already makes per model; the fleet never runs a V1 build off c7g.

Expected on c7g: the 1.10-1.21x move rows at 96..128 land ~0.99-1.10
(hybrid_ft's -1 taken branch measured 0.889x on those rows; v1mid
removes the same branch plus two instructions from a different part of
the path). Tier 65-256 1.02 -> ~1.00. `bwd-gap33/127` (1.034 vs
compiler-rt) gets -2 instructions toward ~1.01. Copy 65..128 gets the
same -2/-1 (c7g copy 65-256 = 1.01). The >128 long path drops one
instruction. Nothing below 65 bytes changes shape — no row can trade.

Byte pins: V1 copy 368 -> 336, V1 move hash only (same 192 bytes,
reordered), V1 set unchanged. V2, V3, and generic are byte-identical
to main (the byte gate proves it).

## Variant 2: set-split (gap: c7g/c8g/c9g set 0..16 B baseline vs glibc 1.00-1.14)

Hypothesis. armh gap 3 documented the delta as glibc's 6-instruction
predicated store vs the advsimd memset's tree and stopped at "no
no-SVE shape closes it" — but that analysis only considered the 1..3
class. The fleet rows that fail are c8g **1..15** at 1.17-1.21x glibc
(run 20260927T171003Z-final-baseline), and 4..15 is not minimal: main
runs 17 instructions, one taken branch, and four 4-byte stores there
(AOR memset.S's shared 4..15 class with a computed middle offset). The
AOR memcpy-advsimd tree at the same pinned commit splits 4..15 at 8:
two overlapping 4-byte pieces for 4..7, two 8-byte pieces for 8..15.

Change (memset_advsimd.zig, the generic/no-SVE kernel):

- 4..7: `dup; add; str s0; str s0` — 13 instructions, 1 taken branch,
  2 stores (was 17/1/4).
- 8..15: `dup; add; str d0; str d0` — 12/1/2 (was 17/1/4).
- 1..3: the `dup` sinks into the classes that store vector registers,
  off the byte-store path — 14 instructions (was 15), still zero taken
  branches.
- 0, 16..64, and the long path execute the same instruction stream as
  main (the dup relocates within the blocks that use it; counts and
  taken-branch counts are unchanged).

Every store stays sized to its class ([0,n) only), so guard-page tails
stay safe. The split costs one taken branch over a single-class fall-
through, but main's class already took one (`b.hs ge4`); the count is
unchanged.

Expected on the baseline builds: c8g set 4..15 rows 1.17-1.21 -> ~1.0
(-4/-5 instructions and -2 stores against a 1.26-1.29 ns row), tier
0-16 1.14 -> ~1.03-1.05 (1..3 keeps most of its gap: 14 instructions
vs glibc's 6 is the documented structural floor without SVE). c7g's
1.000 rows hold or improve (fewer instructions, same branch count).
c9g's 0.50-0.62 wins improve. set 16..64 and >64 cannot move (same
stream). The remaining c8g 1..3 residual is the documented structural
gap; closing it needs the predicated store, which the generic build
cannot execute.

Byte pins: generic set 348 -> 364, hash e8af0817…. Generic copy/move,
and all SVE-target kernels, byte-identical to main.

## Gap not attacked: c7g move fwd/bwd-gap31 16..31 (1.17-1.83x compiler-rt)

No variant fielded. After itemizing the armh fleet data, every head
shape that fixes these rows trades a currently-passing row; the proof
sketch below is so the next lane does not re-derive it.

The numbers (run 20260927T162241Z-final-standard, c7g move,
fastmem_abi/glibc with glibc ns):

- glibc's SVE pair runs 2.31 ns flat on disjoint/gap4096/gap33 16..32
  and on fwd-gap31/16; our rows sit at 1.000-1.167x already
  (bwd-gap33/31 = 1.167 and fwd-gap4096/31 = 1.120 are current G2 case
  violations).
- glibc pays 4.74-5.65 ns on the gap1/gap31/half rows (the V1 masked-
  store hazards); the failing G3 rows live there: bwd-gap31/16-31
  (1.167-1.187x crt), fwd-gap31/24-31 (1.820-1.829x crt).
- An ABI NEON pair costs ~2.7-2.9 ns (armh's neon32 measured 2.70-3.08)
  because reaching it takes two taken branches (the `b.hs` at 16, then
  the branch off the pair's fall-through). glibc's fast case is 2.31,
  so any row rerouted to NEON lands at 1.17-1.26x glibc. neon32 did
  exactly this and was rejected: disjoint/16 = 1.332, gap33/16 =
  1.143, fwd-gap4096/16-31 = 1.12-1.17, dist/small = 1.100 SIG (fleet
  run 20260928T130025Z-armh).

Why every alternative fails:

- **Exact-16 special-case (neon32's `b.eq`)**: +0.4 ns on n = 16 rows
  that sit at 1.000x glibc. Dead.
- **Tree out of line (hybrid_ft)**: +1 taken branch on 0..15 = +16.7%
  on rows at exactly 1.000x compiler-rt. Dead.
- **Alignment gate (`orr/tst/b.ne`)**: cannot separate the row pairs
  that need opposite treatment. fwd-gap31/16 (src = +31, dst aligned)
  must keep the SVE pair (glibc 2.31) while fwd-half/16 (src = +8)
  wants NEON (glibc 4.83); both are "src-misaligned, n = 16". A
  granule-crossing gate (`(dst&31)+n > 32` / `(src&31)+n > 48`)
  separates all suite rows correctly but costs +8 instructions and a
  taken branch on the non-crossing path: disjoint/24 goes 2.31 -> ~2.9,
  1.26x glibc. Dead.
- **NEON as the 16..32 fall-through with early loads** (12
  instructions/1 taken, ~2.0-2.3 ns — the only shape that holds the
  aligned rows): the 33+ paths then pay the wasted q0/q1 loads and a
  taken `b.hi`; disjoint/48 (already 1.068x glibc) goes to ~1.2. Dead.
- **Single-vector SVE for n <= VL** (drop the empty-predicate second
  ops): the masked-store hazard is in the first vector's store; even a
  generous estimate lands fwd-gap31/24 at ~1.2-1.5x crt. Dead.

The structural floor: glibc's memmove entry has no 16-test at all (the
predicated pair covers 0..2*VL uniformly), so it spends zero taken
branches where our 1..3-safe tree spends one, and its fast case equals
our current cost. The slow rows carry 2-3 ns of slack but reaching the
NEON pair costs two taken branches; the fast rows have zero margin and
sit one test earlier. No dispatch ordering moves a taken branch from
the zero-margin rows to the slack rows, because the size-32 boundary
test itself is the taken branch. What remains is the residual named in
the report: fwd-half/16 (1.039) and fwd-half/48 (1.491) also fail G3
today and are the same mechanism.

Possible future lever, not pursued: a per-model inline-only mitigation
cannot help (G3 is the ABI comparison). A V1 move head that serves
16..31 as two 8-byte GPR pairs instead of the NEON q pair was not
measured; it has the same dispatch cost as the NEON pair, so it lands
in the same 1.17-1.26x window on the aligned rows.

## Validation (this host, aarch64 NixOS)

| Check | Result |
|---|---|
| `zig build test` (native V3) at tip | pass (exit 0) |
| `zig build test` at `efa4fc0` baseline | pass |
| `zig build test-export-arm-bytes` at tip | PASS x4 (generic, v1, v2, v3) |
| same at `a7c0c79` alone (memset change stashed) | PASS x4 |
| Guard matrix, generic build, native, ReleaseFast | 28,047,836 cases pass |
| Guard matrix, V1 build, qemu `sve-max-vq=2`, ReleaseFast | 28,047,836 cases pass |
| Guard matrix, native V3 build, ReleaseFast | 28,047,836 cases pass |
| `zig build install` all 7 bench.toml rows + x86_64/generic baselines | pass |
| `zig build test-generic-set` | pass |
| `ziglint src/` | 10 findings, identical set as main |
| `zig build codegen-x86` | fails **identically on main** (`znver5: set NT helper is unreachable: x86_64.set.streamGrouped` — stale gate after x86h-set48; x86 untouched by this lane) |
| Local generic set A/B (V3 host, 6 rounds interleaved) | flat within the 0.9 ns timer quantum (1..15: 0.504x glibc both builds) |

## Fleet commands

```sh
nix develop . -c just bench-up c7g c8g c9g

# Correctness: tip on c7g (target CPU exercises v1mid) and on all three
# baseline builds (set-split).
git checkout --detach armi && nix develop . -c just bench-test \
  --target c7g --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug

# v1mid: c7g target CPU only (V2/V3 bytes are main's).
nix develop . -c just bench-run --rev efa4fc0 --rev armi \
  --cpu target --target c7g --suite standard --rounds 6 \
  --label armi-v1mid

# set-split: the baseline (generic) builds on all three Gravitons.
nix develop . -c just bench-run --rev efa4fc0 --rev armi \
  --cpu baseline --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armi-set48

nix develop . -c just b analyze bench-results/<run-dir>
```

Read first:

- **armi-v1mid (c7g):** move disjoint/96, fwd-gap4096/96, fwd-half/96,
  disjoint/127-128 (expect 1.10-1.21 -> ~1.0), move 65-256 tier (1.02
  -> ~1.00), bwd-gap33/127 (1.034 -> ~1.01), copy 65-256 tier (1.01).
  Watch for layout luck on unchanged-shape rows: move 1..3 (tree bytes
  shift with the head), move 16..64 all profiles (same instruction
  count, cntb relocated), and the >16K tiers (one fewer instruction on
  the long-path entry).
- **armi-set48 (baseline c7g/c8g/c9g):** set 4..15 per-case on c8g
  (1.17-1.21 -> ~1.0), set 0-16 tier (c8g 1.14, c7g 1.00, c9g 0.64),
  set 1..3 (expect ~-5%: one fewer instruction; the residual stays),
  then the must-not-move rows: set 16..64 and set 65-256 (identical
  instruction stream; c9g 16/24/31 sit at 1.06-1.09 without
  significance — flag if they cross), set dist/small.

Tear down only the Graviton boxes.
