# fastmem aarch64 design memo (P1c)

Status: revised after Opus 5.5 review (all P0–P2 findings addressed;
points of disagreement are listed at the end). Scope: c7g (Neoverse V1),
c8g (Neoverse V2), c9g (Neoverse V3). Author lane: P1c research.
Parent rulings applied: AOR global-asm port is the G2 C-ABI baseline
(pure-Zig is the challenger); the G4 inline runtime path uses the
kernel's size classes including the SVE fragment; the ZVA path keeps
the runtime DCZID_EL0 check.

Ground truth: all three Graviton targets run the same glibc 2.40 binary
(`/nix/store/jjjpj4p9bz505ac1c747f2j5z3xw170p-glibc-2.40-224/lib/libc.so.6`,
per `docs/slop/research/hosts/{c7g,c8g,c9g}/libc-probe.json`) and select
`__memcpy_sve`, `__memmove_sve`, `__memset_sve_zva64`
(`docs/slop/research/hosts/README.md`). No target has FEAT_MOPS. All report
`prefer_sve_ifuncs=1`.

- c7g V1: SVE only, no SVE2 (`docs/slop/research/hosts/c7g/cpu.txt` flags
  list `sve` but no `sve2`); VL 256-bit on Graviton3 (AGENTS.md
  benchmark-targets table: "c7g — Graviton3 / Neoverse-V1 (256-bit SVE)").
- c8g V2: SVE2 (`c8g/cpu.txt` flags include `sve2`), VL 128-bit on
  Graviton4 (AGENTS.md: "c8g — Graviton4 / Neoverse-V2 (128-bit SVE)").
- c9g V3: SVE2 (`c9g/cpu.txt`), VL 128-bit **unverified** — flags add
  ecv, afp, wfxt over c8g but say nothing about width; §7 has the probe
  plan. The design does not depend on it (§5, runtime `cntb`).
- L1d 64 KiB/core, L2 1 MiB/core (V1) or 2 MiB/core (V2/V3), L3 32/36/48 MiB
  shared (`docs/slop/research/hosts/{c7g,c8g,c9g}/lscpu.txt`).

## 1. What glibc does on V1/V2/V3

All addresses below are file offsets in
`.bench-cache/glibc/libc-aarch64-linux-gnu.so.6` (glibc 2.40, disassembled
with `llvm-objdump -d --disassemble-symbols=...`). Behavior is described,
not transcribed.

### ifunc selection

- All three Graviton targets resolve `memcpy`→`__memcpy_sve` (0xaed80),
  `memmove`→`__memmove_sve` (0xaee80), `memset`→`__memset_sve_zva64`
  (0xb00c0): `docs/slop/research/hosts/{c7g,c8g,c9g}/libc-probe.json`.
- The memset ifunc (symbol `memset`, type `i`, at 0xa7800; the resolver
  code is also named `__libc_memset_ifunc` in `.symtab`, same address —
  verified with `llvm-nm`) checks, in order: a MOPS feature byte at
  [x0,#0x80] (`tbnz` at 0xa7814 → `__memset_mops` at 0xafe80), then an
  SVE feature byte at [x0,#0x7e] (`tbz` at 0xa7828 skips the SVE
  selection; the offset→name mapping inside the cpu_features struct is
  inferred from which variant each branch returns). It returns
  `__memset_sve_zva64` only when the DC ZVA block size is 64
  (`cmp w4, #0x40` at 0xa7838/0xa78dc) AND `prefer_sve_ifuncs` is set
  (`ccmp w0, #0x0` at 0xa783c, branch to the sve_zva64 return at 0xa78e8).
  With zva64 but no SVE it returns `__memset_zva64` (0xb01c0,
  selected at 0xa7864–0xa7878); otherwise `__memset_generic` (0xafc40).
  So a 64-byte ZVA block is confirmed on all three targets — directly
  corroborated by `aarch64.cpu_features.zva_size=0x40` and
  `dczid_el0=0x4` on every core in
  `docs/slop/research/hosts/{c7g,c8g,c9g}/ld-diagnostics.txt:117,122-137`.

### `__memcpy_sve` (0xaed80) — size classes

- **count ≤ 128** (branch at 0xaed84 `cmp x2, #0x80`):
  - **count ≤ 2×VL**: SVE predicated two-vector copy. `cntb` (0xaed8c),
    `whilelo p0.b, xzr, x2` / `whilelo p1.b, x6, x2` (0xaed98–0xaed9c),
    two predicated `ld1b` + two `st1b` (0xaeda0–0xaedac), `ret`. This is
    the only SVE code in the whole function. On V1 (VL=32 B) it covers
    0–64 B; on V2/V3 (VL=16 B) it covers 0–32 B.
  - **2×VL < count ≤ 128**: pure NEON overlapping copies at 0xaedb4:
    `ldp q0,q1` head + `ldp q2,q3` tail; if count ≤ 64 store both and
    return (0xaedc4–0xaedd4); else an extra middle `ldp q4,q5` and, for
    count > 96, `ldp q6,q7` near the tail (0xaedd8–0xaedf8).
- **count > 128** (0xaee00): the large loop is **pure NEON 128-bit, no
  SVE at all**. It aligns the **source** down to 16 B
  (`and x1, x1, ~0xf` at 0xaee10), shifts the destination pointer by the
  same amount (`sub x3, x0, x6` at 0xaee14), copies an unaligned 16 B head
  (`str q3` at 0xaee20), then runs a 64 B/iteration loop of `ldp`/`stp`
  q-register pairs (0xaee30–0xaee4c, unroll = 4×16 B per iter, software
  pipelined: stores of the previous pair interleave with loads of the
  next). The tail is two overlapping 32 B `ldp`/`stp` pairs from the
  buffer end (0xaee50–0xaee64).

### `__memmove_sve` (0xaee80)

- count ≤ 128: identical small path; the NEON overlapping case literally
  branches into `__memcpy_sve+0x34` (0xaedb4) at 0xaee94.
- count > 128 (0xaeec0): `x6 = dst - src`; if zero, return (0xaeecc). If
  `dst - src ≥u count`, jump into the memcpy forward large path
  (0xaee00, branch at 0xaeed4) — this also covers dst < src via unsigned
  wraparound. Otherwise backward copy (0xaeed8): aligns the **source end**
  down to 16 B (`and x4, x4, ~0xf` at 0xaeee0), stores an unaligned 16 B
  at the destination end first, then a 64 B/iteration **backward** NEON
  loop with negative-offset `ldp` and pre-decrement `str` (0xaef00–0xaef20),
  finishing with overlapping forward `ldp`/`stp` pairs from the source
  start (0xaef24–0xaef38). Same 4×16 B unroll, same source-alignment
  policy as the forward path.

### `__memset_sve_zva64` (0xb00c0)

- Broadcast: `dup v0.16b, w1` (0xb00c4) — NEON register, no SVE.
- **count < 16**: single SVE predicated store: `whilelo p0.b, xzr, x2` +
  `st1b` (0xb0100–0xb0108).
- **16 ≤ count < 64**: up to four overlapping 16 B `str q0` (0xb00dc–0xb00f8).
- **64 ≤ count ≤ 128**: four overlapping 32 B `stp q0,q0` (0xb011c–0xb012c).
- **count ≥ 256 AND value byte == 0** (tests at 0xb0130 `cmp x2, #0x100`
  and 0xb0138 `tst w1, #0xff`): **DC ZVA path**. Progressively aligns the
  destination to 16/32/64 B with plain stores (0xb0140–0xb0150), then a
  loop of one `dc zva` per 64 B (0xb0170–0xb017c), tail handled by
  overlapping stores computed from the buffer end (0xb015c–0xb016c).
- **everything else > 128** (or > 256 with nonzero value; the branch at
  0xb0118 is `b.hi` after `cmp x2, #0x80`, so 128 itself stays in the
  64–128 class): NEON loop at
  0xb0184 — align destination to 16, then 64 B/iteration of two
  `stp q0,q0`, overlapping 64 B tail (0xb01a4–0xb01ac). Note: here the
  **destination** is aligned (unlike memcpy's source alignment).

### The generic variants (for comparison and for G6)

`__memcpy_generic` (0xae800) is pure NEON. Its >128 B loop
(0xae8d8–0xae938) is structurally identical to the SVE variant's — same
source alignment, same 64 B `ldp`/`stp` loop. The difference is entirely
in the small cases: generic uses a `tbz` bit-test tree for count < 16
(0xae838–0xae888: an 8-byte head/tail pair if bit 3 is set, a 4-byte
pair if bit 2 is set, then three byte copies at offsets 0, len/2, len−1
for 1–3 B — there is no 2-byte piece), 16–32 B via two overlapping 16 B
`ldr`/`str` (0xae824–0xae834), and the same 32–128 B
overlapping-`ldp` block as the SVE variant (0xae890 ≈ 0xaedb4). So SVE's
only contribution to memcpy/memmove on these machines is replacing the
branchy sub-2×VL small path with two predicated vector ops.

### VL consequences

The SVE code touches only counts ≤ 2×VL (memcpy) and < 16 (memset), so
the 256-bit vs 128-bit VL difference between V1 and V2/V3 shifts one
branch boundary: the predicated path covers 0–64 B on V1 but only 0–32 B
on V2/V3. Every copy above 128 B and every memset above 16 B runs
identical 128-bit NEON code on all three targets. Any fastmem advantage
for large sizes must come from the NEON loop structure itself
(alignment side, unroll, prefetch), not from wider SVE vectors — and for
small sizes, from removing the call/return and letting the size-class
branches predict against the caller's actual mix (G4; note the harness
calls glibc through a `dlsym` pointer, so there is no PLT delta to
harvest — `docs/slop/fastmem-plan.md` measurement table), not from beating
the predicated two-vector idiom.

## 2. Arm Optimized Routines

Pinned commit: `5e20a93f440ca771bcdb757cc13c3beee217e534` (2026-09-15,
tip of `string/aarch64` history at fetch time). License: MIT OR Apache-2.0
WITH LLVM-exception (per-file SPDX header, e.g. `memcpy-sve.S:5`).
`string/aarch64` at this commit contains `memcpy-sve.S`,
`memcpy-advsimd.S`, `memcpy.S`, `memset-sve.S`, `memset.S`,
`memset-scalar.S`, `memcpy-mops.S`, `memmove-mops.S`, `memset-mops.S`
(GitHub API directory listing at that ref). The only standalone memmove
file is the MOPS one, irrelevant here (no target has FEAT_MOPS); for
SVE and advsimd, memmove is an alias entry of the memcpy routine
(`ENTRY_ALIAS (__memmove_aarch64_sve)` in `memcpy-sve.S:50`).

### Correspondence with glibc 2.40

- `__memcpy_sve` is `string/aarch64/memcpy-sve.S` minus the pre-2026
  layout: same size classes (128 split, 2×VL predicated pair, 64/96
  mid-tier branches), same source-aligning 64 B NEON loop, same backward
  memmove loop. glibc splits memmove into its own entry that tail-branches
  into the memcpy blocks (0xaee94, 0xaeed4) instead of AOR's single
  aliased entry; the instruction sequences are otherwise the same shape.
- `__memset_sve_zva64` is `string/aarch64/memset-sve.S` with the DCZID
  check compiled out — the glibc disassembly contains no `mrs dczid_el0`
  (verified), while AOR guards it behind `#ifndef SKIP_ZVA_CHECK`
  (`memset-sve.S:72-76`); that glibc defined `SKIP_ZVA_CHECK` is an
  inference from the missing `mrs`, marked unverified. The classes match
  except at one boundary: AOR's 4×`str` block covers 16..64 inclusive
  (`cmp count, 64; b.hi` at `memset-sve.S:35-36`) while glibc's covers
  16..63 (`b.hs` at 0xb00d8), putting exactly 64 in the 4×`stp` block.
  The offset masks also differ in form — AOR `48 & (count>>1)`, glibc
  `16 & (count>>1)` — but are equal for all counts below 64. ZVA when
  count ≥ 256 and val == 0 (`memset-sve.S:67-70`), tail written before
  the ZVA loop so the loop can overshoot into already-written bytes
  (`memset-sve.S:86-90`).
- `__memcpy_generic` is `memcpy-advsimd.S` (same 64 B loop, scalar
  bit-test small path instead of the SVE predicated pair).

### The post-glibc-2.40 improvement worth taking

AOR commit `23c4393006122497ea989725c9e34d253bc1e62b` (2026-09-09,
"Improve __memcpy_aarch64_sve") reports **~7% on the random-size test on
Neoverse V2** from layout alone: hoist `cntb` above the 128-byte branch
and add `.p2align 4` before the 65–128 block and the backward-copy block.
glibc 2.40 predates it (its `cntb` is at 0xaed8c, after the branch at
0xaed88). Zig gives no control over basic-block alignment, so a pure-Zig
kernel cannot deliberately reproduce this layout — one more argument for
the global-asm baseline in §5. The lesson to keep either way:
**branch-target alignment of the mid-size and backward blocks is worth
real percentage points on V2**.

### What to port (MIT option) and attribution

- **Baseline port (parent ruling):** `memcpy-sve.S` (with the 23c4393
  layout) and `memset-sve.S` become the G2 C-ABI kernels on SVE targets,
  ported as container-level global asm inside a `.zig` file (mechanism
  proven in §4-E6). This is glibc parity by construction, plus the
  layout fix glibc 2.40 lacks. The pure-Zig kernel of §5 is the
  challenger, not the default.
- `memcpy-advsimd.S` is the G6 generic-aarch64 reference.
- Attribution: keep the Arm copyright header, name the file and pinned
  commit, list the port in `THIRD_PARTY.md` per `docs/slop/fastmem-plan.md`
  licensing rules.
- No reason to port `*-mops.S`: no Graviton target has FEAT_MOPS
  (`docs/slop/research/hosts/README.md`).
- Header template per ported file: upstream copyright lines exactly as
  in the source file (`Copyright (c) 2019-2023, Arm Limited.` for
  `memcpy-sve.S:3`; `Copyright (c) 2024-2024, Arm Limited.` for
  `memset-sve.S:4`; `2012-2024` is `memset.S`), SPDX `MIT OR Apache-2.0
  WITH LLVM-exception`, "Ported from ARM-software/optimized-routines
  `string/aarch64/<file>.S` @ 5e20a93f440ca771bcdb757cc13c3beee217e534".

## 3. What compiler-rt (Zig 0.16) does today

Toolchain source root:
`/nix/store/h4am1dpj4li41cq58861nysgaip7036s-zig-0.16.0/lib/zig`
(cited below as `$Z`).

- `memcpy` export: `$Z/compiler_rt/memcpy.zig:6-21` (`memcpyFast` in
  ReleaseFast). `memmove`: `$Z/compiler_rt/memmove.zig:10-23`. `memset`:
  `$Z/compiler_rt.zig:304-305`, body at `$Z/compiler_rt.zig:677-690`.
  Linkage is weak; visibility is `.hidden` for static links but
  **`.default` when `link_mode == .dynamic`**
  (`$Z/compiler_rt.zig:41-44`) — a G5-relevant detail: in a dynamic
  build, compiler-rt's `memcpy` is default-visibility and can go to
  `.dynsym`.
- The bulk-copy element type is `PreferredLoadStoreElement`
  (`$Z/compiler_rt.zig:350-358`) = `@Vector(suggestVectorLength(u8), u8)`.
  On aarch64, `suggestVectorLengthForCpu` returns 256 bits for any CPU
  with SVE and 128 otherwise (`$Z/std/simd.zig:25-31`, comments name
  Graviton3 explicitly). Verified by comptime print (§4-E15): **32 on
  neoverse_v1/v2/v3, 16 on generic**. So on all three bench targets
  Element is `@Vector(32, u8)` with 32-byte alignment — not the 16 B
  this memo's first draft claimed from AGENTS.md's "16 on NEON" (that
  holds only for non-SVE aarch64).
- `memcpyFast` structure (`memcpy.zig:37-47`): `small_limit` = 2×32 =
  64. Sizes < 16: `copyLessThan16` — three byte copies for 1–3 B,
  `copyRange4(4)` (four overlapping 4 B chunks) for 4–15
  (`memcpy.zig:55-80`). Sizes 16–63: `copy16ToSmallLimit` →
  `copyRange4(16)`, four overlapping 16 B chunks (`memcpy.zig:61,
  83-96, 176-195`). Sizes ≥ 64: `copyForwards` (`memcpy.zig:100-118`):
  a 32 B head chunk, align the **source** up to 32 B, `copyBlocks`
  element loop, a 32 B tail chunk. As written the loop copies one 32 B
  element per iteration (`memcpy.zig:131-151`); what LLVM makes of it is
  measured in §4-E8.
- `memset` is a **byte-at-a-time loop** as written
  (`$Z/compiler_rt.zig:677-690`). No DC ZVA anywhere in compiler-rt
  (no `zva` string under `$Z/compiler_rt*` — verified by grep).
- `memmoveFast` (`memmove.zig:42-57`) does **not** share memcpy's code:
  it imports `memcpy.zig` at line 5 and never references it (verified by
  grep — the import is dead). It has its own `copySmallLength`
  (line 59), `copyForwards` (line 145, same 32 B source alignment), and
  `copyBackwards` (line 196, which aligns the **destination** end). Its
  `copyRange4` (lines 116-142) uses `[copy_len]u8` **array** copies
  rather than `@Vector`, which makes LLVM spill — see §4-E8/E10.
- The export mechanism that fastmem's G5 must beat:
  `symbol(&memset, "memset")` etc. in `$Z/compiler_rt.zig:304-305` and
  the `memcpy`/`memmove` `@export`s; weak, with the visibility rule
  above. A strong export in the program wins the static link; the
  dynamic-link visibility is why G5 needs a `.dynsym` binary test.

## 4. Zig 0.16 expressibility (compiled experiments)

All experiments: `zig build-obj -target aarch64-linux-gnu -mcpu=<cpu>
-OReleaseFast -fno-builtin <file>.zig`, disassembled with `llvm-objdump -d`
(LLVM 21.1.8 from the devshell). Test sources were throwaway files in
/tmp (not committed). Zig 0.16 knows all three CPU models:
`std/Target/aarch64.zig:3563` (neoverse_v1), `:3590` (neoverse_v2),
`:3617` (neoverse_v3).

### E1/E9 — the glibc large loop is expressible in pure Zig, with one hard rule

A 64 B/iteration loop of four `@Vector(16, u8)` load/stores compiles to
two `ldp` + two `stp` q-register pairs per iteration on **all four**
CPUs (neoverse_v1/v2/v3/generic) — the same per-iteration instruction
mix as glibc's loop at 0xaee30. E9 then varied the source shape:

| loop body shape | codegen (all four CPUs) |
|---|---|
| all loads of the block, then all stores, plain pointers | 2 `ldp` + 2 `stp` |
| `st(d, ld(s))` interleaved, plain pointers | 4 `ldr q` + 4 `str q`, **unpaired** |
| interleaved, `noalias` parameters | pairs again; only V3 hoists both loads above both stores |

The first draft's E1 used `noalias`, which memmove cannot use (dst and
src may overlap). The rule for shared copy/move code is therefore:
**load the whole 64 B block before any store, and never put `noalias`
on copy/move pointers**. Two more caveats: LLVM does not reproduce
glibc's cross-iteration software pipelining (0xaee30–0xaee4c interleaves
the previous iteration's stores with the next loads), and LLVM's choice
of which loads pair with which is not under our control — both are
arguments for the global-asm baseline in §5, with the Zig loop as
challenger.

### E7 — fixed-width vectors never become SVE

`@Vector(32, u8)` copy/splat compiles to `ldp q0,q1` / `stp q0,q0` on
both V1 and V2 — LLVM lowers fixed-width vectors to NEON pairs even on
the 256-bit-SVE V1. (The first draft attributed this to
`use_fixed_over_scalable_if_equal_cost`, but that feature is absent from
the neoverse_v1 model — `std/Target/aarch64.zig:3563-3588` — and V1
behaves identically. The real cause is unverified; treat it as "fixed
vectors never lower to SVE in these builds".) Zig has no scalable vector
type and no `vscale`, so **all SVE code must be inline (or global)
asm**. This costs nothing for sizes > 2×VL, where glibc itself is pure
NEON (§1).

### E2 — SVE idiom via inline asm works and is feature-gated

An inline-asm block with `cntb` / two `whilelo` / two predicated `ld1b`
/ two `st1b` (my own code; the idiom is also AOR `memcpy-sve.S:52-64`,
MIT):

- compiles under `-mcpu=neoverse_v1` with encodings byte-identical to
  the glibc small path (e.g. `cntb x6` = 0x0420e3e6 in both),
- is **rejected by the assembler** under `-mcpu=generic`
  (`error: <inline asm>:1:2: instruction requires: sve or sme`),

so the SVE fragments must sit behind `comptime builtin.cpu.has(.aarch64, .sve)`
— which is also what makes the G6 generic build safe by construction.
Zig 0.16 asm syntax notes (differ from training data): clobbers are a
struct literal (idiom from `std/os/linux/sparc64.zig:22`), register ties
use `[ret] "={x0}" (-> u64)` (`std/os/linux/aarch64.zig:7`).

E16 — the production form of the fragment (compiled and verified):
`whilelo` writes NZCV, so the clobber list must include `.nzcv`, and the
`cntb` result should come back through an **output operand** instead of
a hardcoded `x6`:

```zig
const vlen = asm (
    \\cntb %[vl]
    \\whilelo p0.b, xzr, %[len]
    \\whilelo p1.b, %[vl], %[len]
    \\ld1b { z0.b }, p0/z, [%[src]]
    \\ld1b { z1.b }, p1/z, [%[src], #1, mul vl]
    \\st1b { z0.b }, p0, [%[dst]]
    \\st1b { z1.b }, p1, [%[dst], #1, mul vl]
    : [vl] "=r" (-> usize)
    : [dst] "r" (dst), [src] "r" (src), [len] "r" (len)
    : .{ .memory = true, .nzcv = true, .p0 = true, .p1 = true, .z0 = true, .z1 = true }
);
```

(The idiom is AOR `memcpy-sve.S:52-64`, MIT. This is our own code, not a
glibc transcription — it merely shares the 3-instruction whilelo/ld1b
shape any SVE implementation of this class has. Zig passes clobbers
through with no implicit additions: the emitted constraint string is
exactly what is declared, so an omitted NZCV would be a silent
correctness bug.) LLVM allocated `x8` for `vl` and emitted the block
otherwise verbatim.

### E4 — DC ZVA via inline asm works

`asm volatile ("dc zva, %[p]" ...)` compiles to `dc zva, xN` (0xd50b7420)
under neoverse_v1 and survives inside a Zig `while` loop with clean loop
code around it. The 64 B block size is confirmed on all three bench
boxes twice over: glibc's resolver selected the zva64 variant at runtime
(`libc-probe.json`; resolver compare at 0xa7838/0xa7864), and
`zva_size=0x40` / `dczid_el0=0x4` appear in
`docs/slop/research/hosts/{c7g,c8g,c9g}/ld-diagnostics.txt:117,122-137`.

Even so, the ZVA path keeps AOR's runtime check (parent ruling):
`mrs`+`and`+`cmp` against block size 4 (= 64 B), 4 instructions executed
once per zero-fill ≥ 256 B (`memset-sve.S:72-76`). A `-Dcpu=neoverse_v2`
binary run on a host with DZP=1 would take SIGILL on `dc zva`, and a
host with a different block size would zero outside the buffer — cheap
insurance either way. For the G6 `-Dcpu=generic` build the ZVA path is
compiled out (block size is a system property, not a CPU feature);
P7 can add a cached one-time DCZID read if generic wants ZVA.

### E5/E14 — the memcpy-recursion hazard is real on aarch64/0.16

With default builtins (no `-fno-builtin`), idiom recognition fires as
follows (E14, per-function relocations): a byte-element copy loop with
**`noalias`** parameters becomes `b memcpy` (R_AARCH64_JUMP26); the same
loop with plain pointers stays a loop; a byte-element **set** loop
becomes `b memset` either way. With `-fno-builtin` all stay loops.
Consequence, confirming the plan: the fastmem kernel module must build
with `no_builtin = true` — and see E11, because `no_builtin` does not
cross an `inline fn` boundary.

### E8 — what the shipped compiler-rt actually compiles to (aarch64, V1)

Compiled the toolchain's own `compiler_rt.zig` as the root
(`zig build-obj -OReleaseFast -target aarch64-linux-gnu
-mcpu=neoverse_v1 -fno-builtin`), disassembled the exported symbols:

- `memcpy` (memcpyFast): splits <16 / 16–63 / ≥64 (matching §3's
  source reading: `cmp x2, #0xf` and `cmp x2, #0x3f` at the head of the
  disassembly). The ≥ 64 B path copies a 32 B head (`ldp q0,q1`),
  aligns the source to **32 B** (`and x12, x1, #0x1f` — Element-sized,
  per E15), and **is** unrolled by LLVM into a 64 B/iteration
  `ldp`/`stp` q-pair loop — but with a fixup-heavy tail (a
  `neg`/`lsr`/`tbnz` remainder chain plus a separate 32 B epilogue),
  versus glibc's clean 16 B-align + copy-64-from-end. So the builtin's
  large copy is closer to glibc than the source suggests; the remaining
  gap is loop polish, not loop width.
- `memset`: a **byte-store loop unrolled 4×** (`strb`, plus a
  byte-at-a-time remainder pre-loop). No vector stores at any size, no
  ZVA. This is the single largest builtin deficiency on aarch64 — an
  AOR-shaped NEON memset should beat it by an order of magnitude at bulk
  sizes, and G3 (never slower than compiler-rt) is free for memset.
- `memmove` (memmoveFast): the 16–63 B path builds a **0xd0-byte stack
  frame and spills the loaded vectors to it** (`sub sp, sp, #0xd0` at
  +0x38; dead `stp q0,q1,[sp]` and `stp q2,q3,[sp,#0x20]` before the
  real stores) — the same array-copy defect as E10, coming from
  `memmove.zig:116-142`. The builtin's memmove is materially weaker
  than its memcpy in the mid class.
- E13 — same build for `-mcpu=generic`: memcpy's loop degrades to
  **unpaired 16 B** `ldr q`/`str q` per iteration (Element = 16 B there
  and LLVM does not pair the interleaved shape), and memset is a single
  `strb` per iteration, 9 instructions total. G6 is easier than the
  first draft claimed.

The same experiment also re-confirms E5's point from the other side:
`-fno-builtin` is required to even observe these loops, since otherwise
LLVM idiom-recognizes them into calls.

### E10 — `[N]u8` array chunk copies spill; `@Vector(N, u8)` does not

The overlapping head/tail idiom written as `const a: [32]u8 =
src[0..32].*` compiles to two `ldp` + two `stp` **plus dead stores of
both 32 B chunks to a 0x50-byte stack frame** on v1 (and generic) —
LLVM materializes the arrays as stack temporaries. The identical code
with `@Vector(32, u8)` is a clean 2 `ldp` + 2 `stp` with no frame.
Rule: **all chunk copies in fastmem use `@Vector`, never array copies**.
(compiler-rt's memmove has exactly this defect — §3, E8.)

### E11 — `no_builtin` does not survive inlining into a default module

Two-module build (`zig build`): module K with `no_builtin = true`
exports `inline fn setInline` (byte-set loop) and `fn setCall` (same
loop, not inline); the root module (default builtins) calls both. In
the linked archive, `useCall` → `kernel.setCall` stays a `strb` loop,
but `useInline` — the inlined body — became `b memset`
(R_AARCH64_JUMP26 at `useInline+0x10`). Inlined IR takes the **caller's**
builtin setting. Rule: **the inline layer must contain no loops** — only
straight-line class code and asm fragments; every loop lives in a
non-inline function inside the `no_builtin` module. A binary test (no
`memcpy`/`memset` relocations out of inline call sites) belongs in the
G4/G5 gate.

### E12 — the backward loop pairs on all four CPUs

The memmove backward loop (loads-first, negative offsets, plain
pointers, 4×16 B) compiles to 2 `ldp` + 2 `stp` per 64 B iteration on
neoverse_v1/v2/v3 **and generic**. The first draft listed backward-loop
codegen as an open risk; it is closed.

### E15 — `suggestVectorLength(u8)` on the bench targets

Comptime print: **32 on neoverse_v1** (and v2/v3 — same `sve` branch of
`std/simd.zig:25-31`), **16 on generic**. This is what makes
compiler-rt's Element 32 B on Graviton (§3), and it means fastmem's own
`chunk_bytes` is 32 on these targets today (`src/common.zig:12` —
noted because AGENTS.md's "16 on NEON" is true only for non-SVE
aarch64).

### E6 — comptime feature selection and global asm both work

`comptime builtin.cpu.has(.aarch64, .sve)` gates code correctly (true on
v1/v2/v3, false on generic). A container-level `asm` block defining a
whole function (`.globl` + label) compiles and is correctly omitted on
generic when gated — no separate `.S` file or extra build step is
needed. So both units of asm integration are available inside `.zig`
files: inline fragments or whole-function global asm.

**Assignment (parent ruling):** the G2 C-ABI baseline kernel on SVE
targets is a whole-function global-asm port of AOR `memcpy-sve.S` (with
23c4393) and `memset-sve.S` — glibc parity by construction, with block
alignment control the pure-Zig route lacks (E1/E9 pipelining caveat, §2
layout fix). Inline-asm fragments (E2/E16, E4) serve the G4 inline path,
where only fragments can inline. The pure-Zig kernel is the challenger
(§6 H2) and the G6 generic implementation.

### Prologue note for the G2 measurement

`zig build-obj -OReleaseFast` still emits frame-pointer prologues on
exported functions that need them (`stp x29,x30` + `mov x29,sp` +
epilogue `ldp` = 3 instructions); shrink-wrapping already keeps
frameless the leaf paths that do not touch the stack (compiler-rt's
memcpy small classes have no prologue in the E8 disassembly). glibc's
kernels have no frame pointer. Set `omit_frame_pointer` on the fastmem
module itself (`std.Build.Module` field, `std/Build/Module.zig:256`) so
the C-ABI bench entry points never pay it where a frame does exist —
visible noise at 16–128 B sizes where G2/G4 are won. The global-asm
baseline sidesteps this entirely (it has the prologue we port, i.e.
none).

## 5. Proposed fastmem aarch64 design

Two implementations per operation on SVE targets (parent ruling):

1. **Baseline (G2 C-ABI kernel): a global-asm port of AOR
   `memcpy-sve.S` (including commit 23c4393) and `memset-sve.S`,
   written as container-level `asm` blocks inside a `.zig` file** (E6
   proves the mechanism; attribution per §2). glibc's selected kernel is
   this code minus 23c4393 (§2), so the baseline is glibc parity by
   construction plus a measured layout fix — and it has the basic-block
   alignment control (`.p2align`) that Zig codegen does not offer.
2. **Challenger: the pure-Zig kernel** described by the tables below,
   held to the E9/E10 rules (loads before stores per block; `@Vector`
   chunks, never array copies; no `noalias` on shared copy/move code).
   It must match the baseline within the harness noise floor to replace
   it for the C-ABI role; it exists regardless as the inline-layer body
   and the G6 generic implementation.

memmove is the primary kernel; memcpy is the same code with the overlap
check compiled out (plan design decision; AOR's single-entry alias,
`memcpy-sve.S:50-51`). All size classes below follow the glibc/AOR
evidence in §1–§2.

### Comptime selection

```
has_sve  = builtin.cpu.has(.aarch64, .sve)   // v1/v2/v3: true, generic: false
```

`has_sve` gates the entire baseline port and the SVE fragments. The ZVA
path additionally keeps AOR's runtime DCZID_EL0 check (§4-E4, parent
ruling) rather than trusting the CPU model. Never gate on `.mte`: the
v2/v3 CPU models enable it but the hosts report `mte_state=0x0`
(`ld-diagnostics.txt:114`). `mops` is absent from all three models
(`std/Target/aarch64.zig:3563-3640`), so LLVM cannot emit `cpyf*` — no
MOPS leakage to audit.

VL is **not** needed at comptime: the SVE small path reads it with
`cntb` at run time (as glibc does, 0xaed8c), so one kernel serves V1
(VL=32 B) and V2/V3 (VL=16 B). Known VLs only shift which branch a size
takes. VL source: AGENTS.md benchmark-targets table (V1 256-bit SVE, V2
128-bit); V3's VL is unverified (AGENTS.md flags `-Dcpu=neoverse_v3` as
unverified) — see §7.

### memmove/memcpy size classes (SVE build)

| class (bytes) | implementation | evidence |
|---|---|---|
| 0..2×VL | one inline-asm fragment: `cntb`, 2×`whilelo`, 2× predicated `ld1b`/`st1b` (E16 form: output operand, `.nzcv` clobbered) | glibc 0xaed8c–0xaedb0; AOR `memcpy-sve.S:52-64`; E2/E16 prove codegen |
| 2×VL+1..64 | overlapping 32 B head + 32 B tail as `@Vector(32,u8)` loads-first (`ldp`/`stp` pairs — **not** `[32]u8` array copies, which spill; E10) | glibc 0xaedbc–0xaedd4; E7/E10 prove codegen |
| 65..128 | overlapping 32 B chunks: head, head+32, end−64, end−32; drop the third when ≤ 96 | glibc 0xaedd8–0xaedf8; AOR `memcpy-sve.S:81-91` |
| > 128, non-overlap | copy 16 B head; align **source** down to 16; 64 B/iter loop, 4×16 B unrolled, pure Zig (E1); finish with 64 B from the end | glibc 0xaee00–0xaee68; AOR `memcpy-sve.S:94-133` |
| > 128, `0 < dst−src < len` | backward: align **source end** down to 16; 16 B tail store; 64 B/iter backward loop; finish with 64 B from the start | glibc 0xaeed8–0xaef38; AOR `memcpy-sve.S:139-167` |

Overlap test: `dst −% src >=u len` → forward (unsigned wrap covers
dst < src), `dst == src` → return (glibc 0xaeec8–0xaeed4). The check
runs only above 128 B; smaller classes are overlap-safe by construction
(all loads before all stores within each class — same property glibc
relies on).

### memset size classes (SVE + zva64 build)

Broadcast with `@splat` into `@Vector(16, u8)` — E7 shows it emits
`dup v0.16b`, identical to glibc 0xb00c4.

| class (bytes) | implementation | evidence |
|---|---|---|
| 0..15 | one predicated `st1b` fragment | glibc 0xb0100–0xb0108; AOR `memset-sve.S:49-52` |
| 16..64 | four overlapping 16 B stores at offsets 0, `off`, `len−off−16`, `len−16` with `off = 48 & (len>>1)` (AOR's class is 16..64 inclusive; glibc's is 16..63 with mask 16 — equivalent below 64, §2) | glibc 0xb00dc–0xb00f8; AOR `memset-sve.S:39-46` |
| 65..128 | four overlapping 32 B `stp` pairs | glibc 0xb011c–0xb012c; AOR `memset-sve.S:55-63` |
| ≥ 256 **and val == 0** | runtime DCZID_EL0 check first (AOR `memset-sve.S:72-76`, kept per parent ruling); write the unaligned tail first, align dst to 64, `dc zva` loop (one per 64 B), so the final ZVA block overlaps already-written tail bytes | glibc 0xb0130–0xb0180; AOR `memset-sve.S:67-98` |
| other > 128 | align **destination** to 16; 64 B/iter of two `stp` pairs (loads-first not needed — one register); overlapping 64 B tail | glibc 0xb0184–0xb01ac |

Note the alignment asymmetry glibc uses: memcpy aligns the **source**
(load side), memset aligns the **destination** (store side). The copy
side is settled by 0.15.2-era measurement (`docs/slop/results/zig-0.15-benchmark-hosts.md`
c8g section, line ~125: matching source alignment "fixed the worst
non-libc c8g regressions"); H7 in §6 tests the memset side.

### Generic build (G6, `-Dcpu=generic`)

Same classes minus the asm: <16 via the scalar overlapping-store tree
(AOR `memset.S:47-65` / glibc generic 0xae838–0xae888 for copies), 16..128
identical NEON overlapping chunks, >128 identical 64 B NEON loop, no ZVA
(memset long path = the aligned stp loop). E1/E9 show the loop compiles
fine on `generic` with plain pointers (loads-first shape). G6 is
comfortable: on generic, compiler-rt's memcpy loop is **unpaired** 16 B
per iteration and its memset is 1 byte per iteration (E13), weaker than
the SVE-target builds the first draft cited.

### Code structure

- `src/kernels/aarch64_sve.zig` — the **baseline**: container-level
  global-asm port of AOR `memcpy-sve.S` (+23c4393) and `memset-sve.S`,
  gated by `comptime has_sve`, carrying the AOR attribution header (§2).
  Exports the C-ABI symbols the bench measures as `fastmem_abi`.
- `src/kernels/aarch64.zig` — the **challenger** and the G6 generic
  kernel: `moveImpl(comptime check_overlap: bool, ...)`, `copyImpl =
  moveImpl(false, ...)`, `setImpl(...)`, class helpers as `inline fn`,
  following the E9/E10 rules.
- `src/kernels/aarch64_asm.zig` — the three inline-asm fragments
  (`sveCopyLe2Vl`, `sveStoreLeVl`, `dcZva`) shared by the challenger and
  the inline layer, so the clean-room boundary is one auditable file
  with the AOR attribution header (§2).
- `src/root.zig` keeps its public API; aarch64 kernels plug into the
  existing comptime CPU selection (see `std.Target` model compare idiom
  in AGENTS.md).
- Kernel module builds with `no_builtin = true` (E5/E14) and
  `omit_frame_pointer = true` (§4 prologue note,
  `std/Build/Module.zig:256`).

### Inline small-size path (G4)

The first draft got this wrong; corrected per review. `dist/small` uses
**runtime** sizes — "each call has a different size and a different
offset" (`docs/slop/bench-design.md:384-388`) — so no comptime folding
applies and the size-class branches stay, mispredicting on the random
mix. And there is no PLT delta: the harness calls glibc through a
`dlsym` pointer. The inline runtime path therefore works like this:

- **Runtime sizes:** `fastmem.copy`/`move`/`set` inline the kernel's
  size classes at the call site — including the predicated SVE fragment
  when `has_sve` (fragments do inline, E2/E16). The SVE fragment is not
  optional decoration: on V1 it handles 0–64 B with two data-independent
  branches, where a NEON-only path adds data-dependent classes (compare
  glibc's generic tree, 0xae814–0xae888) that mispredict on the mix.
  The structural wins over the glibc call are: no call/return, no
  indirect branch through the ifunc pointer, and branches that predict
  against the caller's own size mix.
- **Comptime-known sizes ≤ 256** (the separate second G4 bullet):
  straight-line overlapping `@Vector` copies, no branches, no call (E7).
- **Loop-free rule (E11):** the inline layer contains no loops — classes
  are straight-line; anything iterative stays in non-inline functions in
  the `no_builtin` module. Otherwise an inlined loop is idiom-recognized
  under the *consumer's* builtin setting and becomes a call — silently
  breaking G4's "no call" and, under `exportSymbols`, becoming
  recursion.

The 0.90 target on `dist/small` is **unverified** — plausible on V1 via
the fragment, at risk on c7g otherwise; the harness decides in P4.

### What is deliberately not in the design

- No MOPS (`cpyp`/`cpyfp`): no target has FEAT_MOPS
  (`docs/slop/research/hosts/README.md`), and the CPU models lack the feature
  so LLVM cannot emit it.
- No SVE in the large loop: glibc/AOR use NEON there even on 256-bit V1;
  wider-SVE large loops are an H-list experiment (§6), not the design.
- No non-temporal path by default: glibc's aarch64 kernels use none;
  `stnp` (non-temporal pair) exists in ARMv8 and is a >L3 experiment (§6).

## 6. Ranked hypotheses for P3 (each with its harness command)

Harness flow (AGENTS.md): `just bench-up c7g c8g c9g`, then
`just bench-run --rev <base> --rev <candidate> --suite quick` (5+ rounds,
A/A noise floor per `docs/slop/bench-design.md`), then `just b analyze
bench-results/<run-id>/`. Baseline for every comparison: P1d's
`docs/slop/results/baseline-0.16.md` numbers.

1. **H1 — the AOR-parity port closes the c8g aligned 4096/16384
   residual.** The 0.15.2-era fastmem never caught glibc on large
   **aligned** copies on c8g: `docs/slop/results/zig-0.15-benchmark-hosts.md` c8g section
   (line ~128: "large aligned copy (`4096B` and `16384B`)"; line ~130:
   reference run `bench-results/trials/20260308-155235-c8g-exact-stride-single/`,
   "remaining copy gap is concentrated in large aligned `16384B`").
   Those runs predate the 0.16 toolchain (AGENTS.md), so they are a
   map, not a verdict. Hypothesis: when the kernel *is* glibc's kernel
   (the AOR port), those rows sit at 1.00 by construction, and any
   remaining gap is measurement or alignment-of-the-loop-body, not
   algorithm. Test: `just bench-up c8g && just bench-run --rev main
   --rev p3-aor-port --suite quick`, then read the `copy/4096B` and
   `copy/16384B` aligned rows via `just b analyze`. If the residual
   survives parity-by-construction, iterate on loop-body alignment
   (64 B cacheline vs 16 B) as comptime variants — that case is cheap
   in the global-asm file.
2. **H2 — the pure-Zig challenger matches the asm baseline.** The
   challenger (§5) obeys E9/E10 but cannot reproduce the baseline's
   software pipelining or `.p2align` layout (E1/E9 caveats, §2).
   Hypothesis: it lands within the A/A noise floor of the baseline
   anyway on V1/V2/V3; if so it can take over the C-ABI role and the
   asm file shrinks to the fragments. Test: `just bench-run --rev
   p3-aor-port --rev p3-pure-zig --suite quick` on all three boxes.
   If it loses on any target, the asm baseline keeps the role — the
   lane rules already require per-target regressions to be gated out.
3. **H3 — DC ZVA wins for zeroing ≥ 256 B.** Hypothesis: `dc zva` loop
   beats the 64 B `stp` loop for memset(0) from 256 B up; glibc's 256 B
   threshold (0xb0130) is near-optimal on all three. A/B: ZVA kernel vs
   NEON-only kernel over 128 B–1 MiB, plus a threshold sweep (128/192/
   256/512) as comptime variants.
4. **H4 — the SVE predicated small path pays off only where VL is
   wide.** Hypothesis: on V1 (covers 0–64 B) the `whilelo` fragment
   beats the NEON overlapping small path — this now matters twice,
   since the G4 inline runtime path uses the same fragment; on V2/V3
   (covers only 0–32 B) it is a wash, and the pure-NEON small path
   (simpler, no asm) is preferable there. A/B: SVE-fragment build vs
   NEON-only small path on `dist/small` and the 0–128 B standard rows,
   per target.
5. **H5 — the 23c4393 layout fix is worth its ~7% on V2.** AOR's
   post-2.40 claim (§2) is reproducible in our harness: A/B the
   baseline port against itself with the two `.p2align 4` blocks and
   the `cntb` hoist reverted (trivial in the global-asm file; impossible
   to express in pure Zig — Zig has no block-alignment control).
6. **H6 — 128 B/iter unroll on V2/V3.** Their L2 is 2 MiB/core vs V1's
   1 MiB (`lscpu.txt`); hypothesis: 8×16 B unroll helps ≥ 64 KiB copies
   on V2/V3 only. If it hurts V1, gate by comptime model — the lane
   rules allow per-target selection.
7. **H7 — memset destination alignment side.** glibc aligns dst for
   memset (0xb0110) but src for memcpy (0xaee10). The copy side is
   already measured (0.15.2-era c8g work, `docs/slop/results/zig-0.15-benchmark-hosts.md`);
   hypothesis: dst-alignment is likewise optimal for memset. Cheap A/B
   against an unaligned variant.
8. **H8 — `prfm` prefetch beyond L2.** Hypothesis: software prefetch in
   the 64 B loop helps copies between L2 (1–2 MiB) and L3 (32–48 MiB).
   A/B on 256 KiB–32 MiB rows.
9. **H9 — `stnp` non-temporal stores above ~L3.** glibc aarch64 has
    no NT path, so any win here beats glibc outright at huge sizes.
    Hypothesis: helps ≥ 32 MiB; risk: hurts everything below. Lowest
    rank; only if G2 parity at large sizes is already met.

Closed before P3: the backward-loop pairing question (E12 — pairs on
all four CPUs); the copy-side source-alignment question (0.15.2
evidence, `docs/slop/results/zig-0.15-benchmark-hosts.md` c8g line ~125); the "unroll the
builtin's loop" framing (E8 — LLVM already unrolls it; the gap is loop
polish).

## 7. Open questions and risks

- **c9g VL and `-Dcpu=neoverse_v3` are unverified** (AGENTS.md says so).
  V3's SVE VL (128 vs 256 bit) only shifts the small-class boundary, and
  the runtime `cntb` design absorbs it — but P3 should run a one-line
  `cntb` probe on each box once and record the result in
  `docs/slop/results/zig-0.15-benchmark-hosts.md`.
- **ZVA block size is a system property, not a CPU feature.** 64 B is
  proven for the three bench targets twice (glibc resolver behavior §1;
  `dczid_el0=0x4` in `ld-diagnostics.txt:122-137`), and the kernel
  still keeps AOR's runtime DCZID check on the path (parent ruling) so
  a wrong host degrades to the NEON loop instead of corrupting memory
  or taking SIGILL. The generic build compiles ZVA out entirely; a
  cached one-time DCZID read for generic is P7 material.
- **Inline-asm scheduling.** The `memory` clobber on the SVE fragments
  may block LLVM reordering around the small path. E2's standalone
  codegen was clean; recheck in the real kernel. Fallback: whole-function
  global asm (E6 proves the mechanism) at the cost of G4 inlining for
  the affected class.
- **Frame pointers.** ReleaseFast still emits x29/x30 prologues (3
  instructions) on exported fns that build a frame (§4); shrink-wrapping
  covers the leaf classes. Set `omit_frame_pointer` on the fastmem
  module (`std/Build/Module.zig:256`); the global-asm baseline is
  unaffected either way.
- **The inline layer can silently become a call (E11).** An inlined
  loop takes the consumer's builtin setting; under default builtins it
  is idiom-recognized into `b memset`/`b memcpy` — breaking G4's "no
  call" and, under `exportSymbols`, recursing. The loop-free rule is a
  correctness constraint, and the no-relocations-out-of-inline-sites
  binary test belongs in the G4/G5 gate.
- **Global-asm baseline is a clean-room concentration point.** The AOR
  port is MIT-clean by construction (§2 attribution), but review should
  diff it against the upstream file at the pinned commit, not against
  the glibc disassembly.
- **`no_builtin` is load-bearing** (E5): without it, a Zig copy loop
  becomes `b memcpy` — infinite recursion under the export layer. The
  kernel module's build flag is a correctness issue, not a perf one.
- **Clean-room discipline in review.** The SVE small-copy idiom is 7
  instructions and also appears in MIT-licensed AOR
  (`memcpy-sve.S:52-64`); our fragments must be written against the AOR
  file, not the glibc disassembly, and carry the AOR header.
- **Overlap-safety of the small classes** rests on "all loads precede
  all stores within a class" — true for the predicated pair (ld1b ×2
  then st1b ×2) and the overlapping-NEON classes. The P2 fuzzer (both
  overlap directions, gaps 1–128) is the enforcement; do not reorder
  loads after stores inside a class.
- **The `dc zva` tail-first trick** zeroes only full 64 B blocks inside
  [dst, dst+len) because the tail is written first and the count is
  biased (AOR `memset-sve.S:83-98`). Misporting the bias by one block
  zeroes past the buffer — exactly what the G1 guard-page tests catch.
  Port the arithmetic, then trust the harness.

---

### Source index

- glibc 2.40 disassembly: `.bench-cache/glibc/libc-aarch64-linux-gnu.so.6`
  (`llvm-objdump -d --disassemble-symbols=...`; addresses cited inline).
- Arm Optimized Routines @ `5e20a93f440ca771bcdb757cc13c3beee217e534`,
  `string/aarch64/`; improvement commit `23c4393006122497ea989725c9e34d253bc1e62b`.
- Zig 0.16.0 lib: `/nix/store/h4am1dpj4li41cq58861nysgaip7036s-zig-0.16.0/lib/zig`.
- Experiments E1–E16: compiled 2026-09-23 with the repo devshell
  (`zig build-obj -target aarch64-linux-gnu -mcpu=<cpu> -OReleaseFast
  ± -fno-builtin`; E8/E13 used the toolchain's own `compiler_rt.zig` as
  root; E11 used a two-module `zig build`; E15 used `@compileLog`).
  Commands and outcomes quoted in §4.

### Disagreements with the reviewer

None of substance. One narrow factual correction in the other
direction: the review (P2, "Resolver") says `__libc_memset_ifunc` is
not in the symbol table; it is — `llvm-nm` on the binary lists
`00000000000a7800 t __libc_memset_ifunc` alongside the `i`-type
`memset` at the same address. The substantive part of that finding
(the missing `sve` flag test at 0xa7828, and MOPS checked first at
0xa7814) was correct and is now in §1. Everything else in the review
reproduced under my own hands: E9 (pairing rule), E10 (array spill),
E11 (inline/no_builtin escape), E12 (backward pairing, closing old H6),
E13 (generic compiler-rt weakness), E14 (noalias condition), E15
(`suggestVectorLength` = 32 on SVE targets), E16 (nzcv/output-operand
fragment), the memmove 0xd0-byte spill frame, and the AOR/glibc 64-byte
class boundary difference.
