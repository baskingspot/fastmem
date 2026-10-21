# Graviton inline layer, round 4: inline-loop re-layout and the mid-entry alias

Lane armd. Base: main `5e78ead` (the layout-clean scorecard run
`20260925T033508Z-scorecard`). Lane branch tip: `a6cceb6`:

- `55f1964` — the inline-loop layout change (target 1).
- `93ec14f` — the mid-entry alias machinery, default off.
- `a6cceb6` — this document.

Variant branch (only diff = the default selection):
`fleet3/armd-midentry` = `4502bc6` (`default_mid_entry = true`).

Revised after cross-family review (Opus: ACCEPT WITH FIXES — the code
is sound; the first revision of this document overclaimed the
mechanism and the dist/small conclusion). This host is Neoverse V3
(c9g's core); V1/V2 timing is unverifiable locally. Every V1/V2 claim
below is a mechanism plus a fleet expectation, not a measurement.

## Diagnosis 1: c8g inline copy 0-16 = 1.16 — mechanism unknown, fixed empirically

The scorecard shows c8g (Neoverse V2) inline copy 0-16 at 1.16x glibc
while the C-ABI kernel measures 1.00 and c9g/c7g inline measure
0.55/0.60. Per-case fleet data (raw samples, c8g, copy/aligned,
inline ns; glibc is flat at ~1.10):

| n | 0 | 1..3 | 4 | 7 | 8 | 15 | 16 |
|---|---|------|---|---|---|----|----|
| ratio | 1.19 | 1.30 | 1.00 | 1.00 | 1.30 | 1.30 | 0.98 |

The class split in absolute time: the 8..15 class runs about +0.3 ns
over {4..7, 16..31} on all three Gravitons (c9g: 1.216 vs 0.912 ns;
c7g: 1.54 vs 1.17; c8g: 1.43 vs 1.09). The {0, 1..3} classes are slow
on V1 and V2 only; on c9g the 1..3 rows run 0.912-0.937 ns, as fast
as everything else. The tier fails only on c8g because glibc's SVE
pair runs in 1.10 ns there (vs 1.9 on c9g, 2.3 on c7g), fast enough
to beat the slow classes.

What is established:

- The runtime-size `runFastmemInline` copy instantiation is
  instruction-identical between the base `-Dcpu=neoverse_v2` and
  `neoverse_v3` builds (mnemonic diff), so this is microarchitecture,
  not codegen.
- On this V3 host, perf counters show the slow 8..15 class executing
  22 instructions in 4.01 cycles while the fast 16..31 class executes
  the same 22 in 3.00. A stall, not extra work.
- Swapping the 8..15 body to d-register (`@Vector(8,u8)`)
  loads/stores changes nothing. Isolated single-class loops show no
  delta, with or without 4K-aliased src/dst. The stall needs the full
  dispatch loop.
- Inserting one `nop` into the harness loop (local diagnostic, not
  shipped) shifts every block by 4 bytes, and 8..15 drops from 4.01
  to 3.00 cycles. The cost follows the block position, not the body.

What is NOT established — the mechanism. The lane's first claim (a
class block entered in the last 8 bytes of a 64-byte fetch line pays
one cycle) fits the V2/V3 base layouts but not V1: in the c7g base
binary the slow blocks start at offsets 24-28 of their 64-byte lines
(8..15 at 28, n==0 at 24, 1..3 at 24) and the fast ones at 40-44,
yet c7g shows the same slow set {0, 1..3, 8..15}. The reviewer's
alternative observation: on V1 and V2 the slow blocks start 24-28
bytes into a 32-byte block while the fast ones start 8-12 bytes in,
and the 1..3 path is also the longest (27 executed instructions per
iteration vs 18-24 for the others). Neither model is confirmed. The
honest statement: the cost is layout- or length-sensitive in a way
that neither this lane nor the review identified, and the fix below
moved the 8..15 block empirically.

## Fix 1 (`55f1964`): invert the inline gate, mark the kernel call cold

In `fastmem.copy`/`move`/`set` (src/root.zig) the gate becomes
`if (bytes > max_inline) { @branchHint(.unlikely); kernel; return }`.
The 7-instruction kernel-call block moves out of the hot region and
the small-class blocks shift. Post-fix block positions (from the
reviewer's disassembly of the fleet builds): on V2/V3, 8..15 moves
off the line end (to offset 32 / 0 respectively), n==0 moves to 28,
and the 1..3 fallthrough stays at offset 56 — the fix does not touch
the 1..3 path. On V1, n==0 moves to offset 60, which the first
revision of this document missed. So the change is not "all hot
entries at 0-48": 1..3 on V2/V3 and n==0 on V1 still sit where the
base cost pattern would put a slow block.

Local V3 (pinned, cycles/iter): copy/aligned and move/disjoint at
every size 0..31 run 3.00 (8..15 was 4.01 — the one clean,
reproduced win); 33..64 and above unchanged; set cycle-identical
locally (but see the watch item below: the set layout did move on
V2); the comptime const-size loops are instruction-identical to base
on all three models (reviewer: all 39 instantiations match, ignoring
nops, branch targets, and constant-pool addresses); x86_64 `.text` is
sha256-identical to main for baseline and all four fleet models
(reviewer, all three binaries).

Fleet expectation (reviewer's arithmetic on the 36 c8g copy 0-16
rows): 1.165 → about 1.094 if only 8..15 is fixed, or 1.070 if n==0
is also fixed — so expect roughly 1.07-1.10, not 1.0. The 1..3 rows
(1.30x) stay, since the diff does not touch that path. When the A/B
lands, read sizes 0-3 on c7g and c8g first.

Watch item (reviewer): on V2 the fixed-size set 16..64 inline loop
head moved from a 64-byte-aligned address to 12 bytes earlier and its
body now crosses a fetch line. Set was verified unchanged on V3 only.
Watch the c7g and c8g set 0-64 inline rows in the A/B.

## Diagnosis 2: dist/small — 0.90 unproven, no lever found in this lane

The case (`src/bench_fastmem.zig`): size = min of two uniform 0..256
draws (about 44% of iterations are ≤ 64 B), random src/dst offsets
≤ 127, a 4096-entry sequence.

The lane's first claim ("structural parity": the inline layer matches
glibc because the > 64 B half calls the same kernel) does not survive
the base fleet run. The C-ABI kernel beats the inline layer on
dist/small on c7g for every op (reviewer's table from the scorecard
raw data):

| op | fastmem_abi / glibc | fastmem_inline / glibc |
|---|---|---|
| copy | 0.954 | 1.003 |
| move | 1.055 | 1.090 |
| set | 0.838 | 0.947 |

The same direction holds for c8g copy (0.997 vs 1.005), c8g set
(1.001 vs 1.018), and c9g copy (0.956 vs 0.964). So the inline
dispatch is a cost under random sizes, not a wash; on c7g set the
kernel alone is already under 0.90. The inline gate at 64 splits the
distribution 44/56 with five tree levels under it, while glibc
reaches 64 B with two branches (n>128, n>2VL). Which side mispredicts
more is unknown — the bench has no branch-miss counter, and the
lane's "~0.7 mispredicts per call each" figure was an unsourced
estimate. Withdrawn.

Also withdrawn: the lane's subpopulation split ("≤ 64 wins 2.2%,
> 64 parity"). It ran with `--dist-file`, and in that mode
`distribution()` draws offsets up to 511 instead of 127 and the full
mix cost 11.55 cycles per call against dist/small's ~8 — a different
workload. Its splits are indicative at best.

What stands (measured against the real dist/small case, local V3):
extending the inline cap to 256 with loop-free overlapping 32-byte
chunk classes made dist/small copy worse (7.95 → 9.00 cycles/iter)
and regressed the 192/255 fixed rows up to 1.37x against the kernel's
SVE long path; set dist/small went 0.983 → 1.112. Not shipped. The
kernel call for > 64 B is strong; no inline-side lever found.

The mid-entry variant (below) is the one remaining candidate lever:
it moves local V3 copy/dist/small from 7.94 to 7.74 cycles per call
(reviewer's pinned measurement; glibc 8.30). Whether that survives on
V1/V2 is a fleet question.

## Variant (`fleet3/armd-midentry` = `4502bc6`): mid-entry alias for > 64 B calls

The inline layer's > 64 B call enters the kernel at its entry, which
re-runs the small-size dispatch the inline gate already decided:
`cmp 16; b.hs` + `cmp 32; b.hi` (neon head) or `cntb` + `cmp 2*VL;
b.hi` (hybrid/sve heads). Those branches are predicted-taken on every
such call, and a predicted-taken branch is measurable on Neoverse V2
at benchmark loop scale (the pre-be7a1f8 abi trampoline cost 1.283x
on c8g 0-16 rows; the same +0.33 ns signature is visible in the c8g
hybrid-move 17..32 rows below).

`fastmem_sve_copy_gt64` is a hidden size-0 label at the shared neon
mid block (`.Lfm_sve_cpy_gt32`). The reviewer verified on all three
models: the alias lands on `cmp x2,#0x80; b.hi long; cmp x2,#0x40;
b.hi 65_128`, the block reads only x0-x2, computes x4-x6 itself, and
clobbers only caller-saved registers; the 65..128 block loads before
it stores and the long path does its own overlap check, so the alias
is valid for copy and move at any n > 64; all 20 call sites are
direct `bl`, so the missing `bti c` is fine. No instruction bytes
change (GOLDEN passes unchanged at both revisions;
check_kernel_bytes.py skips the alias symbol with a comment — without
the skip it fails with `KeyError: 'copy_gt64'`).

Local effect (the reviewer's two pinned runs, which this lane's
first-draft numbers overstated): copy/aligned/96 → 6.47-6.60 cycles
and /127 → 7.58 (reproduce the lane's), but copy/aligned/128 →
7.77-7.79 and move/disjoint/128 → 7.84-7.85 (lane had claimed 7.42 /
7.3). Local C-ABI rows move about ±5% between identical processes, so
treat single-run deltas under ~5% as noise. Expected mechanism benefit
is on V1/V2, unverifiable here.

Correctness status of the variant (reviewer): the fleet `bench test`
in progress covers `a6cceb6`, where the alias has no callers. The
reviewer's one local guard run at `4502bc6` with
`-Dcpu=neoverse_v2` (the config where inline copy > 64 B enters a
block the C-ABI copy never uses) passed 28,047,836 cases in
ReleaseFast; Debug and ReleaseSafe link but never ran. Before the
variant merges, run `bench test` at `4502bc6` on c7g, c8g, and c9g.

## Diagnosis 3: the listed move rows are the hybrid-head price (target 3)

c8g move 17-64 = 1.04: the spikes are disjoint/gap33/gap4096 at
24/31/32 (1.30x glibc). Disassembly: glibc `__memmove_sve` at n=24
executes 11 instructions with zero taken branches
(nop/cmp128/cntb/cmp2VL/pair/ret); fastmem's hybrid head executes the
same pair behind `cmp 16; b.hs` — one predicted-taken branch =
+0.33 ns on V2 = the 1.30x. The hybrid head exists because the tree
below 16 fixes the V2 gap1 1..3 forwarding stalls (3.86x compiler-rt
with the pure SVE head, aarch64c). The alternative layout (b.lo, tree
out of line) was measured by aarch64c to cost the 1..3 class the same
cycle, and 1..3 gap1 is the G3-critical case. The tier passes G2
(1.04 ≤ 1.05). Left as is — a fix needs a head that enters the tree
without a taken branch, and no such aarch64 shape exists.

c7g move 65-256 = 1.04: spikes at disjoint/fwd-gap4096 96..128
(1.09-1.42x) inside the upstream mid/backward dispatch on V1. Not
locally verifiable (V1); tier passes G2. Not touched.

## Validation

- `zig build test`: pass on the lane branch and on `4502bc6`
  (reviewer: 212/212 steps, 30/30 tests).
- Guard suite, ReleaseFast, `-Dmid-entry=on`: 28,047,836 cases pass
  (lane); reviewer's V2-config run at `4502bc6` also passes. The
  variant has no fleet correctness run yet — see above.
- `zig build install` builds for neoverse_v1/v2/v3, aarch64 generic,
  and the x86 fleet models, on both revisions; the all-SVE override
  combo builds with the alias absent (fallback path).
- Kernel bytes: GOLDEN unchanged at both revisions.
- x86_64 `.text`: sha256-identical to main (reviewer: baseline, SPR,
  GNR, znver4, znver5, all three binaries).
- `ziglint src/`: same 16 pre-existing findings as base.

## Fleet commands

```sh
just bench-up c7g c8g c9g
just b test --target c7g --target c8g --target c9g \
    --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
just bench-run --rev 5e78ead --rev a6cceb6 --rev 4502bc6 \
    --target c7g --target c8g --target c9g --suite standard --rounds 8 \
    --label p3-armd
```

(`bench test` at a6cceb6 covers the lane; run it again at 4502bc6
before merging the variant — the alias is live there.)

Expectations:

- c8g inline copy 0-16: 1.165 → about 1.07-1.10 (8..15 fixed, n==0
  maybe, 1..3 untouched). Read sizes 0-3 on c7g and c8g first: if
  1..3 changed at all, the layout model is wrong somewhere new.
- c7g/c9g: unchanged or slightly better on the same rows; watch the
  c7g n==0 rows (its block moved onto a line end) and the c7g/c8g
  set 0-64 inline rows (the set loop head moved on V2).
- `4502bc6` vs `a6cceb6`: 65-256 inline copy/move rows and dist/small
  on c7g/c8g may improve by the skipped predicted-taken branches; c9g
  shows the small local win above. Reject the variant if it does not
  beat the lane beyond noise.
