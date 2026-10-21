# x86_64 design memo (P1b)

Status: revised after review (GPT-6 Astra: 2 P0, 3 P1, 2 P2 findings, all
fixed). Author: Opus 5.5 (research lane P1b), 2026-09-23.

This memo is research. It describes behavior and proposes a design. It
contains no glibc code. Disassembly addresses refer to
`.bench-cache/glibc/libc-x86_64-linux-gnu.so.6` (glibc 2.40, NixOS
25.11 AMI build). Host facts refer to `docs/slop/research/hosts/<target>/`.

Sections 1-3 describe glibc, llvm-libc and compiler-rt. Section 4
proves what Zig 0.16 can express. Section 5 is the design. Section 6
lists the hardware tests for P3. Section 7 lists open questions and
risks.

## Sources and conventions

| Tag | Source |
|---|---|
| `so:0x…` | address in `.bench-cache/glibc/libc-x86_64-linux-gnu.so.6`, disassembled with `nix develop -c llvm-objdump -d --no-show-raw-insn --start-address=… --stop-address=…` |
| `hosts/<t>/<file>:<line>` | `docs/slop/research/hosts/<t>/` host facts (P0) |
| `glibc-src <file>:<line>` | glibc `release/2.40/master`, commit `cdaa5d6db08ee6d7cdcb008ae83b6fe7856291c4`, fetched from sourceware gitweb on 2026-09-23. Read for behavior only. The branch head is newer than the NixOS `glibc-2.40-224` build on the hosts, so the host facts win where they differ. |
| `llvm-libc <file>:<line>` | `llvm/llvm-project` commit `b19a36aaf4b9aaea539b903bd515b54a9f23a639` (main, 2026-09-24T02:13Z), path `libc/src/string/…` |
| `zig-lib <file>:<line>` | `/nix/store/h4am1dpj4li41cq58861nysgaip7036s-zig-0.16.0/lib/zig/…` |
| `exp:<name>` | a compiled experiment in section 4, with its command and output |

"n" is the byte count. "vec" is one vector register of the width in
question. Boundaries use the comparison that the code makes: "n ≤ 128"
means the code takes the branch for 128.

## 1. What glibc 2.40 does on each x86 target

### 1.1 Variant selection

All four x86 targets run an AVX-512 variant (`hosts/README.md`, table).
The memmove selector is `glibc-src sysdeps/x86_64/multiarch/ifunc-memmove.h:51-117`:

1. `Prefer_ERMS` or `Prefer_FSRM` selects the plain `erms` variant
   (lines 56-58). Both flags are 0 on all four hosts
   (`hosts/<t>/ld-diagnostics.txt:208,211`).
2. AVX512F usable and `Prefer_No_AVX512` clear, with AVX512VL, selects
   `avx512_unaligned_erms` if ERMS is usable, else `avx512_unaligned`
   (lines 60-69).
3. Only after that come `evex` (AVX512VL with 32-byte vectors), `avx`,
   `ssse3`, and `sse2` (lines 74-116).

`Prefer_No_AVX512` is 0 on all four hosts (`ld-diagnostics.txt:209`).
The only place that sets it is the Intel branch of
`glibc-src sysdeps/x86/cpu-features.c:975-977`, and only when the CPU
has no AVX-VNNI. c7i and c8i report `avx_vnni` (`hosts/c7i/cpu.txt`,
`hosts/c8i/cpu.txt`). The AMD branch never sets the flag, so Genoa
selects AVX-512 without AVX-VNNI (`hosts/c7a/cpu.txt` has no
`avx_vnni`). The source comment at lines 973-974 gives the reason: CPUs
with AVX-512 and AVX-VNNI do not lower the frequency for ZMM loads and
stores.

ERMS decides between the two AVX-512 entry points. c7a reports no
`erms` flag (`hosts/c7a/cpu.txt`), so it gets `__memmove_avx512_unaligned`
(`so:0x1962f0`). c7i, c8i and c8a report `erms` and get
`__memmove_avx512_unaligned_erms` (`so:0x196380`). memset follows the
same pattern: `__memset_avx512_unaligned` (`so:0x196b80`) on c7a,
`__memset_avx512_unaligned_erms` (`so:0x196c00`) elsewhere
(`hosts/<t>/libc-probe.json`).

FSRM: only c8a reports `fsrm` (`hosts/c8a/cpu.txt`). c7i and c8i do not
expose it to the guest, although Sapphire Rapids has the feature on bare
metal (unverified for these instances beyond the absent flag).

No AVX-512 function in the range uses `vzeroupper`
(`grep -c vzeroupper` on the disassembly of `so:0x1962f0-0x196b40` and
`so:0x196b80-0x196dc0` gives 0). The functions use only
`xmm0/xmm1` (VEX, upper bits zeroed) and `ymm16-31` / `zmm16-31`
(EVEX-only registers), which have no SSE/AVX transition penalty.

### 1.2 Thresholds on each host

All values are bytes, from `hosts/<t>/ld-diagnostics.txt:218-237`.

| Target | variant | `rep_movsb_threshold` | `rep_movsb_stop_threshold` | `non_temporal_threshold` | `rep_stosb_threshold` | `memset_non_temporal_threshold` | L3 (`shared_cache_size`) | NT divisor |
|---|---|---|---|---|---|---|---|---|
| c7i | erms | 16384 (16 KiB) | 0x3580000 (53.5 MiB) | 53.5 MiB | 2048 | 53.5 MiB | 107 MiB | 2 |
| c8i | erms | 16384 | 0xf100000 (241 MiB) | 241 MiB | 2048 | 241 MiB | 482 MiB | 2 |
| c7a | non-erms | 0xc00000 (12 MiB), not read | 12 MiB | 12 MiB | SIZE_MAX, not read | 12 MiB, not reachable | 16 MiB | 4 |
| c8a | erms | 12 MiB | 12 MiB | 12 MiB | SIZE_MAX | 12 MiB, not reachable | 16 MiB | 4 |

Where the numbers come from (`glibc-src sysdeps/x86/dl-cacheinfo.h`):

- `non_temporal_threshold` = shared L3 / divisor (lines 950-951), with a
  floor of 3/4 of the per-thread L3 (956-959). Without ERMS the floor is
  the value (966-968). The divisor is 2 for Sapphire Rapids and Granite
  Rapids (`cpu-features.c:954-961`) and 4 by default
  (`cpu-features.c:742`). c7i: 107 MiB / 2 = 53.5 MiB. c7a and c8a:
  12 MiB = 3/4 of 16 MiB, the floor.
- `rep_movsb_threshold` = 4096 × (64 / 16) = 16 KiB for the AVX-512
  variants (lines 996-1001). FSRM lowers it to 2112 (1015-1016),
  but no Intel host exposes FSRM. On AMD, line 1021-1022 overrides it with
  `non_temporal_threshold`. The comment (1018-1020) cites BZ #30994: REP
  MOVSB is slower than the vector loop on Zen 3+ in many cases.
- `rep_movsb_stop_threshold` = `non_temporal_threshold` (1084-1087).
- `rep_stosb_threshold` = 2048 (1025), SIZE_MAX on AMD (1065-1069,
  "the vectorized loop is slightly better than ERMS").

### 1.3 memmove / memcpy size classes

`memcpy` and `memmove` are the same code (`so:0x1962f0` has both
symbol names, `llvm-nm`). The code has no "no overlap" fast path: every
class below is overlap-safe. VEC = 64 bytes.

| n | Method | Registers | Address |
|---|---|---|---|
| 0 | return | - | `so:0x1963e5-0x1963fa` |
| 1 | one byte | GPR | `so:0x1963ea-0x1963f8` |
| 2-3 | first byte + last 2 bytes, overlapping | GPR | `so:0x1963ee-0x1963f8` |
| 4-7 | first 4 + last 4, overlapping | GPR | `so:0x1963b7-0x1963c1` |
| 8-15 | first 8 + last 8 | GPR | `so:0x196432-0x196442` |
| 16-31 | first 16 + last 16 | `xmm0/1` | `so:0x196400-0x196414` |
| 32-63 | first 32 + last 32 | `ymm16/17` | `so:0x196415-0x196431` |
| 64-128 | first VEC + last VEC | `zmm16/17` | `so:0x19638d-0x1963b6` |
| 129-256 | 2 VEC from the start + 2 VEC from the end | `zmm16-19` | `so:0x196496-0x1964a4`, `so:0x196443-0x196470` |
| 257-512 | 4 VEC from the start + 4 VEC from the end | `zmm16-23` | `so:0x1964a6-0x19650f` |
| > 512 | loop, see 1.4 | | `so:0x196510` |

The small-size ladder (`so:0x1963d0-0x1963e3`) tests 32, 16 and 8 with
32-bit compares, then 4 with a subtract. Each class issues all its loads before its
stores. That order is what makes the class correct for overlap in
both directions, and it is why no direction test runs for n ≤ 512.
The memmove small path uses no masked loads or stores. memset does
(1.8).

The first 64-byte load of the source happens at `so:0x19638d`, before
the n ≤ 128 test. Every path above 64 bytes reuses that register as the
head vector. When the path stores it differs:

| Path | Head VEC store | Address |
|---|---|---|
| 64-128 | first, before the tail | `so:0x1963a8` |
| 129-256 | first of the 4 stores | `so:0x196453` |
| 257-512 | first of the 8 stores | `so:0x1964d4` |
| forward loop | **last**, after the 4 tail VEC | `so:0x1965e4` |
| backward loop | after the loop, first of the 5 saved VEC | `so:0x19666d` |
| `rep movsb` (both alignments) | after `rep movsb` | `so:0x1966c1`, `so:0x196714` |
| NT path | **before** the page loop | `so:0x19673c` |

In the straight-line classes the order does not matter for correctness,
because all loads precede all stores. The loops and `rep movsb` also
run for overlapping buffers. There, an early head store at
[dst, dst + 64) can overwrite source bytes that the bulk copy has not
read yet. The head value was loaded at entry, so a store after the bulk
copy is always safe. The NT path runs only for buffers that do not
overlap (1.7 excludes both overlap cases before it), so it can store the
head first. Its bulk copy then starts at the next 64-byte boundary above
dst (`so:0x196742-0x196753`) and rewrites part of the head bytes with
the same values.

### 1.4 The vector loop (n > 512, below the rep movsb and NT thresholds)

Entry (`so:0x196510-0x196526`):

1. d = dst − src. If d < n as unsigned, the destination starts inside
   the source: take the backward loop (`so:0x1965f0`). If d = 0, return
   (`so:0x1965f3`).
2. If n > `non_temporal_threshold`, go to the NT path (1.6).
3. 4K-aliasing test (`so:0x19652c-0x196540`): if the source does not
   start inside (dst, dst + n), and bits 8-11 of d are all zero (the
   distance modulo 4 KiB is under 256 bytes), take the **backward** loop
   although forward is also correct. A forward copy with that distance
   makes each load hit the low 12 address bits of a store that is still
   in flight. The CPU then predicts a false store-to-load dependency.
   This "4K aliasing" penalty is described in the Intel optimization
   manual (unverified: not re-read for this memo). Copying backward
   makes the loads run ahead of the stores in the other direction.

Forward loop (`so:0x196546-0x1965ea`):

- Before the loop, it loads the last 4 VEC of the source
  (`zmm21-24`). The head VEC is already in `zmm16`.
- It rounds the destination up to the next 64-byte boundary. The
  rounding is strict: an aligned destination moves up by 64, and the
  head VEC covers the first 64 bytes. The source moves by the same
  amount, so source loads are unaligned.
- Body at `so:0x196580` (the loop start is 64-byte aligned, with padding
  at `so:0x19657e`): 4 unaligned 64-byte loads, then 4 aligned stores
  (`vmovdqa64`), 256 bytes per iteration. The loop ends when the
  destination pointer reaches (dst + n − 256).
- After the loop, it stores the 4 saved tail VEC so that they end at
  dst + n, and then stores the head VEC at dst.
- No software prefetch.

Backward loop (`so:0x1965f5-0x196690`): the mirror image. It saves the
first 4 VEC and the last VEC, aligns the end of the destination down to
64 bytes, runs 4 loads high-to-low and 4 aligned stores per iteration
(`so:0x196624-0x19666b`), then stores the 5 saved VEC. No prefetch.

Both loops align the destination, not the source. Unroll is 4 × 64 B.

### 1.5 rep movsb (erms variant only)

After n > 128, the erms entry compares n with `__x86_rep_movsb_threshold`
(`so:0x196480`). The non-erms entry skips that compare and jumps
straight to the n > 512 test (`so:0x19630e` → `so:0x19648d`). Above the
threshold (`so:0x1966d0-0x19671a`):

1. If the destination starts inside the source (backward needed), use
   the backward vector loop. glibc never runs `rep movsb` backward.
2. If n ≥ `rep_movsb_stop_threshold`, go to the NT path.
3. If `__x86_string_control` bit 0 (`Avoid_Short_Distance_REP_MOVSB`) is
   set and the source is 1-63 bytes ahead of the destination, use the
   forward vector loop instead (`so:0x1966eb-0x1966f7`). The flag is 0
   on all hosts (`ld-diagnostics.txt:212`). glibc sets it only on Intel
   CPUs with FSRM (`cpu-features.c:986-989`).
4. If bits 9-11 of d are not all zero (`so:0x1966a0`), align the
   **destination** up to 64 bytes and run `rep movsb` over the rest
   (`so:0x1966fd-0x19671a`). If they are all zero (distance modulo 4 KiB
   under 512 bytes), align the **source** up to the next 64-byte boundary
   instead (`so:0x1966a8-0x1966c7`).
5. In both cases, the head VEC loaded at entry is stored at dst after
   `rep movsb`. `rep movsb` itself copies to the exact end, so no tail
   fix-up is needed.

Effective `rep movsb` window per host (1.2):

| Target | `rep movsb` used for forward-safe n in |
|---|---|
| c7i | 16385 … 56,098,815 (16 KiB < n < 53.5 MiB) |
| c8i | 16385 … 252,706,815 (16 KiB < n < 241 MiB) |
| c7a | never (non-erms entry) |
| c8a | never: n > 12 MiB is required, and n ≥ 12 MiB goes to NT first |

In the standard suite (sizes up to 1 MiB, `docs/slop/bench-design.md`,
"Cases"), glibc uses `rep movsb` on Intel for 65536, 262144 and 1048576,
and for no size on AMD. 16384 stays on the vector loop (the compare is
"above").

### 1.6 Non-temporal path (large_memcpy)

Entry at `so:0x196720`:

- If n is below `non_temporal_threshold`, return to the vector loop
  (`so:0x196727-0x19672a`). This is reachable only when the stop
  threshold is below the NT threshold, which no host has.
- If the source starts inside (dst, dst + n), the copy overlaps in the
  forward direction. NT stores are then not used. The forward vector loop
  runs (`so:0x196730-0x196736`).
- It stores the head VEC unaligned and aligns the destination up to 64
  bytes (`so:0x19673c-0x196753`).
- It interleaves pages. The default interleaves 2 pages
  (`so:0x196774-0x196852`): the copy runs in 8 KiB blocks. Each of 32
  inner iterations issues 16 `prefetcht0` (8 lines ahead in each page,
  starting 256 bytes ahead), loads 2 VEC from each page, and writes them
  with 4 `vmovntdq`. It uses 4 pages (`so:0x196930-0x196a62`, 16 KiB
  blocks, 8 `vmovntdq` per iteration) when bits 9-11 of (dst − src − 1)
  are all zero, that is d mod 4096 in [1, 512] (page-distance
  aliasing), or when n ≥ 16 × `non_temporal_threshold`
  (`so:0x196756-0x19676e`). Page-aligned buffers (d mod 4096 = 0) get 2
  pages (1.7, step 4).
- `sfence` after the page loop (`so:0x196852`, `so:0x196a62`).
- The remainder (under one block) uses the temporal 4-VEC loop with
  `prefetcht0` on both source and destination 256-448 bytes ahead
  (`so:0x196861-0x1968e9`), then the last 256 bytes from the end
  (`so:0x1968ef-0x19692f`).

The NT thresholds (12 MiB and up) are above every standard-suite size.
They matter only for a large-size suite.

### 1.7 memmove: dispatch summary for n > 512

d = dst − src, wrapping. T_rep, T_stop and T_nt are the thresholds of
1.2. For n ≤ 512, every class loads all bytes before it stores, and no
test below runs.

**Step 1, direction and range** (`so:0x196480`, `so:0x196510-0x196526`,
`so:0x1966d0-0x1966e9`, `so:0x196720-0x196736`). The comparisons keep
their exact form: `ja` is "above", `jae` is "above or equal", `jb` is
"below".

| Case | Intel c7i/c8i: 512 < n ≤ 16384 | Intel: 16384 < n < T_stop | Intel: n ≥ T_stop (= T_nt) | AMD c7a/c8a: 512 < n ≤ 12 MiB | AMD: n > 12 MiB |
|---|---|---|---|---|---|
| d = 0 | return | return | return | return | return |
| 0 < d < n (dst inside the source): backward needed | backward loop | backward loop | backward loop | backward loop | backward loop |
| 0 < src − dst < n (src inside the destination): forward needed | forward loop, see step 2 | `rep movsb`, see step 3 | forward loop (`so:0x196736`) | forward loop | forward loop (`so:0x196736`) |
| disjoint | vector loop, direction from step 2 | `rep movsb`, see step 3 | NT, pages from step 4 | vector loop, direction from step 2 | NT, pages from step 4 |

Boundaries:

- Intel enters the `rep movsb` block for n > T_rep (`so:0x196487`, "above").
  Inside it, n ≥ T_stop (`so:0x1966e9`, "above or equal") goes to the NT
  block, and the NT block uses NT stores unless n < T_nt
  (`so:0x19672a`). With T_stop = T_nt, Intel uses NT stores from n = T_nt
  inclusive.
- On AMD, the vector path uses NT for n > T_nt (`so:0x196526`,
  "above"). c7a has no `rep movsb` block (non-erms entry). The erms entry
  on c8a enters the block only for n > 12 MiB and leaves it at once for
  NT, because n ≥ T_stop there. So both AMD hosts use NT from 12 MiB + 1. **At exactly
  12 MiB, both stay on the temporal loop.**

**Step 2, temporal loop direction** (only for the "vector loop" cells,
`so:0x19652c-0x196540`). If the source is not inside (dst, dst + n) and
bits 8-11 of d are all zero (d mod 4096 < 256, including d mod 4096 = 0),
use the backward loop. Else use the forward loop. This test runs only on
the vector path. On Intel above 16384, the `rep movsb` block takes the
case first, so page-aligned disjoint buffers get `rep movsb` there, not
the backward loop.

**Step 3, `rep movsb` alignment** (`so:0x1966a0`, `so:0x1966a8-0x1966c7`,
`so:0x1966fd-0x19671a`). If bits 9-11 of d are all zero
(d mod 4096 < 512), align the source up to the next 64-byte boundary.
Else align the destination up to 64.

**Step 4, NT page interleave** (`so:0x196756-0x19676e`). Use 4 pages if
bits 9-11 of (d − 1) are all zero, that is if d mod 4096 is in [1, 512],
or if n ≥ 16 × T_nt. Else use 2 pages. **Page-aligned buffers
(d mod 4096 = 0) get 2 pages**, because d − 1 has bits 9-11 set.

### 1.8 memset size classes

`__memset_avx512_unaligned_erms` (`so:0x196c00`), with the non-erms
entry at `so:0x196b80`. The byte is broadcast to `zmm16` first
(`vpbroadcastb` from a GPR, `so:0x196c04`).

| n | Method | Address |
|---|---|---|
| 0-63, and (dst mod 4096) ≤ 0xFC0 | **one masked 64-byte store**. The mask has the n low bits set, built with `bzhi` and moved to `k1` | `so:0x196bc0-0x196be9` |
| 0-63, and the 64-byte window crosses a page | ladder: 32-63 two `ymm16`, 16-31 two `xmm16`, 8-15 two 8-byte GPR, 4-7 two 4-byte, 2-3 word + byte, 1 byte, 0 return | `so:0x196cdd-0x196d37` |
| 64-128 | first VEC + last VEC | `so:0x196c1c-0x196c2a` |
| 129-256 | 2 VEC from the start + 2 from the end | `so:0x196c49-0x196c5d`, `so:0x196c2b` |
| 257-512 | 4 VEC from the start + 4 from the end | `so:0x196c5f-0x196c78`, `so:0x196ca8` |
| > 512 | 4 unaligned head VEC at dst … dst + 255. Let a = dst rounded down to 64 and e = dst + n − 512. The loop stores 4 aligned VEC at a + 256 … a + 511, adds 256 to a, and repeats while a < e. The **first loop store is at a + 256**, which is in [dst + 193, dst + 256]: it can overlap the last head VEC, and it is never below dst. Then 4 unaligned VEC at e + 256 … dst + n − 1, the last 256 bytes | `so:0x196c5f-0x196cc4` (loop `so:0x196c80-0x196ca6`) |
| erms, n > `rep_stosb_threshold` and n < `memset_non_temporal_threshold` | `rep stosb` from the unaligned dst, no fix-up | `so:0x196cc5-0x196cdc` |
| erms, n ≥ `memset_non_temporal_threshold` | head VEC, dst up to 64, 4 `vmovntdq` per iteration, `sfence`, 4 unaligned tail VEC | `so:0x196d40-0x196d9a` |

The page test keeps the masked store away from a page that the caller
does not own. Architecturally, masked-off elements do not fault (Intel
SDM, AVX-512 masked stores. Unverified: not re-read for this memo). A
masked access that crosses into an unmapped or protected page can still
take a slow microcode assist (unverified). glibc pays one `and` and one
compare to avoid the case, which suggests that the cost is real.

The non-erms entry jumps from n > 128 directly to the vector path
(`so:0x196b9a` → `so:0x196c49`). The NT memset path is reachable only
through the `rep stosb` branch (`so:0x196ccc` is the only jump to
`so:0x196d40`). Result:

| Target | 129 … 2048 | 2049 … NT | ≥ NT |
|---|---|---|---|
| c7i, c8i | 4-VEC aligned loop | `rep stosb` | NT loop (53.5 MiB / 241 MiB) |
| c7a, c8a | 4-VEC aligned loop | 4-VEC aligned loop | 4-VEC aligned loop (no NT, although the threshold is 12 MiB) |

### 1.9 ERMS against non-ERMS: c7a and c8a

The two AVX-512 entry points share every instruction after the n > 128
test. The erms entry adds one compare with the memory value
`__x86_rep_movsb_threshold` (`so:0x196480`) and, for memset, with
`__x86_rep_stosb_threshold` (`so:0x196c40`). With the c8a thresholds,
neither branch can reach `rep movsb` or `rep stosb` (1.5, 1.8). So c7a
and c8a run the same algorithm. The only difference is one load and one
compare-and-branch for n > 128. For fastmem, c7a and c8a can share one
x86 AMD configuration: no `rep movsb`, no `rep stosb`. That is glibc's
policy, based on BZ #30994. It is not a measurement on Turin. Section 6
tests it.

### 1.10 The evex and avx variants, for comparison

- `__memmove_evex_unaligned_erms` (`so:0x18d2c0`) is the same algorithm
  with 32-byte vectors in `ymm16-31`. Its class edges scale with VEC:
  n < 32, ≤ 64, ≤ 128, ≤ 256, and the loop above 256
  (`so:0x18d2c7`, `so:0x18d2d3`, `so:0x18d39d`, `so:0x18d38d`). The NT
  loop writes 4 × 32 B per page per iteration (`so:0x18d714-0x18d743`).
- `__memmove_avx_unaligned_erms` (`so:0x17d340`) is the same again with
  `ymm0-15`. It must run `vzeroupper` before it returns (22 in the
  function range).
- `__memset_evex_unaligned_erms` uses one masked **32-byte** store for
  n < 32 with a 0xFE0 page test (`so:0x18dd46-0x18dd60`). The avx2
  memset has no masked store (no `k` register in `so:0x17dcd0-0x17df00`).
- The x86_64_v3 baseline (G6) corresponds to the avx variant: 32-byte
  vectors, `ymm0-15`, `vzeroupper`, and no masking.

## 2. What llvm-libc does

Pinned commit: `llvm/llvm-project` `b19a36aaf4b9aaea539b903bd515b54a9f23a639`.
All paths are under `libc/src/string/`. License: Apache-2.0 WITH
LLVM-exception (the SPDX line in every file header, for example
`memory_utils/x86_64/inline_memcpy.h:5`).

### 2.1 Structure

llvm-libc builds every function from small templated building blocks
(`memory_utils/README.md:13-17`): `block` (one fixed-size copy),
`tail` (the last `SIZE` bytes), `head_tail` (both, overlapping), and
`loop_and_tail`. A block is `__builtin_memcpy_inline` of a constant size
(`memory_utils/op_builtin.h:30-33`, `memory_utils/utils.h:75-88`), so
the compiler picks the instructions. Everything is `LIBC_INLINE` and the
entry points are `[[gnu::flatten]]` (`memory_utils/inline_memcpy.h:47-51`).
Feature selection is compile-time only (`K_AVX512_F`, `K_AVX` …,
`memory_utils/op_x86.h:54-59`). There is no runtime dispatch.

### 2.2 memcpy (`memory_utils/x86_64/inline_memcpy.h`)

`memcpy.cpp:17-26` calls `inline_memcpy`, which on x86 is
`inline_memcpy_x86_maybe_interpose_repmovsb`
(`memory_utils/inline_memcpy.h:24-27`).

| n | Method | Lines |
|---|---|---|
| 0, 1, 2, 3, 4 | exact block of that size | 210-219 |
| 5-7 | 4-byte head + tail | 220-221 |
| 8-15 | 8-byte head + tail | 231-232 |
| 16-31 | 16-byte head + tail | 233-234 |
| 32-63 | 32-byte head + tail | 235-236 |
| 64-128 | 64-byte head + tail | 84-85 |
| 129-255 | 128-byte head + tail | 86-87 |
| ≥ 256 | one 32-byte block, align **dst** to 32, loop of 64-byte blocks, 64-byte tail | 88-90 |

- The vector size is 64 with AVX512F, 32 with AVX, 16 with SSE2
  (206-209). With AVX-512 the class edges are "count < 16/32/64". A
  power-of-two count goes to the larger class (the comment at 222-230).
- `rep movsb`: off by default. `LIBC_COPT_MEMCPY_X86_USE_REPMOVSB_FROM_SIZE`
  defaults to SIZE_MAX, "do not use" (48-54). With a value, n ≥ value
  uses `rep movsb` (252-265). The instruction is one `asm volatile` with
  `+D`, `+S`, `+c` operands and a memory clobber
  (`memory_utils/op_x86.h:64-71`).
- Non-temporal stores: off by default. With
  `LIBC_COPT_MEMCPY_X86_USE_NTA_STORES` and AVX, the threshold is 1 MiB,
  "mostly based on empirical data" (39-46). NT stores exist only in the
  software-prefetching variant (170-183): 32-byte streams
  (`__builtin_nontemporal_store`, `op_x86.h:80-87`) and `sfence`
  (`op_x86.h:89-95`).
- Software prefetching: off by default
  (`LIBC_COPT_MEMCPY_X86_USE_SOFTWARE_PREFETCHING`, 36-37). The variant
  prefetches the source for read and the destination for write, 1-3
  cache lines ahead, and copies 3 cache lines per iteration (147-202).
  It copies one cache line at a time "to prevent the use of `rep;movsb`"
  (133, 190): the authors saw LLVM turn a large block copy into
  `rep movsb`.

### 2.3 memmove (`memmove.cpp`, `memory_utils/x86_64/inline_memmove.h`)

- `memmove.cpp:28-33`: small sizes first with no overlap test, then
  `is_disjoint` (`memory_utils/utils.h:60-73`, a branch-free signed
  distance test), which sends disjoint buffers to `inline_memcpy`. Only
  true overlap reaches the memmove loop.
- Small sizes (`inline_memmove.h:21-93`): 0-4 exact, 5-7 4-byte head/tail,
  then 8/16/32/64-byte head/tail, and n ≤ 128 as a 64-byte (one zmm)
  head/tail. `head_tail` loads both ends before it stores
  (`memory_utils/op_generic.h:237-246`). That is the same trick as glibc.
- Overlap (`inline_memmove.h:95-116`): if dst < src, align the
  **source** with a 32-byte head/tail (`align_forward<Arg::Src>`,
  `op_generic.h:266-274`), then `loop_and_tail_forward` with 64-byte
  blocks (`op_generic.h:320-332`). The tail is loaded before the loop.
  Otherwise the mirror image (`align_backward`, `loop_and_tail_backward`,
  `op_generic.h:294-304`, `348-359`). Both loops are
  `LIBC_LOOP_NOUNROLL`: one vector per iteration.
- No 4K-aliasing test, no `rep movsb`, no NT stores in memmove.

### 2.4 memset (`memory_utils/x86_64/inline_memset.h`)

| n | Method | Lines |
|---|---|---|
| 0, 1, 2, 3 | exact | 84-91 |
| 4-8 | 4-byte head + tail | 92-93 |
| 9-16 | 8-byte head + tail | 94-95 |
| 17-32 | 16-byte head + tail | 96-97 |
| 33-64 | 32-byte head + tail | 98-99 |
| 65-128 | 64-byte head + tail | 102-103 |
| > 128 | one 32-byte block, align dst to 32, loop of **32-byte** blocks, 32-byte tail | 104-107 |

No `rep stosb`, no NT stores, no masked stores. An optional prefetching
variant (`LIBC_COPT_MEMSET_X86_USE_SOFTWARE_PREFETCHING`, 29-30, 52-80)
prefetches for write 5 cache lines ahead.

No llvm-libc memcpy, memmove or memset uses AVX-512 masking.
`K_AVX512_BW` is defined (`op_x86.h:59`) but the only AVX-512 mask use in
`memory_utils/` is bcmp/memcmp (`op_x86.h:38-39`).

### 2.5 What is portable to fastmem

Apache-2.0 WITH LLVM-exception is a permitted source
(`docs/slop/fastmem-plan.md`, "Licensing"). A port keeps the upstream
notice, names the file and commit, and gets a `THIRD_PARTY.md` entry.

| Part | Port? | Why |
|---|---|---|
| Block vocabulary (`block`, `tail`, `head_tail`, `loop_and_tail`, `align_forward/backward`, `loop_and_tail_forward/backward`), `op_generic.h:176-360` | **Yes, as a design**. The Zig form is `inline fn` over a comptime size. | It is the right shape for comptime-specialized, inlinable code (G4). The code is short. A Zig rewrite from the idea is simpler than a line-by-line port, but cite it either way. |
| `is_disjoint`, `utils.h:60-73` | Yes | A branch-free disjoint test is what `move` needs to route to the copy kernel. |
| memcpy class table, `x86_64/inline_memcpy.h:205-250` | Yes, as reference | The table matches glibc up to 128. The 129-255 class as one 128-byte head/tail matches glibc's 2+2 VEC. |
| Power-of-two edge rule (222-230) | Not needed | glibc already does it: n = 16, 32 and 64 fall in the 16-31, 32-63 and 64-128 classes, as a collapsed head/tail pair (1.3). |
| `rep movsb` asm (`op_x86.h:64-71`) | Trivial | One instruction with register constraints. Zig syntax differs. |
| memmove loop (1 VEC/iteration, source-aligned) | No | glibc's 4-VEC, destination-aligned loop is stronger on paper, and it is what we must match. |
| memset loop (32-byte blocks under AVX-512) | No | Half the store width that glibc uses. |
| NT threshold 1 MiB | No | It is far below glibc's 12-241 MiB on our hosts (1.2). |
| Software prefetching variants | No | Off by default upstream. glibc uses no prefetch below the NT threshold. |

llvm-libc is a reference for code structure and for the inline layer. It
is not a reference for large-size performance on these hosts: it has no
default `rep movsb`, no 4-VEC unroll, and no aliasing test.

## 3. What Zig 0.16 compiler-rt does, and why it loses

### 3.1 Source

- Exports: `zig-lib compiler_rt.zig:302-307` exports `memcpy`, `memset`,
  `__memset`, `memmove`. Linkage is weak (`compiler_rt.zig:31-36`),
  visibility hidden in static links (`compiler_rt.zig:41-44`).
  ReleaseFast selects `memcpyFast` / `memmoveFast`
  (`compiler_rt/memcpy.zig:14-17`, `compiler_rt/memmove.zig:17-20`).
- The element type is `PreferredLoadStoreElement`: a vector of
  `std.simd.suggestVectorLength(u8)` bytes (`compiler_rt.zig:350-359`).
  `suggestVectorLength` returns 512 bits only if AVX512F is present and
  `prefer_256_bit` is absent (`zig-lib std/simd.zig:19-20`). exp:features
  (4.1) shows that the result is **32 bytes on sapphirerapids and
  graniterapids** (their LLVM models carry `prefer_256_bit`) and 64
  bytes on znver4 and znver5.
- `memcpyFast` (`compiler_rt/memcpy.zig:37-47`): n < 4 copies 3 bytes
  (first, middle, last, lines 67-81). n < 16 uses four overlapping 4-byte
  copies (`copyRange4`, 176-195). Up to `2 × Element`, four overlapping
  copies of the next power-of-4 size (83-98). Above that, `copyForwards`
  (100-119): the first Element, then a loop of single-Element copies
  with the **source** aligned, then the last Element. No `rep movsb`, no
  NT stores, no prefetch.
- `memmoveFast` (`compiler_rt/memmove.zig:41-57`): the same small
  classes, loads before stores (133-142). Then a direction choice by
  `src < dest` only, with no disjoint test (50-54). `copyBackwards`
  (196-217) aligns the destination end. `copyForwards` (145-166) aligns
  the source.
- `memset` (`compiler_rt.zig:677-692`) is a byte loop.

### 3.2 Generated code (exp:crt)

Command:

```
zig build-exe -target x86_64-linux-none -mcpu=<cpu> -OReleaseFast crt.zig
llvm-objdump -d --no-show-raw-insn --disassemble-symbols=memcpy,memmove,memset crt_<cpu>
```

`crt.zig` calls `@memcpy`, `@memmove`, `@memset` with a runtime length.
The binary binds all three to compiler-rt (`llvm-nm`: local `t memcpy`
at 0x1002680, `t memmove` at 0x10022f0, `t memset` at 0x1002260 for
sapphirerapids). compiler-rt is compiled for the `-mcpu` of the build:
the znver4 binary uses `zmm` (95 lines), the sapphirerapids and
x86_64_v3 binaries use only `ymm`.

| Observation | sapphirerapids | znver4 | x86_64_v3 |
|---|---|---|---|
| memcpy vector width | 32 B (`ymm0`) | 64 B (`zmm0-2`) | 32 B |
| memcpy loop | LLVM unrolls 8 × 32 B = 256 B/iter, aligned loads, unaligned stores (0x1002760-0x10027ee) | 8 × 64 B = 512 B/iter (0x1002880-0x10028fb) | 8 × 32 B |
| memcpy 16-63 | four overlapping `xmm` copies | same | same |
| memcpy prologue | `push rbp` / `mov rbp, rsp` frame on every call (0x1002680) | same | same |
| memcpy epilogue | `vzeroupper` (0x1002832) | `vzeroupper` (0x1002958) | `vzeroupper` |
| memmove 16-63 | spills the four `xmm` values to the stack and reloads them (15 `(%rbp)` references in the function) | 22 `(%rbp)` references | not checked |
| memset | **byte stores**, 8 per iteration, no vectors (0x10022b0-0x10022de) | byte stores (9 `movb`) | byte stores |

### 3.3 Why compiler-rt loses to glibc (expected, to be measured in P1d)

1. **memset is scalar.** One byte per store against glibc's one 64-byte
   store (1.8). For n ≥ 64 the gap is up to 64× in store count. This is
   the largest G3 opportunity, and the easiest.
2. **Half the vector width on Intel.** 32-byte vectors on c7i and c8i
   against glibc's 64-byte vectors (1.3-1.4), a consequence of
   `prefer_256_bit` in the LLVM CPU model. Whether 64-byte stores are
   faster than 32-byte stores on Sapphire Rapids for L1-resident data is
   a hardware question (H3 in section 6).
3. **No `rep movsb` on Intel.** glibc switches to `rep movsb` above
   16 KiB on c7i and c8i (1.5). `AGENTS.md` records that `rep movsb` is
   the floor for large aligned copies on x86 with ERMS/FSRM (0.15-era
   evidence, `docs/slop/results/zig-0.15-benchmark-hosts.md`).
4. **Source-aligned loop.** Stores are unaligned. With a misaligned
   destination, every 64-byte store (znver4) splits two cache lines.
   glibc aligns the destination (1.4).
5. **Small-size overhead.** A frame-pointer prologue on every call, 3
   byte copies for n < 4, four 4-byte copies for 8-15 (glibc: two 8-byte
   copies), and stack spills in memmove 16-63.
6. **memmove has no disjoint fast path and no 4K-aliasing test.**
7. **No NT stores.** Not visible in the standard suite (max 1 MiB), but
   visible above the 12-241 MiB NT thresholds.

compiler-rt has one advantage: it is a direct call to a hidden symbol.
glibc is an indirect PLT call to an ifunc target. fastmem keeps that
advantage and adds inlining.

## 4. Zig 0.16 expressibility: compiled experiments

All experiments ran on 2026-09-23 with the flake toolchain (`zig
version` → `0.16.0`). The base command is:

```
nix develop /Users/matt/code/fastmem-zig -c zig build-obj \
  -target x86_64-linux-gnu -mcpu=<cpu> -OReleaseFast [-fno-builtin] \
  [-fomit-frame-pointer] <file>.zig
nix develop /Users/matt/code/fastmem-zig -c llvm-objdump -d --no-show-raw-insn <file>.o
```

The sources were scratch files in `/tmp/p1b/exp/`. They are not in the
repository. Each subsection shows the part of the source that matters,
so that the experiment can be repeated.

### 4.1 exp:features: what the CPU models say

Source: `comptime { @compileLog(cpu.model.name, std.simd.suggestVectorLength(u8), cpu.has(.x86, .prefer_256_bit), cpu.has(.x86, .ermsb), cpu.has(.x86, .fsrm), cpu.has(.x86, .avx512bw), cpu.has(.x86, .avx512vl), cpu.has(.x86, .evex512), cpu.has(.x86, .avx2), cpu.has(.x86, .fast_gather)); }`

| `-mcpu` | `suggestVectorLength(u8)` | `prefer_256_bit` | `ermsb` | `fsrm` | `avx512bw` | `avx512vl` | `evex512` | `avx2` |
|---|---|---|---|---|---|---|---|---|
| sapphirerapids | 32 | true | true | true | true | true | true | true |
| graniterapids | 32 | true | true | true | true | true | true | true |
| znver4 | 64 | false | **false** | true | true | true | true | true |
| znver5 | 64 | false | **false** | true | true | true | true | true |
| x86_64_v3 | 32 | false | false | false | false | false | false | true |
| x86_64_v4 | 32 | true | false | false | true | true | true | true |

Consequences:

- The LLVM models do not match the guests. The Intel models claim FSRM.
  The c7i and c8i guests do not expose it (1.1). The znver4 and znver5
  models claim no ERMS. The c8a guest has it and c7a does not. **A
  comptime feature test cannot tell c7a from c8a**, and cannot see
  FSRM on c7i/c8i. fastmem must select x86 tuning by CPU model
  (`builtin.cpu.model == &std.Target.x86.cpu.znver5`, per `AGENTS.md`,
  "Zig notes"), not by the `ermsb` / `fsrm` feature bits.
- Code that uses `suggestVectorLength` gets 32-byte vectors on Intel.
  fastmem must pick its vector width explicitly.

### 4.2 exp:vec: `@Vector(64, u8)` loads and stores

Source (excerpt):

```zig
const V64 = @Vector(64, u8);
export fn copy64(dst: [*]u8, src: [*]const u8) void {
    const s: *align(1) const V64 = @ptrCast(src);
    const d: *align(1) V64 = @ptrCast(dst);
    d.* = s.*;
}
export fn storeAligned(dst: [*]align(64) u8, src: [*]const u8) void {
    const d: *V64 = @ptrCast(dst);
    d.* = @as(*align(1) const V64, @ptrCast(src)).*;
}
// also: headTail64 (two loads, then two stores), loop4 (4 x 64 B per
// iteration, dst align(64)), set64 (@splat of a u8), copy32 (@Vector(32, u8))
```

Result, `-fno-builtin`:

| `-mcpu` | `zmm` lines | `ymm` lines | `vzeroupper` |
|---|---|---|---|
| sapphirerapids | 50 | 2 (copy32 only) | 6 |
| graniterapids | 50 | 2 | 6 |
| znver4 | 82 | 2 | 6 |
| znver5 | 82 | 2 | 6 |
| x86_64_v3 | 0 | 101 | 6 |

- A load and a store **through a vector-typed pointer**
  (`*align(1) const V64`) give full `zmm` moves on Sapphire and Granite
  Rapids, although their models carry `prefer_256_bit`. Removing the
  feature (`-mcpu=sapphirerapids-prefer_256_bit`) gives the same 50
  `zmm` lines. **This depends on the source form.** The same vector
  loaded from or stored to an array (`s[0..64].*`, `d[0..64].* = v`) is
  split into two `ymm` halves on the Intel models (parent finding,
  confirmed in 4.8).
- `*align(1)` gives `vmovups (%rsi), %zmm0`. A `*V64` with 64-byte
  alignment gives `vmovaps %zmm0, (%rdi)` (storeAligned, offset 0x1fa).
  `@splat(c)` gives `vpbroadcastb %esi, %zmm0` (set64). headTail64 keeps
  the order: two loads, then two stores (0x214-0x228).
- LLVM unrolls loop4 by another 4×, to 1 KiB per iteration
  (0x70-0x17c), with a 256-byte remainder loop (0x1a0-0x1e8). Zig has no
  loop pragma to stop that. A loop written with a pointer bound, not a
  count, can behave differently (not tested).
- LLVM allocates `zmm0-zmm3`, not `zmm16-31`. Therefore every function
  that uses vectors ends with `vzeroupper`. glibc avoids it (1.1). The
  cost of one `vzeroupper` per call is a hardware question (H11).
- **Frame pointers.** Without `-fomit-frame-pointer`, every function has
  a `push rbp` / `mov rbp, rsp` / `pop rbp` frame (copy64 at 0x240-0x250).
  With `-fomit-frame-pointer`, copy64 is 2 moves, `vzeroupper`, `ret`
  (0x200-0x20f). The fastmem module must set `.omit_frame_pointer = true`
  (`zig-lib std/Build/Module.zig:256`). compiler-rt keeps the frame
  (3.2).

### 4.3 exp:mask: AVX-512BW masked loads and stores without inline asm

Zig has no masked-load builtin. The LLVM backend passes an `extern fn`
whose name starts with `llvm.` through as an LLVM intrinsic call. This
is not documented (no use in `zig-lib std/`, unverified as a supported
feature).

```zig
const M64 = @Vector(64, bool);
extern fn @"llvm.masked.load.v64i8.p0"(ptr: *const anyopaque, alignment: u32, mask: M64, passthru: V64) V64;
extern fn @"llvm.masked.store.v64i8.p0"(val: V64, ptr: *anyopaque, alignment: u32, mask: M64) void;

export fn maskedMoveLt64(dst: [*]u8, src: [*]const u8, n: usize) void {
    const bits: u64 = (@as(u64, 1) << @as(u6, @truncate(n))) - 1;
    const m: M64 = @bitCast(bits);
    const v = @"llvm.masked.load.v64i8.p0"(src, 1, m, @splat(0));
    @"llvm.masked.store.v64i8.p0"(v, dst, 1, m);
}
```

Result (sapphirerapids and znver4 are identical, offsets 0x60-0x83):
`movq $-1, %rax`, `shlxq %rdx, %rax, %rax`, `notq %rax`,
`kmovq %rax, %k1`, then `vmovdqu8 (%rsi), %zmm0 {%k1} {z}`,
`vmovdqu8 %zmm0, (%rdi) {%k1}`, `vzeroupper`, `retq`.

- The whole n < 64 memmove is one masked load and one masked store, with
  no branch. The load finishes before the store, so it is overlap-safe.
- A mask built with a vector compare against an index vector also works,
  but costs a broadcast and a compare with a constant-pool load
  (`vpbroadcastb`, `vpcmpnleub (%rip)`, mask1.o). The integer form is
  better.
- A masked memset: `@"llvm.masked.store.v64i8.p0"(@splat(c), dst, 1, m)`
  gives `shlx`/`not`/`kmovq`/`vpbroadcastb`/`vmovdqu8 … {%k1}`
  (maskedSetLt64, 0x30-0x53).
- **Guards required.**
  - With `-mcpu=x86_64_v3`, LLVM rejects the module ("Intrinsic has
    incorrect argument type!", "LLVM ERROR: Broken module found").
  - With `-ODebug`, the self-hosted backend emits a call to an undefined
    symbol. exp:backend: `comptime { @compileLog(builtin.zig_backend); }`
    prints `.stage2_x86_64` with `-ODebug` and `.stage2_llvm` with
    `-OReleaseFast` for `x86_64-linux-gnu`. The Debug object has
    `U llvm.masked.load.v64i8.p0` (`llvm-nm`), so the link fails.
  - The guard `builtin.zig_backend == .stage2_llvm and
    builtin.cpu.has(.x86, .avx512bw)` removes the reference at comptime.
    exp:sel shows the masked form on sapphirerapids and the two-`ymm`
    fallback on x86_64_v3, from the same source.
- The intrinsic signature has the `i32 alignment` argument of the LLVM
  version in Zig 0.16. A later LLVM can change the signature (unverified).
  This is a maintenance risk for each Zig upgrade (section 7).

### 4.4 exp:asm: `rep movsb`, `rep stosb`, NT stores, `sfence`, prefetch

Zig 0.16 inline asm cannot bind an output to `p.*` (error "expected ')',
found '.*'" for `"=m" (p.*)`). Outputs are variables or `-> T`. The
forms below compile:

```zig
export fn repMovsb(dst: [*]u8, src: [*]const u8, n: usize) void {
    var d = dst; var s = src; var c = n;
    asm volatile ("rep movsb"
        : [d] "={rdi}" (d), [s] "={rsi}" (s), [c] "={rcx}" (c),
        : [d_in] "{rdi}" (d), [s_in] "{rsi}" (s), [c_in] "{rcx}" (c),
        : .{ .memory = true });
}
// repStosb: same with rdi, rcx, and [v] "{al}" (v)
inline fn streamStore(p: *align(64) V64, v: V64) void {
    asm volatile ("vmovntdq %[v], (%[p])"
        :
        : [v] "v" (v), [p] "r" (p),
        : .{ .memory = true });
}
// sfence: asm volatile ("sfence" ::: .{ .memory = true });
// prefetch: @prefetch(p, .{ .rw = .read, .locality = 3, .cache = .data })
```

Results (sapphirerapids, `-fomit-frame-pointer`):

| Function | Code |
|---|---|
| repMovsb | `movq %rdx, %rcx`, `rep movsb`, `retq` (0x60-0x65) |
| repStosb | `movq %rdx, %rcx`, `movl %esi, %eax`, `rep stosb`, `retq` (0x50-0x57) |
| ntCopy loop | `prefetcht0`, `vmovups` load, `vmovntdq %zmm0, (%rdi)`, then `sfence` after the loop (0x20-0x3d) |
| `@prefetch` locality 3 / 0 / `.rw = .write` | `prefetcht0` / `prefetchnta` / `prefetchw` (0x0-0x7) |

- The `"v"` constraint accepts a 64-byte vector and allocates a `zmm`.
- No Zig builtin for non-temporal stores was found (no match for
  "nontemporal" in `zig-lib std/` outside the LLVM IR metadata enum in
  `std/zig/llvm/ir.zig`). Inline asm is the way.
- The `"memory"` clobber on the NT store is **required**, not a tuning
  choice. The asm writes memory through a register operand and has no
  memory output operand, so the clobber is the only thing that tells
  LLVM that memory changes (LLVM LangRef, "Clobber Constraints",
  https://llvm.org/docs/LangRef.html#clobber-constraints). Zig 0.16
  rejects a memory output bound to `p.*` (see above). The LangRef text:
  `~{memory}` "indicates that the assembly reads and writes to arbitrary
  undeclared memory locations – not only the memory pointed to by a
  declared indirect output". Without the clobber, LLVM is free to
  reorder or delete the loads and stores around the asm.
- exp:ind (`ind.zig`, sapphirerapids): Zig 0.16 binds an asm output to
  the storage of a variable, not to the memory that a pointer value
  points to.
  - `[p] "=*m" (dst)` with a parameter: error "asm cannot output to
    const 'p'".
  - `var p = dst;` then `[p] "=*m" (p)`: compiles, and `vmovntdq` writes
    64 bytes at `-0x8(%rsp)`, where the pointer variable lives
    (0x46-0x4b). The destination is never written, and the store
    overwrites the stack. **Wrong code, do not use.**
  - `"=m" (tmp)` with a local `V64`: the NT store goes to a stack slot
    and a normal store copies it out (0x15-0x23). Correct, but it is not
    a non-temporal store to the destination.

  So in Zig 0.16 the `"memory"` clobber is the only correct memory
  contract for an NT store to caller memory. A correct way to reduce
  the number of barriers is one asm block for a whole iteration
  (exp:nt4, next item).
- exp:nt4 (`nt4.zig`, sapphirerapids, `-fno-builtin`): a 4-VEC NT loop
  written two ways, both with a `"memory"` clobber.

  | Form | Loop body | After the loop |
  |---|---|---|
  | one `streamStore` asm per store, Zig loads (`ntPerStore`, 0x70-0xc6) | 4 `vmovups` loads, then 4 `vmovntdq`, with a `leaq` before 3 of the 4 stores: the `"r"` operand needs the address in a register, so the offset is not folded | `sfence`, `vzeroupper` |
  | one asm block per iteration with 4 loads and 4 `vmovntdq` in `zmm16-19` (`ntPerBlock`, 0x10-0x57) | 4 `vmovdqu64` loads, 4 `vmovntdq` with folded offsets, 3 pointer and counter updates | `sfence`, no `vzeroupper` |

  LLVM did not unroll either loop. The loads stay before the stores in
  both forms, because the source order puts them there.

### 4.5 exp:sel: comptime selection

```zig
const use_mask = builtin.zig_backend == .stage2_llvm and builtin.cpu.has(.x86, .avx512bw);
const tuning: Tuning = if (builtin.cpu.model == &std.Target.x86.cpu.sapphirerapids or
    builtin.cpu.model == &std.Target.x86.cpu.graniterapids) .{ .rep_movsb_min = 16 * 1024, … }
else if (builtin.cpu.model == &std.Target.x86.cpu.znver4 or
    builtin.cpu.model == &std.Target.x86.cpu.znver5) .{ .rep_movsb_min = maxInt(usize), … }
else .{ … generic … };
```

`@compileLog` output: sapphirerapids → `use_mask = true`, `"intel"`.
znver5 → `true`, `"amd"`. x86_64_v3 → `false`, `"generic"`. x86_64_v4 →
`true`, `"generic"`. The not-taken branch is not analyzed, so the
masked intrinsic never reaches LLVM on x86_64_v3 (4.3).

### 4.6 exp:idiom: does LLVM turn our loops into `memcpy` calls?

Relocations (`llvm-objdump -dr`) for sapphirerapids:

| Function | builtins on | `-fno-builtin` |
|---|---|---|
| byte loop, pointers can alias | loop | loop |
| byte loop, `noalias` pointers | `memcpy` call | loop |
| `@Vector(64, u8)` loop, `noalias` | `memcpy` call | loop |
| byte store loop (`dst[i] = c`) | `memset` call | loop |
| `@memcpy` with runtime length | `memcpy` call | **inline byte loop** (0x10-0x1d, one byte per iteration) |
| `@memcpy` of `[4096]u8` | `memcpy` call | **`rep movsb`** (0x95) |
| `@memcpy` of `[256]u8` | inline, 8 `ymm` loads + 8 stores | inline |

Across modules (exp:mod, `zig build-obj --dep fm -Mroot=main.zig
-fno-builtin -Mfm=fm.zig`: the root module has builtins on, the `fm`
module has them off):

- A non-inline `fm` function with a `noalias` vector loop stays a loop
  (`fm.loopCopyCall`, 0x10).
- The same loop in an `inline fn`, called from the root module, becomes
  a `memcpy` call (`viaInline`, relocation at 0x11a). **Inlining moves
  the code into the caller's LLVM function, and the caller's builtin
  setting applies.**
- Straight-line code (8 loads and 8 stores of `V64`, the 257-512 class)
  in an `inline fn` stays 16 `zmm` moves in the root module, no call
  (`straight`, both CPUs).

Comptime-size `@memcpy` in a module with builtins on (exp:mod2):

| Size | sapphirerapids | znver4 |
|---|---|---|
| 128 (memset) | inline | inline |
| 256 | inline, 8 × `ymm` pairs (exp:idiom) | not compiled (512 is inline, so 256 is expected inline) |
| 257 | `memcpy` call | inline |
| 512 | `memcpy` call | inline, 8 `zmm` pairs (0x100-0x171) |
| 1024 | `memcpy` call | `memcpy` call |
| 1024 (memset) | `memset` call | inline |

Rules for fastmem that follow:

1. The kernel module needs `no_builtin = true` (already in the plan).
2. The inline layer (`fastmem_inline`, G4) must contain **no loops**.
   A loop in an inlined function becomes a `memcpy`/`memset` call in the
   caller. Loops live only in non-inline functions of the kernel module.
3. With `-fno-builtin`, the kernel module must not use `@memcpy` /
   `@memset` for runtime lengths. For comptime lengths they are allowed, but LLVM
   can emit `rep movsb` for them (the 4096 case). Use explicit vector
   loads and stores.
4. The Intel inline threshold for `@memcpy` is 256 bytes. For G4
   ("comptime sizes up to 256 generate no call and are not slower than
   `@memcpy`"), fastmem can emit `zmm` straight-line code where LLVM
   emits `ymm` code.

### 4.7 exp:fold: constant sizes through an inline size-class ladder

`fm3.zig` has an `inline fn move(dst: []u8, src: []const u8)` with the
classes n < 64 (masked), 64-128 (2 VEC), 129-256 (4 VEC), and a call to
a non-inline kernel above 256. `main3.zig` calls it from a module with
builtins on (sapphirerapids):

| Caller | Code |
|---|---|
| `*[100]u8` | 2 `zmm` loads, 2 stores, at offsets 0 and 0x24 (0x1a0-0x1c3) |
| `*[200]u8` | 4 `zmm` loads, 4 stores (0x130-0x175) |
| `*[7]u8` | `movl $0x7f, %eax`, `kmovq`, masked load and store (0x180-0x199) |
| runtime n | the ladder: 3 compares, and a tail jump to the kernel above 256 (0x0-0x99) |

- LLVM folds the ladder when the length is a constant. The inline layer
  needs no separate comptime-size code path for G4 in the 64-256 range.
- For n < 64, a masked constant copy costs a `kmovq` and a `vzeroupper`.
  `@memcpy` of 7 bytes needs two overlapping 4-byte moves (llvm-libc
  does the same, 2.2). So for small comptime sizes, the ladder is better
  than the mask. The inline layer needs to know if n is comptime-known.

exp:ct: an `inline fn probe(n: usize)` can test that with
`@typeInfo(@TypeOf(.{n})).@"struct".fields[0].is_comptime`. `probe(7)`
compiles to `movb $1, %al`, and `probe(runtime_n)` to `movb $2, %al`. A
slice made from a `*const [9]u8` gives 2: the length of a slice is not
comptime-known in Sema, although LLVM later sees a constant. This trick
is not documented (unverified as stable). A type-based test
(`@typeInfo(@TypeOf(dst)) == .pointer` with `.size == .one` and an array
child) is the documented alternative.

### 4.8 exp:form: the source form decides `ymm` or `zmm` on Intel

Parent finding (P1b follow-up): the form below compiles to two `ymm`
moves and `vzeroupper` on skylake_avx512, sapphirerapids and
graniterapids, and to one `zmm` load and store on znver4 and znver5.

```zig
const v: @Vector(64, u8) = s[0..64].*;
d[0..64].* = v;
```

This memo confirms it, and shows that the pointer form of 4.2 is not
affected.

Source (`form.zig`, built with `-OReleaseFast -fno-builtin
-fomit-frame-pointer`):

```zig
export fn formPtrCast(d: [*]u8, s: [*]const u8) void {      // 4.2 form
    const v: V64 = @as(*align(1) const V64, @ptrCast(s)).*;
    @as(*align(1) V64, @ptrCast(d)).* = v;
}
export fn formArray(d: [*]u8, s: [*]const u8) void {        // parent form
    const v: V64 = s[0..64].*;
    d[0..64].* = v;
}
// formMixedLoadArray: array load, vector-pointer store
// formMixedStoreArray: vector-pointer load, array store
```

`zmm` / `ymm` lines per function:

| `-mcpu` | formPtrCast | formArray | array load, vector store | vector load, array store |
|---|---|---|---|---|
| skylake_avx512 | 2 / 0 | 0 / 4 | 2 / 0 | 2 / 1 |
| sapphirerapids | 2 / 0 | **0 / 4** | 2 / 0 | 2 / 1 |
| graniterapids | 2 / 0 | **0 / 4** | 2 / 0 | 2 / 1 |
| znver4 | 2 / 0 | 2 / 0 | 2 / 0 | 2 / 0 |
| znver5 | 2 / 0 | 2 / 0 | 2 / 0 | 2 / 0 |
| sapphirerapids-prefer_256_bit | 2 / 0 | 2 / 0 | 2 / 0 | 2 / 0 |
| graniterapids-prefer_256_bit | 2 / 0 | 2 / 0 | 2 / 0 | 2 / 0 |
| sapphirerapids+evex512 | 2 / 0 | 0 / 4 | 2 / 0 | 2 / 1 |

- On sapphirerapids, formArray is two `vmovups` `ymm` loads, two `ymm`
  stores, and `vzeroupper` (0x30-0x45). "Vector load, array store" is
  worse: a `zmm` load, a `ymm` store, and a `vextractf64x4` store of the
  upper half (0x0-0x12).
- `+evex512` changes nothing. The Intel models have it already
  (`"target-features"` in the IR contains `+evex512` and
  `+prefer-256-bit`).
- **Mechanism** (`-femit-llvm-ir`): for formPtrCast the IR has
  `load <64 x i8>` and `store <64 x i8>`. For formArray the IR already
  has two `load <32 x i8>` and two `store <32 x i8>`, with SROA-named
  values (`%.sroa.33.0..sroa_idx`). The split happens in the LLVM IR
  passes (SROA rewrites the `[64 x i8]` aggregate with the preferred
  256-bit width), not in the backend. The backend keeps a `<64 x i8>`
  load or store in one `zmm`. The IR functions carry no
  `min-legal-vector-width` attribute. The LLVM rule that this absence
  makes 512-bit types legal under `prefer-256-bit` was not read in the
  LLVM source (unverified), but it matches every result above.
- The array form and `@memcpy` of a comptime size are the same case:
  `@memcpy` of `[256]u8` also gives `ymm` on sapphirerapids (exp:idiom).
- An `inline fn` that uses the pointer form keeps `zmm` when it is
  inlined into a sapphirerapids caller (exp:mod2, `straight`: 16 `zmm`
  lines, no `ymm`).

### 4.9 exp:mcpu: per-module CPU features, and no per-function features

- `-mcpu` is a per-module option (`zig build-obj --help`, "Per-Module
  Compile Options"). `std.Build.Module` has its own `resolved_target`
  (`zig-lib std/Build/Module.zig:9`, `:279`).
- Zig 0.16 has no per-function target-feature builtin. The 125 builtins
  in `zig-lib std/zig/BuiltinFn.zig` contain nothing that sets CPU
  features. `std.builtin.CallingConvention` x86 options have only
  `incoming_stack_alignment` and similar (`zig-lib std/builtin.zig:348`
  and following).
- Experiment (`fm4.zig` and `main4.zig`): the root module is built with
  `-target x86_64-linux-gnu -mcpu=sapphirerapids`, the `fm` module with
  `-target x86_64-linux-gnu -mcpu=sapphirerapids-prefer_256_bit
  -fno-builtin`. Both functions use the array form.

  | Function | Code |
  |---|---|
  | non-inline `fm.kernelArray`, called from root | one `zmm` load and store (0x30-0x3f) |
  | `inline fn fm.inlineArray`, inlined in root | two `ymm` loads and stores (0x0-0x15) |

  `@compileLog` shows `builtin.cpu.has(.x86, .prefer_256_bit)` = true in
  root and false in `fm`. `builtin.cpu.model` stays sapphirerapids, so
  the model-keyed tuning of 5.4 still works.
- A module-level CPU override therefore works for the out-of-line
  kernel. It does not reach inlined code, which takes the features of
  the caller's LLVM function.
- The `-target` must be repeated for each module. Without it, the
  per-module `-mcpu` resolves against the host architecture (aarch64 on
  the dev box: "available CPUs for architecture 'aarch64'").

### 4.10 exp:high: `zmm16-31` / `ymm16-31` in inline asm, and `vzeroupper`

Source (`hi2.zig`). The 64-byte head/tail variants in `hi.zig` are the
compiled form of llvm-libc `head_tail` (`op_generic.h:237-246`) with
the registers named. They were built the same way.

```zig
export fn copy64High(d: [*]u8, s: [*]const u8) void {
    asm volatile (
        \\vmovdqu64 (%[s]), %%zmm16
        \\vmovdqu64 %%zmm16, (%[d])
        :
        : [s] "r" (s), [d] "r" (d),
        : .{ .zmm16 = true, .memory = true });
}
// variants: zmm16/zmm17 head/tail; ymm16/ymm17 head/tail; the same with
// zmm0 in asm; and each variant followed by a call to an extern function
```

The clobber names exist in `zig-lib std/builtin/assembly.zig:101`
(`zmm16: bool = false`, and the rest of the bank).

| Function | `vzeroupper` |
|---|---|
| `copy64High` above (`hi2.o`, 0x20-0x2c), and followed by a call (0x0-0xc) | **none** |
| head/tail with `zmm16/17` in asm, then `ret` (`hi.o` from here on, 0x80-0x9c) | **none** |
| head/tail with `ymm16/17` in asm (0xb0-0xcc) | **none** |
| head/tail with `zmm16/17` in asm, then a tail call to `other` (0x50-0x6c) | **none** before the jump |
| one move through `zmm0` in asm (0xa0-0xaf) | yes, before `ret` |
| the same head/tail as plain Zig vectors (LLVM picks `zmm0/1`, 0x30-0x4f) | yes |
| plain Zig vectors, then a tail call (0x0-0x1f) | yes, before the jump |

- LLVM's `vzeroupper` insertion reads inline asm operands and clobbers.
  An asm block that touches only registers 16-31 does not mark the upper
  state dirty, so LLVM adds no `vzeroupper`. That is the glibc property
  of 1.1, reproduced from Zig.
- The cost: the asm fixes the registers, LLVM cannot schedule across
  the block, and every class becomes hand-written asm. The benefit is
  one `vzeroupper` less per call. H11 decides whether that is worth it.
- There is no way to ask LLVM to allocate plain Zig vectors in
  `zmm16-31`. The allocator picks `zmm0` upward (every exp:vec function).

### 4.11 exp:di: `@disableIntrinsics()`

`zig-lib std/zig/BuiltinFn.zig:266-271` lists `@disableIntrinsics`, zero
parameters, legal only inside a function (Zir tag `disable_intrinsics`,
`std/zig/Zir.zig:2044`). Experiment (`di.zig`, sapphirerapids, module
with builtins **on**):

| Function | IR attributes | Code |
|---|---|---|
| `noalias` vector loop with `@disableIntrinsics()` | `"no-builtins"` | loop, no `memcpy` call |
| byte store loop with `@disableIntrinsics()` | `"no-builtins"` (attributes #2) | loop, no `memset` call |
| caller of an `inline fn` that calls `@disableIntrinsics()` | **the caller** gets `"no-builtins"` (attributes #3) | loop, no call |
| `@memcpy` with runtime length after `@disableIntrinsics()` | `llvm.memcpy.inline` in the IR | **byte loop** (0x0-0x1f) |

- `@disableIntrinsics()` is a per-function `no_builtin`. It is the
  robust way to protect a kernel function: it works even if a consumer
  compiles the fastmem sources into a module with builtins on.
- In an `inline fn`, it applies to the whole caller. Every other
  runtime-length `@memcpy` in that caller then becomes a byte loop. The
  inline layer must never call it.

### 4.12 exp:g4: the fixed-size G4 gate, codegen part (sizes 1-256)

G4 requires that `fastmem.copy` with a comptime-known size up to 256
"generates no call and is not slower than `@memcpy` with the same
comptime size" (`docs/slop/fastmem-plan.md`, G4). This experiment checks the
first half and a static proxy for the second half, for every size
1-256, on all four `-mcpu` values. The timing half is gate G4F in
section 6. It needs hardware and the harness.

The prototype is a scratch file, not repository code. `fm.zig` is built
as a module with `-fno-builtin` (the kernel module). `main.zig` is the
consumer module with builtins on. For each n, `main.zig` exports three
C-ABI functions:

| Symbol | Public argument form | Body |
|---|---|---|
| `fixed_<n>` | pointer to array, `*[n]u8` | `fm.copyFixed(n, dst, src)`: what the facade calls for a `*[N]u8` argument (7.1, item 3) |
| `slice_<n>` | slice with a constant length, `dst[0..n]` | `fm.copySlice(dst[0..n], src[0..n])`: the runtime class ladder of 5.2 up to 256, left to LLVM constant folding (exp:fold) |
| `builtin_<n>` | pointer to array | `@memcpy(dst, src)`: the reference |

`copyFixed` (excerpt. `ld`/`st` are `*align(1)` vector or integer loads
and stores, `pair(T, …)` loads a T at 0 and at n − size(T), then stores
both):

```zig
pub inline fn copyFixed(comptime n: usize, dst: *[n]u8, src: *const [n]u8) void {
    const d: [*]u8 = dst;
    const s: [*]const u8 = src;
    switch (n) {
        0 => {},
        1 => st(u8, d, ld(u8, s)),
        2 => st(u16, d, ld(u16, s)),
        3 => { const a = ld(u16, s); const b = ld(u8, s + 2); st(u16, d, a); st(u8, d + 2, b); },
        4 => st(u32, d, ld(u32, s)),
        5...7 => pair(u32, d, s, n),
        8 => st(u64, d, ld(u64, s)),
        9...15 => pair(u64, d, s, n),
        16 => st(V16, d, ld(V16, s)),
        17...31 => pair(V16, d, s, n),
        32 => st(V32, d, ld(V32, s)),
        33...63 => pair(V32, d, s, n),
        64 => st(V64, d, ld(V64, s)),
        else => { // 65..256: full 64-byte blocks, then one overlapping 64-byte tail, loads first
            const full = n / 64;
            const has_tail = n % 64 != 0;
            var v: [full + @intFromBool(has_tail)]V64 = undefined;
            inline for (0..full) |i| v[i] = ld(V64, s + i * 64);
            if (has_tail) v[full] = ld(V64, s + n - 64);
            inline for (0..full) |i| st(V64, d + i * 64, v[i]);
            if (has_tail) st(V64, d + n - 64, v[full]);
        },
    }
}
```

The exports come from one `comptime` loop:
`for (1..257) |n| @export(&Case(n).fixed, .{ .name = std.fmt.comptimePrint("fixed_{d}", .{n}) });`
and the same for `slice` and `builtin` (`@setEvalBranchQuota(10_000_000)`
is needed for the 768 names).

Commands, for each `<cpu>` in sapphirerapids, graniterapids, znver4,
znver5:

```
A="-OReleaseFast -fomit-frame-pointer -target x86_64-linux-gnu"
zig build-obj $A -mcpu=<cpu> --dep fm -Mroot=main.zig $A -mcpu=<cpu> -fno-builtin -Mfm=fm.zig -femit-bin=g4_<cpu>.o
llvm-objdump -dr --no-show-raw-insn g4_<cpu>.o
llvm-nm --defined-only g4_<cpu>.o
```

A Python script maps each exported name to its address (LLVM merges
identical bodies, so several names can share one address) and counts,
per function: body instructions (without `ret`, padding, `int3`),
memory operands, `memcpy`/`memmove` relocations, `vzeroupper`, and the
widest register.

Results. Each cell is "memory operations / widest register", and
"+vzu" marks a `vzeroupper`. A count such as "6-8" is the minimum and
the maximum over the sizes of the row. SPR and GNR gave identical
statistics for all 768 functions, and so did Zen 4 and Zen 5.

| n | SPR/GNR `fixed` | SPR/GNR `slice` | SPR/GNR `@memcpy` | Zen 4/5 `fixed` | Zen 4/5 `slice` | Zen 4/5 `@memcpy` |
|---|---|---|---|---|---|---|
| 1, 2, 4, 8 | 2 / gpr | 2 / gpr | 2 / gpr | 2 / gpr | 2 / gpr | 2 / gpr |
| 3, 5-7, 9-15 | 4 / gpr | 4 / gpr | 4 / gpr | 4 / gpr | 4 / gpr | 4 / gpr |
| 16 | 2 / xmm | 2 / xmm | 2 / xmm | 2 / xmm | 2 / xmm | 2 / xmm |
| 17-31 | 4 / xmm | 4 / xmm | 4 / xmm | 4 / xmm | 4 / xmm | 4 / xmm |
| 32 | 2 / ymm +vzu | 2 / ymm +vzu | 2 / ymm +vzu | 2 / ymm +vzu | 2 / ymm +vzu | 2 / ymm +vzu |
| 33-63 | 4 / ymm +vzu | 4 / ymm +vzu | 4 / ymm +vzu | 4 / ymm +vzu | 4 / ymm +vzu | 4 / ymm +vzu |
| 64 | 2 / zmm +vzu | 2 / zmm +vzu | **4 / ymm** +vzu | 2 / zmm +vzu | 2 / zmm +vzu | 2 / zmm +vzu |
| 65-127 | 4 / zmm +vzu | 4 / zmm +vzu | **6-8 / ymm** +vzu | 4 / zmm +vzu | 4 / zmm +vzu | 4 / zmm +vzu |
| 128 | 4 / zmm +vzu | 4 / zmm +vzu | **8 / ymm** +vzu | 4 / zmm +vzu | 4 / zmm +vzu | 4 / zmm +vzu |
| 129-192 | 6 / zmm +vzu | 6 / zmm +vzu | **10-12 / ymm** +vzu | 6 / zmm +vzu | 6 / zmm +vzu | 6 / zmm +vzu |
| 193-256 | 8 / zmm +vzu | 8 / zmm +vzu | **14-16 / ymm** +vzu | 8 / zmm +vzu | 8 / zmm +vzu | 8 / zmm +vzu |

- **No call** in any of the 3 × 256 functions on any of the 4 CPUs.
- `fixed` and `slice` never have more instructions or more memory
  operations than `@memcpy`, for every n in 1-256 on every CPU. The
  functions have no non-memory instructions other than `vzeroupper`.
  Totals over n = 1-256: 1619 instructions for `fixed` and `slice` on all
  four CPUs. `@memcpy` has 2581 on SPR/GNR and 1619 on Zen 4/5.
- On Zen 4/5 the counts equal `@memcpy` for every n: LLVM already uses
  `zmm` there. The G4 timing gate on AMD tests only that the inline path
  adds no hidden cost.
- On SPR/GNR, `@memcpy` of 64-256 bytes uses `ymm` (the split of 4.8),
  and fastmem uses half as many `zmm` operations. Fewer instructions do
  not prove "not slower": whether a 64-byte `zmm` move is at least as
  fast as two `ymm` moves on these cores is H3 and G4F.
- LLVM removes dead overlapping stores in the constant `slice` form. For
  n = 150 it keeps 3 `zmm` loads and stores at 0, 0x16 and 0x56 instead
  of the 4 that the ladder writes (`slice_150`, SPR), because the store
  at 64 is fully overwritten by later stores.
- **A regression that the gate caught.** The first version of the
  `slice` ladder copied the 2-3 class as a `u16` plus the last byte, as
  glibc does (1.3). With a constant n = 2 that is 2 loads and 2 stores,
  where `@memcpy` has one `u16` move. An overlapping `u16` pair folds to
  one move for n = 2. 5.2 now uses the `u16` pair.
- `vzeroupper` appears exactly where `@memcpy` also has it (n ≥ 32).

## 5. Proposed fastmem x86_64 design

### 5.1 Decisions

1. **One move kernel, memcpy is an alias.** glibc exports one body for
   both names (1.3), and every class up to 512 is overlap-safe by
   construction. The only cost of memmove semantics above 512 is one
   subtract and one compare. fastmem exports `fastmem_move` and makes
   `fastmem_copy` the same function. The inline layer gets a comptime
   `Overlap = enum { may_overlap, disjoint }` parameter that removes the
   direction test for `copy`. It does not remove the 4K-aliasing test,
   which also helps disjoint copies.
2. **Copy glibc's size classes and thresholds on the four hosts, then
   beat it with inlining.** G2 asks for parity per size tier. The lowest
   risk path to parity is the same class edges, the same vector width,
   the same loop shape, and the same `rep movsb` windows. The P3
   hypotheses (section 6) then try to improve on each one.
3. **Tuning by CPU model, not by feature bits.** exp:features shows that
   the LLVM models lie about ERMS (AMD) and FSRM (Intel). The tuning
   table keys on `builtin.cpu.model`. Feature bits select only the ISA
   level (AVX-512BW, AVX2).
4. **Explicit vector width, vector-typed memory operations.**
   `@Vector(64, u8)` on the AVX-512 targets, `@Vector(32, u8)` on
   x86_64_v3. Never `suggestVectorLength` (it says 32 on Intel, 4.1).
   Every load and store goes through a `*align(1) V` or `*align(64) V`
   pointer, never through an array (`p[0..64].*`), `@memcpy`, or a
   struct, because those forms are split to `ymm` on Intel (4.8). 5.8
   gives the full rule.
5. **Loops only in non-inline functions of the kernel module.** The
   kernel module has `no_builtin = true` and `omit_frame_pointer = true`.
   The inline layer is straight-line code (4.6).
6. **Inline asm only for `rep movsb`, `rep stosb`, `vmovntdq`, `sfence`,**
   and, behind the `high_regs` flag, the small classes (5.8). Masked
   loads and stores use the `llvm.masked.*` externs behind the guard of
   4.3. Everything else is plain Zig vector code.
7. **`@disableIntrinsics()` in every non-inline kernel function**, in
   addition to the module-level `no_builtin` (4.11). Never in an
   `inline fn`.

### 5.2 memmove / memcpy size classes (AVX-512 targets)

VEC = 64 bytes. "Load all, then store all" in every class up to 512.

| n | Class | Method |
|---|---|---|
| 0-63 | `small` | Ladder, as glibc (1.3): 32-63 two `V32`, 16-31 two `V16`, 8-15 two `u64`, 4-7 two `u32`, 2-3 two overlapping `u16` (glibc uses a byte and a `u16`. The `u16` pair lets LLVM fold a constant n = 2 to one move, 4.12), 1 `u8`. Option `small_masked` (default **off**, H5): one masked load and store. |
| 64-128 | `vec2` | first VEC + last VEC |
| 129-256 | `vec4` | 2 VEC from the start + 2 from the end |
| 257-512 | `vec8` | 4 + 4 |
| > 512 | `large` | non-inline, see below |

`large` (non-inline, one function per direction):

1. d = dst − src (wrapping). If d = 0: return. If d < n: backward loop.
2. Intel only: if `rep_movsb_min < n < nt_min`, `rep movsb`, with the
   destination aligned to 64 unless bits 9-11 of d are all zero, then
   with the source aligned (1.5). The head VEC, loaded first, is stored
   after `rep movsb` (1.3, store-order table).
3. If n ≥ `nt_min` and the source does not start inside (dst, dst + n):
   the NT loop.
4. If the source does not start inside (dst, dst + n) and
   `d & 0xF00 == 0`: the backward loop (4K aliasing, 1.4).
5. Else the forward loop.

Forward loop: save the head VEC and the last 4 VEC. Align dst up to
64 (strict). Do 4 unaligned loads and 4 aligned stores per iteration
(`*align(64) V64`, which gives `vmovaps`, exp:vec). Store the 4 tail VEC
and the head VEC. Backward loop: the mirror (1.4).

NT loop: store the head VEC unaligned and align dst to 64. Per
iteration: 4 loads, 4 `vmovntdq` (inline asm, 4.4), and `prefetcht0` of
the source 256-512 bytes ahead (`@prefetch`). Then `sfence`, the
remainder through the forward loop body, and the last 256 bytes from
the end. Start with a single page stream.
The 2-page and 4-page interleave of 1.6 is a P3 experiment (H13),
because the standard suite (≤ 1 MiB) never reaches the NT thresholds.

### 5.3 memset size classes (AVX-512 targets)

| n | Method |
|---|---|
| 0-63 | if `(dst & 0xFFF) <= 0xFC0`, one masked store (`small_masked_set`, default **on**, glibc 1.8). Else the ladder |
| 64-128 | 2 VEC |
| 129-256 | 4 VEC |
| 257-512 | 8 VEC |
| > 512 | 4 unaligned head VEC at dst. Then, with a = dst rounded down to 64, an aligned loop of 4 VEC whose **first store is at a + 256** (never below dst), while a < dst + n − 512. Then 4 unaligned tail VEC at dst + n − 256 (1.8) |
| Intel, `rep_stosb_min < n < memset_nt_min` | `rep stosb` (no alignment, no fix-up, 1.8) |
| Intel, n ≥ `memset_nt_min` | NT loop: 4 `vmovntdq` per iteration, `sfence`, 4 unaligned tail VEC |
| AMD | no `rep stosb`, no NT (1.8) |

The broadcast is `@splat(c)` (one `vpbroadcastb`, exp:vec).

### 5.4 Tuning constants

Values in bytes. "none" means the path is compiled out.

| Constant | sapphirerapids (c7i) | graniterapids (c8i) | znver4 (c7a) | znver5 (c8a) | other AVX-512BW | x86_64_v3 |
|---|---|---|---|---|---|---|
| `vec` | 64 | 64 | 64 | 64 | 64 | 32 |
| `rep_movsb_min` (exclusive) | 16384 | 16384 | none | none | none | none |
| `nt_min` (move, inclusive) | 0x3580000 | 0xF100000 | 0xC00001 | 0xC00001 | none | none |
| `rep_stosb_min` (exclusive) | 2048 | 2048 | none | none | none | none |
| `memset_nt_min` (inclusive) | 0x3580000 | 0xF100000 | none | none | none | none |
| `small_masked` (move kernel) | false | false | false | false | false | n/a |
| `small_masked_inline` (move, runtime n) | false | false | false | false | false | n/a |
| `small_masked_set` | true | true | true | true | true | n/a |
| `alias_mask` (1.4) | 0xF00 | 0xF00 | 0xF00 | 0xF00 | 0xF00 | 0xF00 |
| `rep_src_align_mask` (1.5) | 0xE00 | 0xE00 | n/a | n/a | n/a | n/a |
| `inline_max` (5.6) | 256 | 256 | 256 | 256 | 256 | 128 |
| `high_regs` (5.8, asm with `zmm16-31` below 256 B) | false | false | false | false | false | n/a |

Justification:

- `vec`, the class edges, and the loop shape: the glibc variant on the
  host (1.1, 1.3). The Intel models' `prefer_256_bit` does not stop
  64-byte moves (exp:vec).
- `rep_movsb_min`, `rep_stosb_min`, `nt_min`, `memset_nt_min`: the
  measured glibc values on each host (1.2), with glibc's comparison
  direction. `rep_movsb_min` and `rep_stosb_min` are exclusive
  (`so:0x196487`, `so:0x196c47`, "above"). `nt_min` is inclusive:
  Intel reaches NT at n = T_nt through the `rep movsb` block, AMD only at
  n = T_nt + 1 (1.7, "Boundaries"). `memset_nt_min` is inclusive
  (`so:0x196ccc`, "above or equal"). They depend on the L3 size
  that the guest reports. A comptime constant is right for these four
  instance families. Other hosts that build with the same `-mcpu` get
  the same constants. That is a documented limitation, not a bug.
- AMD: no `rep movsb` and no `rep stosb`, with the glibc reason (BZ
  #30994, 1.2) and the fact that c7a and c8a behave the same in glibc
  (1.9). H9 tests whether that is right on Turin.
- "other AVX-512BW" (for example `x86_64_v4` or `native` on an unknown
  CPU): the vector classes only. No string instructions and no NT,
  because we have no measurement.
- Every constant is also a build option (`-Dx86-rep-movsb-min=…` etc.)
  so that P3 can sweep a threshold without a code change. The default
  comes from the table.

### 5.5 Code structure

```
src/
  root.zig               public facade: copy, move, set; exportSymbols()
  x86_64/
    tuning.zig           Tuning struct, the table in 5.4, build-option overrides
    ops.zig              V16/V32/V64 load/store (align(1) and align(64)),
                         splat, masked load/store (guarded), NT store,
                         rep movsb, rep stosb, sfence (inline asm)
    move.zig             moveSmall (inline, classes ≤ 512),
                         moveLarge (noinline: forward, backward, rep, NT),
                         fastmem_move (callconv(.c) kernel)
    set.zig              setSmall (inline), setLarge (noinline), fastmem_set
  aarch64/ …             P1c lane
```

- `ops.zig` holds every inline asm block and every `llvm.masked.*`
  extern. No other file uses asm. Each helper has a comptime guard and a
  plain-Zig fallback (for the self-hosted Debug backend).
- `moveSmall(comptime overlap, comptime max, dst, src, n)` is `inline`.
  `max` bounds the classes that it emits: the kernel uses 512, the
  inline layer uses `inline_max`. Above `max` it calls `moveLarge` (or,
  in the inline layer, the kernel).
- The kernel functions are `callconv(.c)` so that the same body serves
  `fastmem_abi` (G2), `asm_probe.zig`, and `exportSymbols()` (G5).
- `moveLarge` and `setLarge` are separate `noinline` functions. The
  kernel entry stays small. That matches the glibc layout, where the
  classes up to 512 are within the first 0x190 bytes of the function
  (`so:0x196380-0x19650f`).
- Tests (G1) sit next to the code. They must cover each class edge
  (63/64, 128/129, 256/257, 512/513), the aliasing test (d mod 4096 in
  {0, 255, 256}), the `rep movsb` edges (16384/16385), and the
  source-aligned `rep movsb` case (d mod 4096 < 512).

### 5.6 The inline small-size path (`fastmem_inline`, G4)

- `fastmem.copy` / `move` / `set` are `inline fn`. They call
  `moveSmall(…, inline_max, …)` and fall through to the C-ABI kernel.
  No loop is inlined (4.6).
- **Comptime-known size.** LLVM folds the ladder to one class
  (exp:fold). exp:g4 (4.12) checks every size 1-256 on all four CPUs:
  no call, and never more instructions or memory operations than
  `@memcpy` of the same size, in both the pointer-to-array and the
  constant-length slice forms. G4F times it. For n < 64 the facade must use the ladder, not the mask,
  when n is comptime-known, because a constant mask costs a `kmovq` and
  a `vzeroupper` (exp:fold, `*[7]u8`). Detect a comptime-known size
  from the argument type (a pointer to an array) or with the tuple
  test of exp:ct. For comptime sizes above `inline_max` up to some
  bound (for example 1024), emit straight-line VEC code. LLVM itself
  calls `memcpy` above 256 on Intel (exp:mod2), so this is where fastmem
  can beat `@memcpy` in G4.
- **Runtime size.** Classes up to `inline_max` = 256 inline, the rest a
  call. That is 3 compares and at most 8 vector moves in the caller
  (exp:fold, runtime path 0x0-0x99). n < 64 uses the masked form when
  `small_masked_inline` is set. H5 decides. It is a strong candidate
  for `dist/small`, where the ladder mispredicts.
- `inline_max` = 128 on x86_64_v3: its classes use 32-byte vectors, so
  a 256-byte class needs 8 `ymm` loads and 8 stores.
- `vzeroupper`: LLVM adds one before each return or call after `zmm`
  use in the caller. H11 measures the cost.

### 5.7 The baseline x86_64_v3 path (G6)

G6 only asks for "not slower than compiler-rt". The model has AVX2 and
no ERMS bit (4.1).

- Classes: ladder below 32 (`V16`, `u64`, `u32`, `u16`, `u8`), 32-64 two
  `V32`, 65-128 4 `V32`, 129-256 8 `V32`, loop above 256 of 4 × 32 B
  with dst aligned to 32. That is glibc's `avx_unaligned` shape (1.10).
- No masking, no `rep movsb`, no `rep stosb`, no NT. Unknown CPU,
  unknown thresholds.
- memset: the same classes with `@splat`. This alone beats compiler-rt,
  whose memset is a byte loop (3.2).
- Where it is expected to beat compiler-rt (hypotheses, not
  measurements: H1 for memset, H12 for the whole v3 build): memset on
  every size (compiler-rt stores bytes, 3.2), memmove 16-63 (no stack
  spills, 3.2), and the destination-aligned loop (3.3, point 4). Where it
  can lose: the 8× unrolled 32-byte compiler-rt loop is 256 B/iteration,
  the same as our 4 × 32 B plus LLVM's own unroll (exp:vec). H12
  measures the loop on v3 against compiler-rt.

### 5.8 `zmm` on Intel without a program-wide `-mcpu` change

The problem (4.8): with the Intel models, LLVM splits a 64-byte vector
into `ymm` halves whenever the data goes through an array, a struct, or
`@memcpy`. glibc uses `zmm` on c7i and c8i (1.1). fastmem must get
`zmm` there, or prove on hardware that `ymm` is as fast (H3, H15), and
it must not ask the user to change `-mcpu` for the whole program.

Options, with the evidence:

| Option | Kernel | Inline layer | `vzeroupper` | Cost |
|---|---|---|---|---|
| A. Vector-typed pointers only (`*align(1) const V64`) | `zmm` (4.2, 4.8) | `zmm` (exp:mod2 `straight`) | yes, LLVM uses `zmm0-15` | a source rule and a codegen test |
| B. Per-module CPU for the kernel module: the user's CPU minus `prefer_256_bit` | `zmm`, also for array forms (4.9) | no effect: inlined code takes the caller's features (4.9) | yes | a second target query in `build.zig`, exe link not tested |
| C. Inline asm with `zmm16-31` | `zmm` | `zmm` | **none** (4.10) | every class hand-written, and LLVM cannot schedule across the asm |
| D. Per-function target features | - | - | - | **not available** in Zig 0.16 (4.9) |

Decision:

1. **Use A everywhere.** It is plain Zig, it works in the kernel and in
   inlined code, and it needs no build change. The rule is in 5.1,
   item 4: all loads and stores go through vector pointers.
2. **Enforce A with a codegen test.** A new build step disassembles
   `fastmem_move`, `fastmem_set` and an inline-layer probe for
   sapphirerapids and graniterapids, and fails if a class of 64 bytes or
   more contains a `ymm` move (a split) or no `zmm` move. The existing
   `asm-all` step does **not** cover this: it builds five
   arch-OS-ABI triples with no CPU model (`build.zig:85-99`), so every
   x86 object is for the baseline CPU. The gate needs explicit
   `-Dcpu`-style probes for sapphirerapids, graniterapids, znver4 and
   znver5. The G4 gate of 4.12 uses the same probes.
3. **Do not use B by default.** It adds a second target to `build.zig`
   and protects only the kernel. Keep it as the fallback if the codegen
   test finds a split that source changes cannot remove.
4. **Keep C behind a tuning flag** (`high_regs`, default off). Turn it
   on for the classes below 256 bytes only if H11 shows that the
   `vzeroupper` costs a significant amount against glibc. The loops stay
   in Zig with option A.
5. The `vec` constant (5.4) switches the kernel between `V64` and `V32`.
   If H3 or H15 shows that `ymm` is better on c7i or c8i, the change is
   one table entry.

## 6. Hypotheses for P3, ranked

Ranking: the expected effect on G1-G6, times the uncertainty. Every
command runs the harness (`docs/slop/bench-design.md`, "bench run"). The
harness builds each revision with fixed flags and has no pass-through
for `-D` options. A threshold sweep is therefore a set of revisions:
one commit for each value, on branches `p3/<hyp>-<value>`. The impl
names are the P1a schema v2 names (`builtin`, `glibc`, `fastmem_abi`,
`fastmem_inline`). The memset op name is assumed to be `set` (open
question 7.1). Every run uses at least 5 rounds and the A/A floor
(the defaults).

| # | Hypothesis | Goal | Command | Pass if |
|---|---|---|---|---|
| G4F | **Fixed-size G4 gate, timing part.** For every n in 1-256, `fastmem_inline` with a comptime size is not slower than `@memcpy` with the same comptime size, in both public argument forms (`*[N]u8` and a constant-length slice), on c7i, c8i, c7a and c8a. The codegen part passed (4.12). | G4 | needs P1a support (7.1): a `fixed` suite with cases `copy/fixed/<n>` for n = 1..256, profiles `aligned` and `misaligned`, and impls `builtin` (constant-size `@memcpy`), `fastmem_inline` (pointer form) and `fastmem_inline_slice`. Each (impl, n) is its own comptime instance of the timed loop, with an empty `asm volatile` that takes both pointers and clobbers memory after each copy, so that LLVM can neither hoist nor delete the repeated copy. Then `just bench-run --rev WORKTREE --target c7i --target c8i --target c7a --target c8a --suite fixed --impl builtin,fastmem_inline,fastmem_inline_slice --label g4-fixed` | no case with `fastmem_inline/builtin` or `fastmem_inline_slice/builtin` significantly above 1.00, with 5 rounds and the A/A floor. If an Intel row in 64-256 fails, switch the fixed path on that target to `V32` above 32 bytes and rerun |
| H1 | The vector memset (5.3) is far faster than compiler-rt for n ≥ 16 and at parity with glibc on every size, on all four targets. | G2, G3 (set) | `just bench-run --rev WORKTREE --target c7i --target c8i --target c7a --target c8a --suite standard --filter set/ --label h1-set` | `fastmem_abi/builtin` < 1 on every case, and `fastmem_abi/glibc` tier geomean ≤ 1.00 |
| H2 | The v1 binary maps the source and the destination with separate `mmap` calls (`src/bench_fastmem.zig:625-634`, `:859-861`), so both are page-aligned. Then d mod 4096 is 0 in `aligned` and 2 in `misaligned` (offsets 1 and 3). Both are under 256, and glibc takes the backward loop for 513 … 16384 on Intel and for all n > 512 on AMD (1.4). `cross-lane` (d = −(chunk/2 − 1), for example 0xFE1 modulo 4096 for chunk 64) goes forward. On Intel above 16 KiB, the same d values select the source-aligned `rep movsb` (1.5). Without the 4K-aliasing test, fastmem runs a different loop from glibc on most copy rows. (Check again with the P1a v2 binary.) | G2 | `just bench-run --rev p3/h2-noalias --rev p3/h2-alias --suite standard --filter copy/ --label h2-alias` | the `alias` revision is significantly faster on n ≥ 513, or equal, and never slower |
| H3 | A `zmm` kernel (`vec` = 64, pointer form, 5.8) beats a `ymm` kernel (`vec` = 32, which is also what the array form gives on Intel, 4.8) for 128 B … 16 KiB on c7i and c8i, as glibc's choice implies. Run AMD too: Zen 4 executes 512-bit operations on 256-bit units (unverified), so the result can differ there. Check the saved disassembly of both revisions for `zmm` / `ymm` before reading the numbers. | G2 | `just bench-run --rev p3/h3-vec32 --rev p3/h3-vec64 --suite standard --filter copy/ --label h3-width`, then `--filter set/ --label h3-width-set` | vec64 ≤ vec32 on every tier, with a significant gain in 257-16384 |
| H4 | The Intel `rep movsb` threshold of 16 KiB is a formula (`dl-cacheinfo.h:999`), not a per-model measurement. A lower value (4 KiB, 8 KiB) or a higher one (32 KiB) is better on c7i or c8i. | G2 (1025-16384, > 16384) | `just bench-run --rev p3/h4-16k --rev p3/h4-4k --rev p3/h4-8k --rev p3/h4-32k --target c7i --target c8i --suite standard --filter copy/ --label h4-repmovsb` | pick the lowest geomean in tiers 1025-16384 and > 16384, and keep 16 KiB on a tie |
| H5 | For n < 64, the masked load/store (4.3) is not slower than the ladder on fixed sizes, and faster on `dist/small`, where the ladder mispredicts. A masked store can block store-to-load forwarding for a following read (unverified), so the fixed-size rows can lose. | G2, G4 | kernel: `just bench-run --rev p3/h5-ladder --rev p3/h5-masked --suite standard --filter copy/ --label h5-std`, then the same with `--suite dist --label h5-dist` | masked ≤ ladder on `dist`, and not slower than the floor on `standard` 0-63 |
| H6 | `inline_max` = 256 is better than 128 and 512 for `fastmem_inline` on `dist/small`. | G4 | `just bench-run --rev p3/h6-128 --rev p3/h6-256 --rev p3/h6-512 --suite dist --impl fastmem_inline,glibc --label h6-inline` | `fastmem_inline/glibc` ≤ 0.90 on every target with the chosen value |
| H7 | LLVM's extra 4× unroll of the 4-VEC loop (1 KiB per iteration, exp:vec) hurts 513 … 2048 through the remainder loop. A loop that LLVM does not unroll is faster there. | G2 (257-1024, 1025-16384) | `just bench-run --rev p3/h7-llvm-unroll --rev p3/h7-no-unroll --suite standard --filter copy/ --label h7-unroll` | no-unroll significantly faster on 513-2048, not slower elsewhere |
| H8 | glibc uses `rep movsb` for a forward overlap with a 1-byte gap on Intel (the flag that avoids it is off, 1.5). The vector loop is faster for `move/fwd-gap1` at 65536 and above. | G2 (move) | `just bench-run --rev p3/h8-rep --rev p3/h8-vec --target c7i --target c8i --suite standard --filter move/fwd-gap1/ --label h8-gap` | vec significantly faster on n > 16384 |
| H9 | glibc's AMD policy (no `rep movsb`, BZ #30994) holds on Turin: `rep movsb` from 16 KiB is slower than the vector loop on c8a. Also for `rep stosb` from 2 KiB. | G2 | `just bench-run --rev p3/h9-norep --rev p3/h9-rep16k --target c8a --suite standard --filter copy/ --label h9-turin`, then `--filter set/` | if `rep16k` wins significantly, add a znver5-only window |
| H10 | Destination alignment beats source alignment in the loop on AMD too (glibc aligns dst everywhere, compiler-rt aligns src). | G2 (misaligned, cross-lane) | `just bench-run --rev p3/h10-dst --rev p3/h10-src --target c7a --target c8a --suite standard --filter copy/misaligned/ --label h10-align` | keep dst unless src is significantly faster |
| H11 | The `vzeroupper` that LLVM adds after `zmm` use (exp:vec) costs measurable time below 256 bytes against glibc, which needs none. The asm variant with `zmm16-31` / `ymm16-31` (`high_regs`, 4.10) removes it. | G2 (0-16 … 65-256) | `just bench-run --rev p3/h11-llvm-regs --rev p3/h11-high-regs --suite standard --filter copy/ --label h11-vzu`, and the same with `--suite dist --label h11-vzu-dist` | turn `high_regs` on only if it is significantly faster on a tier and never slower |
| H12 | The x86_64_v3 build (5.7) is not slower than compiler-rt on any case. | G6 | needs a baseline-build run (P1a/P7, command form open, 7.1) | `fastmem_abi/builtin` ≤ 1.00 everywhere |
| H13 | For n ≥ NT threshold, a 2-page interleaved NT loop (1.6) beats a single stream. | parity above 12 MiB | needs a large-size suite (7.1): `just bench-run --rev p3/h13-1page --rev p3/h13-2page --suite large --filter copy/aligned/ --label h13-nt` | 2-page significantly faster at 64 MiB and 256 MiB |
| H14 | A per-iteration asm block for the NT loop (4 loads and 4 `vmovntdq` in `zmm16-19`, one `"memory"` clobber, exp:nt4 `ntPerBlock`) is not slower than per-store asm (exp:nt4 `ntPerStore`), and both reach glibc parity. Both variants keep the `"memory"` clobber: the asm writes memory through a register operand, so removing the clobber is not a valid variant (4.4). | parity above NT | as H13, `--rev p3/h14-per-store --rev p3/h14-per-block` | pick the faster one. If they are equal, keep per-block: it has no `leaq` and no `vzeroupper` |
| H15 | On c7i and c8i, `zmm` stores do not lower the core frequency for the code that runs **after** the copy. glibc assumes that for CPUs with AVX-VNNI (`cpu-features.c:973-977`). A copy microbenchmark cannot see it: it measures only the copy, at whatever frequency the copy itself runs. | G2 in real programs, G5 | needs a P1a profile (7.1): each iteration copies n bytes, then runs a fixed scalar integer loop (about 1 µs, and a 100 µs variant, because frequency changes take time to revert, unverified duration), and records `cycles` and `ref-cycles` for the copy and for the scalar phase. Then `just bench-run --rev p3/h3-vec32 --rev p3/h3-vec64 --target c7i --target c8i --suite freq --impl fastmem_abi,glibc --label h15-freq` | the scalar-phase time and its `cycles / ref-cycles` ratio differ by less than the A/A floor between vec32, vec64 and glibc. If vec64 lowers the scalar-phase frequency, prefer vec32 on that target even if H3 favors vec64 |

G4F is an acceptance gate, not a hypothesis. It runs as soon as the
inline layer exists (P4). H1, H2 and H3 decide the first kernel, and H15
can veto H3 on Intel.
H4-H8 tune it. H9-H14 can wait until G2 holds.

## 7. Open questions and risks

### 7.1 Open questions (for the parent or P1a)

1. **Harness interface.** Section 6 assumes the P1a schema v2: impl names
   `builtin`, `glibc`, `fastmem_abi`, `fastmem_inline`, a memset op
   named `set`, and filters of the form `<op>/<profile>/`. It also needs
   three things that `docs/slop/bench-design.md` does not define yet:
   a `large` suite (16 MiB, 64 MiB, 256 MiB, for the NT paths, H13/H14),
   a command form for the x86_64_v3 baseline build (H12), a `fixed`
   suite with a constant-size `@memcpy` impl and a constant-length slice
   impl, 256 comptime instances each (G4F), a `freq`
   suite with a "copy, then scalar work" profile and `cycles` /
   `ref-cycles` counters for each phase (H15), and, if possible, a `-D`
   pass-through so that threshold sweeps do not need one commit per
   value.
2. **Buffer layout in the v2 binary.** If v2 still maps the source and
   the destination separately, the `aligned` and `misaligned` profiles
   hit the glibc 4K-aliasing path (H2). A profile with d mod 4096 ≥ 512
   measures the forward loop (and the destination-aligned `rep movsb`
   on Intel). The buffers must not overlap for any n: put the
   destination at src + alignForward(n, 4096) + 1024 in one mapping of
   at least alignForward(n, 4096) + 1024 + n bytes. Then d mod 4096 =
   1024 and d ≥ n for every n. A layout with the destination at a fixed
   1 KiB after the source overlaps for n > 1024 and sends glibc to the
   backward loop (`so:0x196516-0x196519`). That is a choice for P1a.
3. **API for comptime sizes (G4).** The current facade is
   `copy(comptime T, dest: []T, source: []const T)`. A slice length is
   never comptime-known in Sema (exp:ct). Options: accept `anytype` and
   detect `*[N]T`, add `copyFixed(comptime n, …)`, or use the tuple test
   on an explicit length parameter. The recommendation is `anytype` with
   pointer-to-array detection: it is documented behavior, and existing
   calls with arrays get the fast path for free.
4. **Other CPU models.** A user with `-mcpu=native` on an Ice Lake server
   or an Emerald Rapids box gets the "other AVX-512BW" row (no
   `rep movsb`). Add rows for more models, or wait for runtime dispatch
   (P7)?
5. **AMD NT memset.** glibc never uses NT stores for memset on AMD,
   although it computes a 12 MiB threshold (1.8). Parity says "no". A
   large-suite test can show if NT memset wins there.

### 7.2 Risks

| Risk | Effect | Mitigation |
|---|---|---|
| `llvm.masked.*` externs are undocumented Zig behavior (4.3) | A Zig or LLVM upgrade can break the build or change the signature | One file (`ops.zig`) holds them. A comptime guard. A test that disassembles the masked class and checks for `vmovdqu8 … {%k1}` |
| The masked path only exists in the LLVM backend | Debug builds (self-hosted backend) run the ladder, so a Debug test does not cover the masked code | Run the G1 tests in ReleaseSafe and ReleaseFast as well as Debug |
| The tuple `is_comptime` test (exp:ct) is undocumented | It can change meaning | Prefer the type-based test (7.1, item 3) |
| Model-keyed constants encode the L3 size of these instance types (1.2) | A different instance size or a different host with the same `-mcpu` gets glibc-unlike thresholds | Document it. Build options override it. Runtime dispatch (P7) can read the cache size |
| LLVM models disagree with the guests about ERMS and FSRM (4.1) | Feature-bit tuning picks wrong paths | Tuning keys on the model (5.1) |
| LLVM unrolls our loops by 4× (exp:vec), and Zig has no loop pragma | Code size, remainder cost on 513 … 2048 | H7 |
| LLVM uses `zmm0-15`, so every vector path ends with `vzeroupper` (exp:vec) | A small constant per call that glibc does not pay | H11. Hand-written asm with `zmm16-31` is the fallback, at a cost in maintenance |
| The `"memory"` clobber on the NT store asm is a compiler barrier, and it is required (4.4) | Per-store asm adds a `leaq` for each store with an offset (exp:nt4) | H14 compares per-store asm with a per-iteration asm block. Both keep a correct memory contract |
| Masked memmove near a page end | A masked load or store whose masked-off bytes reach into an unmapped page does not fault, but can be slow (unverified). glibc does not use masking in memmove at all | `small_masked` defaults to off. If H5 turns it on, add the page tests for both pointers, as glibc does for memset |
| Masked stores and store-to-load forwarding | A read of the destination right after a masked store can stall (unverified) | H5 measures fixed sizes, where the harness reads nothing back. If H5 turns masking on, add a read-after-copy profile |
| `rep movsb` behavior in a VM | Fast-string microcode can differ under the hypervisor (unverified) | Only measurements on the boxes count (H4, H8) |
| The glibc source is the `release/2.40/master` head, newer than the host build | A line cited here can differ from the code that the hosts run | The disassembly and the host facts are the primary sources. The source only explains them |
| Zen 4 double-pumps 512-bit operations (unverified) | 64-byte vectors can be no better than 32-byte vectors on c7a | H3 runs on AMD too |
| `zmm` on Intel depends on the source form (4.8) | A later edit that routes data through an array, a struct, or `@memcpy` silently gives `ymm` on c7i and c8i | The codegen test of 5.8, item 2 |
| The pointer form depends on LLVM keeping `<64 x i8>` legal under `prefer-256-bit` when the function has no `min-legal-vector-width` attribute (4.8, unverified in the LLVM source) | If a Zig upgrade starts to emit that attribute, as clang does (unverified), every kernel falls back to `ymm` | The same codegen test. Fallbacks: option B (per-module CPU) or option C (asm), 5.8 |
| `@disableIntrinsics()` applies to the whole caller when it is in an `inline fn` (4.11) | The caller's own runtime `@memcpy` calls become byte loops | Use it only in non-inline kernel functions |
| Downclocking after `zmm` code on Intel (H15) | A copy that looks faster in isolation can slow the code after it | H15 before the Intel `vec` choice is final |

### 7.3 What this memo did not verify

- No hardware run. Every performance statement is a hypothesis for P3.
- The Intel optimization manual text on 4K aliasing, the SDM text on
  masked-store fault suppression, and the Zen 4 512-bit datapath were
  not re-read. They are marked "unverified" where used.
- The loop shape with a pointer bound instead of a counter (exp:vec) was
  not compiled.
- The x86_64_v3 memmove small path of compiler-rt was not inspected for
  stack spills (3.2, "not checked").
- The LLVM rule that keeps `<64 x i8>` legal under `prefer-256-bit`
  without a `min-legal-vector-width` attribute was inferred from the
  results of 4.8, not read in the LLVM source.
- The per-module CPU override (4.9) was tested with `zig build-obj`
  only, not with an executable link or through `build.zig`.
- The frequency behavior of `zmm` stores on Sapphire and Granite Rapids
  (H15) is glibc's assumption, not a measurement.
