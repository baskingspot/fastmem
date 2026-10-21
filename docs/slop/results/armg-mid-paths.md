# armg: Graviton mid-size dispatch, baseline memset, and the dist/small floor

Lane armg, 2026-09-26. Base: main `2afc101`. Lane branch
`pi-subagents/armg-138c818-267e-s0-t0`, tip `a11099e`:

- `2bcb48d` — the SVE kernel mid-size rework (gaps 1a and 1b).
- `2236c7f` — the generic (baseline) memset rework (gap 2).
- `a11099e` — the cross-family review fixes (Opus: ACCEPT WITH FIXES):
  the class split described in gap 1a, the corrected gap 1b claims, the
  implementation-name bumps, and the `-Dmid-entry=on` comptime error.
- This document, and the THIRD_PARTY.md attribution line for the
  memset-advsimd tail.

The review verdict was ACCEPT WITH FIXES; the fixes are in `a11099e`
and this document's corrections. Where this text disagrees with the
first revision, this revision is right.

Fleet variant branch `fleet3/armg-midentry` = `ef0dc6c` (gap 3 lever;
flips `default_mid_entry`, one commit on top of `2236c7f`).

This host is Neoverse V3. All V1/V2 timing claims below are mechanism
plus fleet expectation, not measurements. Local runs compare against
glibc 2.42 (the fleet has 2.40), 8 samples x 5 ms, pinned to CPU 2;
cross-process drift on this box is about +-5% for C-ABI rows, so
sub-5% deltas below are marked as such. Evidence JSONL and the patched
binaries live in `.bench-cache/armg/`.

## Gap 1a: c9g copy misaligned/cross-lane 48-64 B (fleet 1.20-1.50)

Fleet rows (run `20260926T112106Z-smallmove-v1`, v1 = current main):
copy/misaligned/48 = 1.499 (1.82 vs 1.22 ns), /63 = 1.390, /64 = 1.328,
cross-lane/63 = 1.262, cross-lane/64 = 1.213.

Diagnosis. The V3 copy head is the neon tree; 33..64 fell into
mid_neon's four 16-byte chunk block (`ldr` x4 / `str` x4 at 0, 16,
n-32, n-16). glibc's `__memcpy_sve` at 33..128 runs the AOR ldp/stp
pair block (c9g glibc disasm, `__memcpy_sve+0x34`: `ldp q0,q1,[x1]`,
`ldp q2,q3,[x4,-32]`, `stp` x2). Locally reproduced exactly:
misaligned/48 = 6.00 vs 4.00 cycles (ratio 1.500, matching the fleet).
The inline layer's 33..64 class (two 32-byte chunks, which LLVM emits
as `ldp`/`stp` pairs) runs the same profile in 4.00 cycles with the
same branch count — so the cost is the chunk block's eight separate
16-byte accesses, not the size class or the dispatch. The chunk block's
aligned/page-offset wins (0.89-0.94) existed only because glibc's pair
block stalls on 4K aliasing there (glibc aligned/48 = 7.00 cycles vs
its own misaligned 4.00; the chunk block runs 6.5 on both). Parity on
those profiles is enough.

The residual after the pair swap (5.00 vs 4.00) was one
predicted-taken branch: the neon head reaches 33..64 through
`cmp 16; b.hs` + `cmp 32; b.hi` (two taken) against glibc's single
`b.hi` after the 2*VL compare.

Changes (`2bcb48d`, class split in `a11099e` after review):

- The neon mid block's 33..64 for the **copy** entry and the gt64 alias
  is the upstream ldp/stp pair block (instruction-identical to what
  glibc executes at these sizes). 65..128 is self-contained again
  (recomputes x4/x5, reloads q0-q3): hoisting those above the 64 check
  measured 3-7% slower at 127-128 in review, and with the revert the
  local misaligned/127-128 rows beat the pre-change binary (13.6/13.8
  vs 14.4/14.4 cycles).
- The V3 copy head inverts the 32 test (`b.ls` to an out-of-line 16..32
  pair block) so 33+ falls through into the mid block: one fewer taken
  branch at 33..128 and above. 16..32 pays that branch instead; its
  local margin is 4.00 vs glibc 6.33 cycles. The head's ge16 block is
  exactly 16 bytes, so the mid entry lands 16-aligned with zero padding
  on the fall-through and the move heads branch to an aligned target
  (the first revision left it at 8 mod 16; review flagged it).
- The **move** entry keeps the chunk block on V3 and takes the pair
  block on V2 (`tuning.move_mid`). Rationale below.
- V2 copy keeps the SVE head; its mid_neon copy is for the move entry.

The G2-vs-G3 trade, disclosed (it decided the class split). The pair
block's wins are the misaligned/cross-lane classes; under 4K aliasing
it loses a few percent to the chunk block. Local V3, 3 interleaved
rounds of the final layout, cycles (base = main's chunk block, head =
this lane):

| Case | base | head | glibc | crt | head/glibc | head/crt (base) |
|---|---:|---:|---:|---:|---:|---:|
| copy/misaligned/48 | 6.01 | 4.00 | 4.00 | 5.00 | 1.000 | 0.80 (1.20) |
| copy/misaligned/63 | 7.33 | 6.72 | 6.13 | 7.59 | 1.097 | 0.89 (0.97) |
| copy/misaligned/64 | 7.42 | 6.92 | 7.16 | 7.69 | 0.967 | 0.90 (0.96) |
| copy/cross-lane/64 | 6.30 | 5.80 | 5.99 | 7.70 | 0.968 | 0.75 (0.82) |
| copy/aligned/64 | 6.19 | 6.88 | 7.00 | 6.53 | 0.984 | **1.055 (0.949)** |
| copy/page-offset/64 | 6.11 | 6.85 | 7.00 | 6.23 | 0.979 | **1.100 (0.982)** |
| copy/aligned/48 | 6.44 | 6.70 | 6.92 | 5.89 | 0.969 | 1.138 (1.093) |
| copy/cross-lane/48 | 6.56 | 6.91 | 6.92 | 5.97 | 0.999 | 1.159 (1.099) |
| move/fwd-half/48 (chunk both) | 6.60 | 6.58 | 8.12 | 9.78 | 0.811 | 0.67 |

The two bold cells are the new G3 risk this change accepts on the copy
side: at exactly 64 B under 4K aliasing, compiler-rt's loop-class entry
is strong and every 33..64 shape I measured lands at 6.7-6.9 cycles
against its 6.5 (chunk: 6.78; pair: 6.87; both mixed-width 3-store
shapes: 6.7-6.8). The fleet base passes at 0.933/0.971; local builds
inflate all shapes by layout, so the fleet A/B makes the call. Note
main already fails G3 at copy aligned/48 (1.187), page-offset/48
(1.159), aligned/63, page-offset/63, and misaligned/127-128
(1.20-1.23) on c9g — the pair block did not create that pattern, it
risks extending it to exactly 64. A runtime alignment dispatch
(`tst x1, 15`) was rejected without building it: its branch costs the
misaligned class the same ~1 cycle the fix is worth. If the fleet
confirms the two cells as failures, the prepared follow-up is an
exact-64 carve-out (a 16+16+32 tail-pair shape, the best measured at
64: 6.73 cycles, 1.03x crt / 0.98x glibc locally).

Move side: the pair block measured +25% at move/fwd-half/48 (6.5 ->
8.1 cycles, reproduced in two layouts) and +9% at fwd-half/64 and
disjoint/64, while every V3 move goal row already passed with the
chunk block (the gap*/64 rows sit at 1.05-1.09, under the 1.10 case
bar). So V3 move keeps the chunk block and is byte-for-byte main's
behavior locally (fwd-half/48: 6.58 vs 6.60). V2 move takes the pair
block as the candidate for its real fleet failure (bwd-gap31/64 =
1.129x glibc, CI [1.119, 1.144]); its G3 margin there is wide
(0.38-0.91 vs compiler-rt). Fleet-unverifiable locally; named in the
read-first list.

Remaining in this area: copy page-offset/255 and aligned/255 (fleet
1.09-1.14). The first revision claimed an improvement to 1.06-1.08;
the reviewer measures 1.11 head vs 1.07-1.10 base, so that claim is
withdrawn — the residual is the tree-first `b.hs` every >= 16 B call
pays against glibc's single 128 check, the deliberate trade that keeps
1..3 B at zero taken branches. move/disjoint/255 (fleet 1.12) is
unchanged locally at 1.03; the V3 move head keeps three taken branches
to the long path.

## Gap 1b: c7g move 96-256 B (fleet 1.09-1.43)

Fleet rows: move/disjoint/96 = 1.125, /127 = 1.271, /128 = 1.422
(3.85 vs 2.70 ns), fwd-half and fwd-gap4096 identical, /256 = 1.091.
Copy at the same sizes runs 0.96-1.07.

Diagnosis. V1 move uses the hybrid head; n > 2*VL (64 on V1) branched
to mid_neon's gt32 entry, which re-runs the 128/64 checks the head
already implies — one more taken branch and two more instructions than
glibc's `__memmove_sve` path (c7g glibc disasm: `cmp 128; b.hi` then
`cntb; cmp 2*VL; b.hi` into the shared mid block at
`__memcpy_sve+0x34`). Fastmem's own copy reaches the same mid block in
fewer branches and runs 2.89 ns at 128.

Change: the hybrid head checks 128 itself and routes (2*VL, 128]
straight to `.Lfm_sve_cpy32_128` (the SVE mid block), matching glibc's
memmove shape (glibc's entry also checks 128 first). V1 no longer emits
mid_neon at all, so the gt64 alias is absent there (root.zig already
guards on `has_gt64_entry`; the mid-entry variant below is a no-op on
V1). V1 guards pass under qemu with `sve-max-vq=2` (28,047,836 cases).

Correction (review, accepted): the first revision of this section
claimed the reroute addresses the 96-128 rows. The reviewer's emulator
traces the old and new heads at VL=32 to identical instruction and
taken-branch counts at 65-128 (21/4 and 23/3 both ways) — the removed
mid-entry re-checks are exactly offset by the new in-head `cmp 128`.
The only measured-mechanism win is at > 128 (30/4 -> 28/3: one taken
branch and two instructions; V1 fleet rows move/disjoint/256 and
fwd-gap4096/256 sit at 1.09x glibc). The 65-128 gap (fleet up to
1.42x at disjoint/128) is the tree-first `cmp 16; b.hs` the hybrid head
shares with the neon head, and this change does not touch it. The
reviewer's suggested variant — a V1 move head with >= 16 on the
fall-through — is UNTRIED, deliberately: it moves the entry branch onto
the 1..3 class, and c7g move disjoint/1-3 sits at exactly 1.000x
compiler-rt (CI [1.000, 1.001]) with zero margin; the gap1/1-3 rows
are the G3-critical classes the tree exists for. If the fleet still
shows the 65-128 rows failing after this, that variant is the next
measurement, with a G3 watch at 1..3.

Watch items for the fleet: V1 move 16..64 pays one extra not-taken cmp
(the pair path is at exactly 1.000 vs glibc today); V1 move 255/256
should improve by the taken branch; V1 copy rows should be
byte-identical in their live paths — only dead code left the symbol.

## Gap 2: baseline (generic) memset vs glibc on Graviton

Fleet rows (run `20260926T044944Z-final-baseline`): set 0-16 = 1.20
(c7g) / 1.43 (c8g) / 0.83 (c9g); 65-256 = 1.09/1.14/1.14;
257-1K = 1.17/1.16/1.16. G6 (vs compiler-rt) already passes everywhere
(0.03-0.67).

Diagnosis, 0-16 B. Per-case, the tier is driven by n=0 (1.33-1.67 on
V1/V2), 1..3 (1.25-1.67), 4..15 (1.17-1.33). The upstream memset.S
tree pays 2-3 predicted-taken branches at 0..3 (b.lo into the tree,
tbz chain, cbz for zero) where glibc's `__memset_sve_zva64` pays one
(`b.lo` into whilelo/st1b). A generic build cannot use the predicated
SVE store — that is the structural limit of this comparison — but the
branch count is closable. (Review trace correction: the inverted tree
drops taken branches at n=0, 9/3 -> 3/1 instructions/branches, and at
1..3, 13/2 -> 15/0; at 4..15 the count does not drop — 14/1 -> 17/1 —
and 16..64 picks up one taken branch, 15/0 -> 16/1. That last trade
measured set/misaligned/24-32 at 1.06-1.09x glibc in the reviewer's
interleaved runs, not the 1.00 I first reported; the fleet 17-64 tier
margin is 0.89-0.90, and the read-first list names the row.)

Diagnosis, 129 B-1 KiB. Local generic-build runs showed a constant
~+4 cycles per call versus the SVE kernel at every size from 129 B to
64 KiB with identical instruction counts (aligned/192: 10.98 vs 7.07;
aligned/16384: 517.7 vs 513.4). The upstream memset.S tail (two
pre-stores `[x0]`/`[x3,16]`, the ungated ZVA check at >128, and the
[x3,32]/[x3,64] store loop) versus the memset-sve.S tail (256-byte ZVA
gate, one pre-store, [x3,16]/[x3,48] loop). I did not isolate the
microarchitectural mechanism (store-to-line completion order is the
suspect); the SVE-shaped tail removes the entire delta, and that tail
contains no SVE instructions, so the generic build may use it.

Changes (`2236c7f`, both in `src/aarch64/memset_advsimd.zig`): the
below-16 tree inverts to the layout the SVE kernel's neon body already
ships (cbz first; 1..3 falls through every branch — taken branches go
3->1 at n=0 and 2->0 at 1..3, while 4..15 keeps its one taken branch
and 16..64 pays one it did not pay before); the >128 tail now follows
AOR memset-sve.S at the same pinned commit (attribution updated in the
file header and THIRD_PARTY.md). Note the ZVA eligibility gate moved
from 129 to 256 bytes: correct and aligned with the SVE kernel, and
invisible to the fleet either way — the benchmark fills with 0xA5 and
ZVA only runs for zero fills; the guard suite covers the zero path
(values 0/0x5a/0xff through 1 MiB).

Local generic-build result: 0-15 B drops to 0.50-1.00 (n=0: 1.66 ->
1.00), 129-1024 B drops to 0.99-1.01, and everything larger stays
1.00. At 16-64 B the tree-first b.hs costs one taken branch the old
layout did not pay: my 8-sample runs read 0.98-1.03 there, the
reviewer's interleaved runs read 1.06-1.09 at misaligned/24-32 — treat
it as a real few-percent cost on the smallest vector class, bounded by
the fleet 17-64 tier margin (0.89-0.90) and named in the read-first
list.
Compiler-rt margins remain >= 0.5x at every measured size. If a 0-16 B
gap to glibc survives on V1/V2 after this, it is the SVE predicated
store, which a no-SVE build cannot express — that remainder is the
documented structural gap, not a regression.

The same tree inversion applied to `memcpy_advsimd.zig` would address
baseline copy 0-16 (fleet 1.21/1.57 on c7g/c8g), but that head checks
16 first only by trading a taken branch onto 17-64, where the fleet
margin is 0.98-1.00 — too thin to touch blind. Left for a lane with
fleet access.

## Gap 3: dist/small on Graviton (G4 target 0.90)

Fleet: copy 1.10/1.01/0.96, move 1.08/0.98/0.98, set 1.10/1.01/0.98
(c7g/c8g/c9g).

New evidence, branch counters. The bench binary's perf group counts
cycles+instructions; I patched it locally (never committed) to count
branches and branch-misses on aarch64. Two host quirks found on the
way, relevant if branch counters ever join the harness: this vPMU
fails to schedule a four-event group (all counters read zero), and
opening branch-misses as a group *member* with `disabled=0` fails
EINVAL on this kernel (members must open disabled and rely on the
group enable ioctl).

dist/small mispredicts on V3, per call (median of 6 x 5 ms samples):
copy: glibc 0.0005, fastmem_abi 0.0004, fastmem_inline 0.0014;
move: ~0.04 for every impl (the shared-buffer overlap workload, not
dispatch); set: 0.0005-0.001. The 4096-entry fixed sequence is learned
by the predictor, so the armd lane's mispredict hypothesis is
disproven for this benchmark on V3 — that is a statement about the
harness's repeating sequence, not about V1/V2 hardware: even at 20
cycles per miss, 0.0014 misses/call is 0.03 cycles. The c7g 1.10
dist/small rows remain unexplained by anything measured here.

Local cycles per call after the kernel changes (glibc 2.42):
copy 8.30 glibc / 7.82 abi / 7.74 inline (0.933); move 15.87 / 15.57 /
15.60 (0.983); set 8.04 / 7.89 / 7.90 (0.983). The kernel changes
above already bought copy about 0.2 cycles versus the pre-change 7.94
the armd lane recorded.

The mid-entry alias on top of that: copy/dist/small inline branches
drop 8.09 -> 6.99 per call with cycles unchanged (7.74 both ways, 6
samples, +-0.5% repeat runs). No local win — the fall-through head
already removed one of the two branches the alias skips. It ships as
fleet variant branch `fleet3/armg-midentry` (`ef0dc6c`) because the
documented benefit was always a V2 mechanism (predicted-taken branch
cost on c8g); V1 no longer has the alias.

Structural floor, stated plainly: on V3 the >64 B half of dist/small
(56% of calls) is a kernel call for both sides, and the <= 64 B inline
half saves the call but pays the gate plus the class tree — under
random offsets the two nearly cancel (abi 7.82 vs inline 7.74). The
0.90 target needs 7.47 cycles per copy call on this box; the only
untested direction left was inlining 65..256, and armd measured that
losing (7.95 -> 9.00). With this harness and distribution the V3 floor
is about 0.93 copy and 0.98 move/set against glibc 2.42; the c9g fleet
numbers (0.96-0.98 against 2.40) already sit at that floor. Nothing
measured here moves c7g copy/set dist/small (1.06-1.10): the V1 live
copy path is unchanged, and its inline half already wins its fixed-size
tiers (0.56/0.72), so the gap lives in the mix itself — the kernel
beats the inline layer under random sizes there (armd's table), and no
lever survives contact with that fact on the evidence I can produce
locally.

Not addressed (leftover from the small-move follow-up, different
levers): c8g move 16-32 at ~1.30 (the +0.33 ns taken branch into the
exact-16 class), c8g move 0-3 at 1.10-1.16, c9g move fwd-gap1/15 at
1.06.

## Validation

| Check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 test-generic-set` at `a11099e` | 348/348 steps, 38/38 tests |
| `zig build install` all 7 bench.toml rows + x86_64/generic baselines at `a11099e` | pass |
| Native guards, V3 build, this host | 28,047,836 cases pass at `a11099e` |
| Native guards, generic build, this host | 28,047,836 cases pass at `2236c7f` (covers the new ZVA gating: values 0/0x5a/0xff through 1 MiB; the memset file is untouched after that commit) |
| qemu guards, V1 build (`-cpu max,sve-max-vq=2`) | 28,047,836 cases pass at the review-fix state (kernel bytes pin-identical to `a11099e`; the later edit is a comptime name string) |
| qemu guards, V2 build (`-cpu max,sve-max-vq=4`, wider than V2's real 128-bit SVE) | 28,047,836 cases pass at `a11099e` |
| `-Dmid-entry=on` on V1 defaults | comptime error (no gt64 alias without a neon head); with `-Dsmall-move=neon` it builds |
| `ziglint src/` | the 18 pre-existing findings |
| Arm kernel-byte gate | re-pinned in each kernel commit, on purpose: V1 copy shrinks (dead neon mid removed, 496 -> 368 B), V1 move head changes (192 B), V2 copy 464 -> 480 B (self-contained 65..128), V2 move byte-identical to main, V3 copy -> 576 B (pair + chunk mid blocks, fall-through head), V3 move hash (branch target), generic set 288 -> 348 B; x86 and generic copy/move bytes untouched |
| `src/bench_fastmem.zig` | at HEAD; the branch-counter patch was never committed |

## Fleet commands (no instance launches here)

```sh
cd /Users/matt/code/worktrees/fastmem-zig/pi-worktree-138c8182-b7bd-45d6-931c-0650fe0135e0-s0-0

# 1. Correctness on the Graviton fleet (target and baseline CPUs).
nix develop . -c just bench-test \
  --target c7g --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug

# 2. Target-cpu A/B (gaps 1a, 1b, and the dist/small movement).
nix develop . -c just bench-run \
  --rev main --rev pi-subagents/armg-138c818-267e-s0-t0 --cpu target \
  --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-mid

# 3. Baseline-cpu A/B (gap 2).
nix develop . -c just bench-run \
  --rev main --rev pi-subagents/armg-138c818-267e-s0-t0 --cpu baseline \
  --target c7g --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-baseline

# 4. Optional: the mid-entry variant (V2/V3 only; no-op on V1).
nix develop . -c just bench-run \
  --rev pi-subagents/armg-138c818-267e-s0-t0 --rev fleet3/armg-midentry \
  --cpu target --target c8g --target c9g \
  --suite standard --rounds 6 --label armg-midentry

nix develop . -c just b analyze <run-dir>
```

Read first in run 2:

- The G2 targets: c9g copy misaligned/cross-lane 48-64 (expect ~1.0
  from 1.20-1.50).
- The accepted G3 risk (the accept/reject criterion for the copy
  change): c9g copy aligned/64 and page-offset/64 vs compiler-rt —
  fleet main passes at 0.933/0.971, local head measures 1.05/1.10. If
  both fail with confidence intervals, the copy pair block needs the
  exact-64 carve-out named in gap 1a.
- The watch cells: c9g copy aligned/48-63 and page-offset/48 vs
  compiler-rt (main already fails at 1.09-1.19; local head is a few
  percent worse), c9g copy cross-lane/48 vs compiler-rt (main 1.040,
  local head 1.159), c9g copy misaligned/cross-lane 96-128 (the
  self-contained revert; local head beats base), c9g move fwd-half at
  48/64/128 and disjoint/64 and bwd-gap31/48 (must equal main: the V3
  move entry keeps the chunk block).
- c9g copy 16-32 (the head inversion's cost side; local margin is
  4.00 vs 6.33 cycles) and every c7g copy row (live code unchanged,
  layout shifted — drift check).
- c7g move: 96-128 separately from 255/256. The reroute only helps
  255/256 (one taken branch); the 96-128 rows are expected to be
  UNCHANGED (identical instructions per the review trace) and remain
  failing — that is reported, not fixed. V1 move 16-64 must hold
  1.00 (it pays one extra not-taken cmp).
- c8g move 33-64, especially bwd-gap31/64 (the V2 pair-block
  candidate; fleet failure 1.129). V2's fwd-half/48-64 rows are the
  regression watch copied from the V3 measurement.

In run 3: baseline set 0-16 on c7g/c8g (expect <= ~1.0 from
1.20/1.43), 65-256 and 257-1K on all three (expect ~1.0 from
1.09-1.17), and baseline set/misaligned 16-48 (the tree-first trade;
reviewer-measured 1.06-1.09 at 24-32 locally, tier margin 0.89-0.90).
