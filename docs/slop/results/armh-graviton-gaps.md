# armh: the remaining Graviton gaps

Lane armh, 2026-09-28. Base: main `6135cac`. Lane branch
`pi-subagents/armh-0ed03b8-e1b1-s0-t0`, code tip `95b1c8a` (the
doc-only commits on top do not change bytes):

- `0cb3bf3` — the V3 copy 97..128 dispatch rework (gap 1).
- `ce61677` — the `hybrid_n32` head machinery (gap 2), default off.
- `b45e58d` — the `hybrid_ft` head machinery (gap 4), default off.
- Review fixes (Opus: ACCEPT WITH FIXES, code correct, no P0):
  - `def4587` — the 65..128 split serves only the V3 copy fall-through;
    gt32/mov_gt32 keep the single upstream block (review item 1), and
    the corrected trace counts below (item 2).
  - `6f397eb` — hybrid_n32's NEON class is 16..31 with the 32 test
    after the 2*VL test (item 3).
  - `95b1c8a` — hybrid_ft drops the padding nop on the >= 16
    fall-through (item 4).

Where this text or these commits disagree with `0cb3bf3`/`ce61677`/
`b45e58d` and the first revision of this document, the later revision
is right.

Fleet variant branches (one-line default flips plus the GOLDEN re-pin
of the bytes the flip changes, on purpose), rebuilt on the post-review
tip:

- `fleet3/armh-move-neon32` = `4fe6b29` (V1 move = hybrid_n32).
- `fleet3/armh-v1move-ft` = `518a3b9` (V1 move = hybrid_ft).

This host is Neoverse V3 (c9g's core), glibc 2.42; the fleet runs 2.40.
V1/V2 timing is unverifiable locally; their claims below are mechanism
plus fleet expectation. Local runs: pinned, interleaved base/head
processes, 4-8 samples x 5-8 ms. Cross-process drift on this box is
about +-5% for C-ABI rows (unchanged 1 MiB long-path rows moved
+-5-9% between the A/B binaries); sub-5% deltas are marked as such.
Evidence JSONL and the A/B binaries live in `.bench-cache/armh/`.

## Gap 1: c9g copy 97..128 (fleet misaligned/127 = 1.086, cross-lane/127 = 1.130)

Fleet rows (run `20260927T162241Z-final-standard`, abi/glibc):
cross-lane/127 = 1.130 [1.095, 1.208] (3.48 vs 3.05 ns; the only
remaining G2 case violation in the class), misaligned/127 = 1.086,
aligned/128 = 1.022, page-offset/128 = 1.019. Vs compiler-rt,
misaligned/127 = 1.352 and misaligned/128 = 1.201 (G3 failures).

Diagnosis. glibc's `__memcpy_sve` at 33..128 is the AOR pair block, on
2.40 (fleet) and 2.42 (this host) identically — the disassembly differs
from upstream only in the entry nop/bti. At n = 127 both sides execute
the same four `ldp` pairs and four `stp` pairs at the same addresses;
the data path is not the gap. The gap is dispatch. The reviewer's qemu
traces (instructions/taken branches, BTI included, V3 copy; verified
against perf instruction counters):

| class | main | this lane |
|---|---|---|
| 33..64 | 18/1 | 18/1 |
| 65..96 | 22/3 | 20/2 |
| 97..128 | 24/2 | 20/2 (glibc: 21/2) |
| >128 head dispatch | 9/2 | 7/2 |

(The first revision of this section and the `0cb3bf3` message claimed
16/1 at 33..64 and 18/2 from 21/3 at 65..96. Those counts were wrong:
the two end-pointer adds removed from the fall-through are replaced by
the cmp96/b.hi pair, so 33..64 is the same length and does not get
faster.)

Change. The V3 copy head's ge16 block is now pure dispatch (the 32 and
128 tests, exactly 16 bytes) and falls into a new mid96 block that
dispatches 96/64; only that fall-through uses the split 65..96 and
97..128 blocks (97..128 keeps glibc's load/store set and order). The
gt32 and mov_gt32 entries keep the single upstream 65..128 block —
routing them through the split cost the move path one taken branch at
97..128 (22/4, was 22/3; review item 1), and with the split gated to
the fall-through, **V2 is byte-identical to main** and the V3 move
entry's live paths are unchanged in shape.

Local V3 (per-process abi/glibc medians, 4 interleaved processes each;
measured at `0cb3bf3`, whose V3 copy path is byte-identical to the
post-fix tip):

| case | base runs | head runs | med base | med head |
|---|---|---|---|---|
| copy/aligned/128 | 1.105 1.111 1.109 1.114 | 1.007 1.000 1.003 1.007 | 1.110 | 1.005 |
| copy/page-offset/128 | 1.106 1.117 1.097 1.111 | 0.993 1.001 0.993 0.997 | 1.108 | 0.995 |
| copy/aligned/127 | 0.966 0.965 0.966 0.967 | 1.009 1.012 1.011 1.011 | 0.966 | 1.011 |
| copy/page-offset/127 | 0.965 0.965 0.967 0.964 | 1.009 1.009 1.010 1.010 | 0.965 | 1.010 |
| copy/cross-lane/128 | 1.015 1.012 1.022 1.032 | 0.997 0.986 1.012 0.987 | 1.018 | 0.992 |
| copy/cross-lane/127 | 1.008 0.994 1.040 0.998 | 1.013 0.980 1.022 1.009 | 1.003 | 1.011 |
| copy/misaligned/127 | 0.961 0.981 1.011 1.025 | 0.954 0.944 1.016 1.018 | 0.996 | 0.985 |
| copy/misaligned/128 | 0.940 0.951 0.913 1.005 | 1.015 0.989 1.047 0.982 | 0.946 | 1.002 |

The reviewer's independent interleaved run reproduces these
(aligned/128 0.903, page-offset/128 0.885, aligned/127 1.048,
page-offset/127 1.047 head/main) and notes that the fleet's failing
rows — misaligned/127 and cross-lane/127 — came out at 0.993 and 0.983,
inside noise: the local run does not show the fix working on the rows
it targets. The 127/128 flip is deterministic (+-0.002 across
processes) and is **not** an instruction effect: within each binary,
127 and 128 execute identical instruction sequences, so opposite
movement is whole-binary layout luck of the kind armd's diagnosis 1
documented (mechanism still unknown). The head binary lands within
1.2% of glibc at both sizes on aligned/page-offset; the base binary won
127 and lost 128 by the same layout luck. dist/small copy moved 0.982x
base (sub-5%, marked as such). Watch rows held: misaligned/48 = 1.000
(the armg pair block), 33..64 within +1%.

Not closed: misaligned/127-128 vs compiler-rt (1.20-1.35). crt's
`memcpy` aligns the source to 32 bytes before its block loop, so three
of its four 32-byte loads avoid the line split that every one of ours
(and glibc's) pays at src_off = 1. Matching that needs the alignment
prologue (about five instructions) on the 65..128 path, which spends
the dispatch budget this change saved on the aligned profiles. Left as
the documented residual; glibc pays the same cost, so G2 holds.

Fleet expectation: c9g copy aligned/page-offset 128 move toward 1.00
and 127 give back the base build's layout luck (fleet 0.969-0.976,
expect ~1.01 — under the 1.10 case bar either way); cross-lane/127 and
misaligned/127 move by the removed dispatch work (4 instructions at
97..128) or not — the local run cannot show it, so the fleet A/B is
decisive. c8g is a drift check: its bytes are main's.

## Gap 2: c7g move fwd/bwd-gap31 at 16..31 (fleet 1.17-1.83x compiler-rt)

Fleet rows (same run, c7g move, abi): fwd-gap31/24 = 5.61 ns,
fwd-gap31/31 = 5.64, bwd-gap31/16-31 = 4.74-4.75 — 1.17-1.83x
compiler-rt (3.08-4.07 ns), significant, G3 failures. fwd-gap31/16 is
the exception at 2.42 ns (0.81x compiler-rt). G2 holds at 1.00
throughout: glibc's `__memmove_sve` runs the identical SVE pair and
pays the same 4.75-5.65 ns.

Diagnosis. The V1 hybrid move head routes 16..2*VL (64 on V1) to the
predicated SVE pair: `cntb; cmp 128; b.hi; cmp 2*VL; b.hi; whilelo x2;
ld1b x2; st1b x2; ret`. The inline layer's NEON pair runs the same
cases in 1.16 ns (fleet fastmem_inline). The pair is fast only when
both addresses are aligned (disjoint/16-31: 2.31 ns, 0.75-0.81x
compiler-rt) and degrades with active-lane count past 16 (fwd-gap31/16
= 2.42 ns vs fwd-gap31/24 = 5.61 ns, same alignments) and with a
misaligned store (bwd-gap31/16 = 4.74). This is the V1 masked-store
behavior p3-armc documented at 1..3; at 16..31 the tier target
min(glibc, compiler-rt) is compiler-rt, whose disjoint-forward path
runs plain 16-byte vector pairs in 3.08 ns.

Variant (`fleet3/armh-move-neon32` = `4fe6b29`). Head `hybrid_n32`:
the tree below 16 unchanged (the 1..3 class has zero G3 margin on V1
and keeps its zero-taken-branch shape); the 2*VL dispatch runs first
(cmp 128, b.hi; cmp 2*VL, b.hi), then `cmp 32; b.lo` sends 16..31 to an
out-of-line overlapping 16-byte NEON pair (the move flavor keeps the
exact-16 single transfer; loads precede stores, so any overlap stays
correct); 32..2*VL keeps the SVE pair. The 65..128 path executes
byte-identically to main (review item 3: the first revision's b.ls
shape lengthened those rows, which already fail G2 on c7g). n = 32
keeps the SVE pair: the only fleet data point for the NEON pair at 32
is inline fwd-gap31/32 at 6.15 ns against the abi pair's 5.59. The
33..64 path pays one extra not-taken cmp32/b.lo pair.

Expected on V1: the five failing gap31 rows drop from 4.7-5.7 ns to
about 1.4-1.7 ns (0.4-0.55x compiler-rt); disjoint 16..31 improve from
2.31 toward ~1.5 ns; 33..64 moves by at most the not-taken compare.
The same mechanism sits inside c7g move dist/small (abi 1.125x glibc —
the shared-buffer mix exercises misaligned 16..31 moves), so watch that
row too.

Correctness: the variant build passes the full guard matrix
(28,047,836 cases) under qemu `sve-max-vq=2`. The head is VL-agnostic
(runtime `cntb`); on a 128-bit-VL build the SVE pair's range is empty
and harmless.

## Gap 3: baseline (generic) set 0-16 vs glibc — documented structural gap

Fleet per-case rows (run `20260927T171003Z-final-baseline`,
abi/glibc): c7g every row 0..16 = 1.000; c9g 1..15 = 0.50-0.62 (the
predicated SVE store is slow on V3) but c9g 16 = 1.057-1.067 and
24/31 = 1.06-1.09 (the neon 16..64 block, not significant at these
CIs); **c8g 1..15 = 1.17-1.21** (1.26-1.29 vs 1.07 ns), 0 and 16 =
1.000. Vs compiler-rt the tier passes with margin 0.16-0.72 on c8g (G6
is the baseline goal; it holds).

The remaining gap is one mechanism: glibc's `__memset_sve_zva64` fills
1..15 with `dup; cmp 16; b.lo; whilelo; st1b; ret` — six instructions,
one store. The generic build has no SVE, so the advsimd memset runs the
inverted store tree: 13-14 instructions, 0-1 taken branches, 3-4
stores. The ~0.2 ns delta on V2 is the instruction count. No no-SVE
shape closes it (a shorter tree needs wider stores, which guard-page
tails forbid at 1..3). Locally the generic build on this V3 host runs
set 1..15 at 0.50x glibc and 0.08-0.60x compiler-rt
(`.bench-cache/armh/generic-set.jsonl`), consistent with the fleet's
c9g rows. armg's gap-2 note predicted exactly this remainder; it is the
documented structural gap, not a regression. No code change.

## Gap 4: dist/small on the Gravitons (G4 target 0.90)

Fleet (abi/glibc, inline/glibc): c7g copy 1.047/1.070, move
1.125/1.033, set 1.023/1.119; c8g copy 0.997/1.014, set 1.001/1.009;
c9g copy 0.942/0.943, move 0.978/0.983, set 0.984/0.984.

- c9g sits at armg's measured floor (0.93 copy, 0.98 move/set). No
  lever left that survives measurement on this host (armd: inlining
  65..256 loses; armg: the mid-entry alias is branch-neutral here).
- c7g move abi 1.125 carries the gap-2 mechanism (misaligned SVE pairs
  at 16..31 in the shared-buffer mix); `fleet3/armh-move-neon32` is the
  measurement.
- c7g set inline 1.119 vs abi 1.023: on V3 the inline layer wins every
  fixed size (set <= 64: 6-7 executed instructions per call against the
  abi path's 22-24, cycles 1.5-2.0 vs 3.0-3.5) and ties the abi row on
  dist/small (0.984 both), so the V1 inversion is not the class shapes.
  A mnemonic-level diff of the V1- and V3-model bench binaries' inline
  loops shows 56/69 timing-loop bodies instruction-multiset identical
  and the rest differing by scheduler-level choices (register
  assignment, independent-instruction order, ldp/stp pairing) — no
  class-shape difference, so codegen is not ruled in. The standing
  suspicion remains armd's diagnosis-1 layout sensitivity on V1. No
  code change; documented so the next lane does not re-derive it.
- The `hybrid_ft` variant (`fleet3/armh-v1move-ft` = `518a3b9`) is
  armg's documented-untried V1 move head with >= 16 on the
  fall-through: zero taken branches in the head for 16..2*VL and the
  mid/long dispatch, targeting the c7g move
  disjoint/fwd-gap4096/fwd-half 96..128 rows (1.10-1.21x glibc, G2 case
  violations). The first revision executed one padding nop on every
  call >= 16 (the .p2align before ge16 landed at +12; review item 4);
  with it dropped, the traced counts are 15/0 at 16..64 (main: 15/1)
  and 23/2 at 97..128 against glibc's 21/2 — the residual is the tree
  tax (cmp16/b.lo) plus one instruction. Predicted to break G3 at 1..3
  (the class sits at exactly 1.000x compiler-rt and pays the taken
  b.lo; p3-armc measured that shape at 1.33x on V3). Run it after the
  neon32 read; reject if 1..3 moves.

## Validation

| Check | Result |
|---|---|
| `zig build test test-export test-dispatch codegen-x86 test-generic-set` at `95b1c8a` | pass (exit 0) |
| `zig build install` all 7 bench.toml rows + x86_64/generic baselines | pass |
| Native guards, V3 build, this host, at `95b1c8a` | 28,047,836 cases pass |
| qemu guards, V1 `fleet3/armh-move-neon32` build (`sve-max-vq=2`) | 28,047,836 cases pass |
| qemu guards, V1 `fleet3/armh-v1move-ft` build (`sve-max-vq=2`) | 28,047,836 cases pass |
| V2 guards | not rerun: after `def4587` the V2 build is byte-identical to main, which the byte gate proves on every run (review P2 note: the earlier lane ran V2 at sve-max-vq=4, wider than V2's real 128-bit SVE; the code in question is VL-agnostic) |
| Arm kernel-byte gate | re-pinned per commit on purpose: V3 copy 576 -> 736 across the lane (the split blocks are additive; the mid96 dispatch replaces the old fall-through). V1, V2, and generic match main's pins on the lane branch; each variant branch re-pins its V1 move bytes (n32: 192 -> 256; ft: hash only) |
| `ziglint src/` | 20 findings (18 pre-existing + two more instances of the flagged `head_*` naming pattern) |
| x86 | untouched; codegen-x86 and test-dispatch pass |

## Fleet commands (no instance launches here)

```sh
cd /Users/matt/code/worktrees/fastmem-zig/pi-worktree-0ed03b89-5a57-4fff-9f61-20ae6135100f-s0-0
nix develop . -c just bench-up c7g c8g c9g

# Correctness: the lane tip on c8g/c9g (its V1 bytes are main's), the
# two variants on c7g.
git checkout --detach 95b1c8a && nix develop . -c just bench-test \
  --target c8g --target c9g \
  --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
for r in 4fe6b29 518a3b9; do
  git checkout --detach $r && nix develop . -c just bench-test \
    --target c7g --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
done

# V2/V3: the mid96 dispatch and split tail (V1 bytes are main's).
nix develop . -c just bench-run --rev 6135cac --rev 95b1c8a \
  --cpu target --target c8g --target c9g --suite standard --rounds 6 \
  --label armh-split96

# V1: the two move-head variants.
nix develop . -c just bench-run --rev 6135cac \
  --rev fleet3/armh-move-neon32 --rev fleet3/armh-v1move-ft \
  --cpu target --target c7g --suite standard --rounds 6 \
  --label armh-v1move

nix develop . -c just b analyze bench-results/<run-dir>
```

Read first:

- **armh-split96 (c9g):** copy misaligned/127 and cross-lane/127 (the
  fleet failures; the local run cannot show the fix working on them),
  then aligned/page-offset 127 vs 128 (the layout-luck pair: expect 128
  at ~1.00 and 127 to give back ~4%), then the watch rows: copy 33..64
  (same length as main per the traces, expect flat), move 96..128
  (byte-shape-identical to main, expect flat), copy/dist/small.
- **armh-split96 (c8g):** pure drift check; every byte is main's.
- **armh-v1move (c7g):** move fwd/bwd-gap31 16..31 on neon32 (expect
  1.17-1.83x -> ~0.4-0.55x compiler-rt), then move 33..64 and
  fwd-gap31/32 (the not-taken cmp32/b.lo; n = 32 keeps the SVE pair),
  then move dist/small (abi 1.125). On ft: move
  disjoint/fwd-gap4096/fwd-half 96..128 (expect the 1.10-1.21x rows
  toward 1.0) against move 1..3 disjoint/gap1 (predicted to degrade
  toward 1.3x compiler-rt — the accept/reject question).

Tear down only the Graviton boxes; another lane holds the x86 fleet.
