# Graviton small sizes, round 3: n<16-first heads and V1/V2 tree defaults

Lane P3-aarch64c, revised after cross-family review (Opus: ACCEPT WITH
FIXES). Base and control: main `a29a7cc`. Fleet revisions:

- `fleet/p3-armc-head` = `88d7f6a` — the n<16-first kernel heads only.
- `fleet/p3-armc-full` = `a64cf25` — head plus the V1/V2 tuning flips
  and the set n==0 hoist.

The first revision of this lane also moved the inline layer onto
per-model SVE inline asm (commit 528815e). The review measured that
change 2-4x slower for inline move at 16..32 on V3 (disjoint/16..31:
3.0 -> 6.16 cycles; fwd-gap31/24,31: 3.0 -> 12.1; only gap1/16
improved), showed that `asm volatile` defeats comptime constant
folding (comptime sizes 24/48 became the runtime predicated sequence
instead of two `ldr q`/`str q` pairs), and reproduced a silent
truncation trap in its comptime VL=32 class boundary (a
`-Dcpu=neoverse_v1` binary running at VL=16 fails the guard suite from
`copy path=runtime len=33`). That commit is reverted: the inline layer
is main's loop-free NEON classes on every model, and nothing in the
tree assumes a comptime VL any more (kernels bound the predicated pair
by runtime `cntb`).

Raw local data: `.bench-cache/local-p3-armc/` (gitignored; `p3c-*` =
first revision, `p3h-*` = the head-layout experiment below), 3 pinned
processes per binary on this Neoverse V3 host. V1/V2 timing effects
are not measurable here; the fleet decides them.

## Diagnosis 1: the 1..3 B tree sat behind three range checks (c9g)

Fleet run `20260924T102308Z-p3-arm-small` (v2): copy and move at 1..3 B
measure 1.333x compiler-rt on c9g at every profile, CI width ~0.003.
Disassembly (main binary): `fastmem_sve_copy` runs 20 instructions on
the 1..3 path (bti, three range-check pairs, two hoisted address adds,
then the tree), the hybrid move head runs 21, and compiler-rt's
`memmove` runs 14 with the same `lsr`/`sub` shape and zero taken
branches. At ~1 ns per call the loop is front-end bound and the
executed instruction count is the whole effect: 20/15 ~ 1.333.

Fix (`88d7f6a`): the neon and hybrid heads test `n < 16` first and fall
through into the tree; the end pointers move into the 4..15 classes
and the 1..3 class derives its tail index from the count. The 1..3
path is now 15 instructions with zero taken branches (compiler-rt: 14;
the extra one is the BTI landing pad, kept).

Local V3, stable to 0.01 cycles within each process: abi copy/move at
1..3 B goes 4.00 -> 3.00 cycles per call (1.333 -> 1.00 vs
compiler-rt) in the lane's builds and in the reviewer's independent
builds at different code addresses.

### Measured costs of 88d7f6a (real, for the fleet to judge)

These reproduce in the reviewer's builds of 88d7f6a alone, so they are
properties of the head layout, not process noise:

- abi copy at 16..31 B: 3.00 -> 4.00 cycles. The class keeps one taken
  branch and loses two instructions; the extra cycle is the leading
  `b.hs`. The rows still beat both references by a wide margin
  (locally 0.80 vs compiler-rt, 0.64 vs glibc).
- abi copy/aligned/48: 6.0 -> 6.5 cycles (the > 128 check moved into
  the shared gt32 block). c9g's copy/aligned/48 is already a G3
  violation at 1.106; the head makes it slightly worse locally.
- The executed dispatch above 64 B gains predicted-taken branches:
  65..128 goes 2 -> 3 taken and > 128 goes 1 -> 3 taken (the
  > 64 B code blocks themselves are byte-identical to main, verified
  by asm diff).
- inline copy at 96/128 B: +1..2 cycles in the reviewer's measurement
  of 88d7f6a alone. The wrapper is unchanged from main, the abi rows
  at those sizes are flat, and the mechanism is unverified; the fleet
  decides. The same review measured copy dist/small
  `fastmem_inline/glibc` at 0.948 -> 1.01 on 88d7f6a.

### The alternative head layout, measured and rejected

The review suggested `cmp 16; b.lo` with the tree out of line, which
restores main's exact branch sequence at >= 16 (16..31 falls through
with zero taken branches). Measured on this host (3 pinned processes
per binary, cycles per call):

| class | main | 88d7f6a (b.hs, tree in line) | b.lo, tree out of line |
|---|---|---|---|
| copy 1..3 B | 4.00 | 3.00 | 4.00 |
| copy 4..15 B | 3.00 | 3.00 | 4.00 |
| copy n=0 | 3.00 | 3.00 | 4.00 |
| copy 16..31 B | 3.00 | 4.00 | 3.00 |
| copy/aligned/48 | 6.12 | 6.53 | 5.87 |
| move disjoint 1..3 (vs builtin, same process) | 1.00 | 0.75 | 1.33 |

A predicted-taken branch on the 1..3 path costs exactly the cycle the
reorder saved, so the b.lo layout fails the condition "recovers 16..31
without losing the 1..3 fix". 88d7f6a stays; the 16..31 cost goes to
the fleet with it.

## Diagnosis 2: the SVE small paths mispredict V1 (c7g)

glibc selects `__memcpy_sve` / `__memmove_sve` / `__memset_sve_zva64`
on all three Gravitons (`docs/slop/research/hosts/README.md`), and the
fastmem bodies are instruction-identical to them below 16 B. c7g
(Neoverse V1, 256-bit SVE) still fails G3 per case against
compiler-rt, all significant:

- move fwd/bwd-gap1 at 1..3 B: 2.05-2.45x compiler-rt. The predicated
  256-bit masked store does not forward to the next iteration's narrow
  overlapping loads on V1. compiler-rt's byte stores forward. glibc
  pays the same stall, so G2 vs glibc holds; the tier target
  min(glibc, compiler-rt) is compiler-rt here.
- copy, move, set at n == 0: 1.6-2.0x compiler-rt across profiles. The
  SVE head runs `cntb`, two `whilelo`, and the empty-predicate
  `ld1b`/`st1b` pair even at n == 0; on V1 those still cost the chain.
- set at 0-16 B: 1.26x glibc as a tier, with identical bodies. The
  residual is V1-specific behavior of the predicated store path plus
  heavy measurement noise: per call, glibc alternates between ~1.16
  and ~2.31 ns at these sizes within a round, and two builds with the
  same `fastmem_sve_set` bytes at the same address measured 1.76 vs
  2.24 ns at set/aligned/1. The actionable observation is the natural
  experiment in the same run: `fastmem_inline` (which runs the NEON
  tree on every model) beats glibc's predicated store by 2-3x on the
  c7g set rows at 0..16 B (point estimates 0.28-0.61; the CIs are
  wide, for example [0.34, 0.68], but every row lands the same side).

Fix (`a64cf25`): V1 defaults become copy=hybrid, move=hybrid,
set=neon. The move hybrid keeps the SVE pair at 16..2*VL (64 B on V1),
where it beats compiler-rt's stack-spilling 16..63 class (c7g
fwd-gap1/16: 0.61x compiler-rt with the pair). The neon set body tests
n == 0 first (three instructions, one taken branch) so the V1 default
does not inherit the n == 0 failure. Disclosure, per review: the neon
set body takes one predicted-taken branch (`b.hs`) at 16..64 B where
the sve body and glibc take none; that shape is the one already merged
for V3 (a54b3ac) and winning there (0.90 tier vs glibc), but its cost
on V1's 17-64 set tier is unmeasured until the fleet run.

## Diagnosis 3: same V2 exposure, smaller (c8g)

c8g (Neoverse V2, 128-bit SVE) with sve defaults fails G3 at: move
bwd-gap1 1..3 B = 3.86x compiler-rt (same forwarding stall), move
disjoint 1..3 B = 1.02-1.03x, copy 1..3 B = 1.02-1.05x, copy
48/63/64 = 1.02-1.15x. Set passes everywhere on V2 (1.000 vs both
references).

Fix (`a64cf25`): V2 defaults become copy=hybrid, move=hybrid; set
stays sve. Hybrid on V2 puts the tree below 16, keeps the SVE pair at
16..32, and runs the NEON 4x16 B block at 33..64 instead of the SVE
`ldp/stp` mid block. Per review: the 4x16 block is not proven to fix
copy/48 — c9g already runs that block and measures copy/aligned/48 at
1.106 [1.063, 1.159] vs compiler-rt, so the c8g row may remain a G3
violation after the flip. The block swap is still the right default
(it matches the class structure that wins everywhere else at 33..64),
and the fleet run measures it.

Untouched by this lane, recorded so the next one does not rediscover
them: the move gap31 G3 violations at 17..31 B (c7g 1.11-1.34x, c8g
and c9g at 24/31 1.22-1.59x compiler-rt) come from the SVE pair at
16..2*VL, which the hybrid deliberately keeps; and the copy 127/128 B
violations live in the upstream 65..128 block, which this lane holds
byte-identical.

## Why the head commit is a no-op on c7g/c8g

`88d7f6a` changes only the neon and hybrid heads and the neon mid
block. V1/V2 defaults select the sve head, which is byte-identical to
main (verified by asm diff of a neoverse_v1 build), and the neon mid
block is not emitted. So on c7g/c8g the head revision is a control
against itself; the flips are measured exactly once, by
`fleet/p3-armc-full`. On c9g the head changes the copy and move
entries; the inline layer is main's in both fleet revisions.

## Correctness

- `zig build test`: passes on both fleet revisions.
- `zig build install test-bin` builds for `-Dcpu=neoverse_v1`,
  `neoverse_v2`, `neoverse_v3`, and `generic` (ReleaseFast).
- Guard suite (28,047,836 cases each), ReleaseFast:
  - `fleet/p3-armc-head`, native V3 build: pass.
  - `fleet/p3-armc-full`, native V3 build: pass.
  - `fleet/p3-armc-full`, `-Dcpu=neoverse_v1` build run on this V3
    host: pass (the hybrid heads are VL-agnostic via runtime `cntb`,
    so a V1-model binary is correct at VL=16 — this directly
    re-checks the reverted commit's trap).
  - `fleet/p3-armc-full`, `-Dcpu=neoverse_v2` build: pass.
- The reviewer's independent checks on the pre-revert tree: a
  boundary test (sizes 0..130, move gaps -70..70, all three paths)
  passed in 11 build configurations including `-Dcpu=neoverse_v2`
  Fast/Safe/Debug, and a planted one-register bug in the tree was
  caught by the guard suite's abi path.
- Target-hardware V1/V2 timing behavior is unverified locally by
  construction; `bench test` on the fleet covers V1/V2 execution.

## Fleet commands

Run from the lane worktree (`bench test` builds the checked-out tree;
check out `fleet/p3-armc-full` first):

```sh
cd /Users/matt/code/worktrees/fastmem-zig/pi-worktree-a62ef0a5-df22-48b4-9db9-bd18b33bed24-s0-0
git checkout fleet/p3-armc-full
just bench-up c7g c8g c9g
just b test --target c7g --target c8g --target c9g \
    --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug
just bench-run --rev a29a7cc --rev 88d7f6a --rev a64cf25 \
    --target c7g --target c8g --target c9g --suite standard --rounds 8 \
    --label p3-armc
```

Expectations:

- c9g: copy/move 1..3 B vs compiler-rt collapse from 1.333 to ~1.00 at
  88d7f6a; copy 16..31 B pay ~+1 cycle (stay well under both
  references); copy/48 slightly worse; full adds nothing on c9g beyond
  one not-taken `cbz` in set.
- c7g: head is bit-identical kernels; full should bring move gap1
  1..3 B from 2.05-2.45x to ~1x compiler-rt, all-ops n == 0 from
  1.6-2.0x to ~1x, and the set 0-16 tier from 1.26x to ~1x glibc.
- c8g: head is bit-identical kernels; full should fix move bwd-gap1
  1..3 B (3.86x) and copy 1..3 B (1.02-1.05x); copy/48 may remain a
  violation (see Diagnosis 3).
- The >128 dispatch takes three predicted-taken branches instead of
  one under the head layout (both fleet revisions share it); the loop
  dominates at those sizes, and the code blocks above 64 B are
  byte-identical to main.

If full regresses a V1/V2 tier that the head does not, the table cells
flip individually (`-Dsmall-copy/-Dsmall-move/-Dsmall-set`,
auto|sve|neon|hybrid) or by a one-line edit in
`src/aarch64/tuning.zig`.
