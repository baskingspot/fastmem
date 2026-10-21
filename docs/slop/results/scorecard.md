# Scorecard

The current state of fastmem against glibc 2.40 and compiler-rt (Zig 0.16)
on all seven targets. Update this file after each full-fleet run of main.

Runs: `bench-results/20260927T162241Z-final-standard/` (target CPUs),
`...171003Z-final-baseline/` (x86_64 / generic, runtime dispatch),
`...175720Z-final-large/` (large suite). Main 418197e. Standard suite, 6
rounds, A/A on, fixed-size revision labels, THP arena. Correctness:
`bench-results/20260927T154725Z-test/`, 42/42 (7 targets x target and
baseline CPU x ReleaseFast, ReleaseSafe, Debug).

Ratios: time ratio, geometric mean per tier (0-16 / 17-64 / 65-256 /
257-1K / 1K-16K / >16K bytes). Below 1 means fastmem is faster.

### target, abi / glibc (G2)

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.66 0.77 0.93 1.06 1.01 1.00 | 0.96 1.08 1.17 1.01 1.01 1.00 | 0.82 0.94 1.02 0.99 1.00 1.00 | 0.95 1.02 1.09 1.01 0.99 0.87 | 1.00 1.00 1.01 1.00 0.99 1.00 | 1.00 1.00 1.00 1.00 1.00 1.00 | 0.53 0.77 1.00 1.00 1.00 1.00 |
| move | 0.63 0.93 1.02 0.99 0.99 0.40 | 0.89 0.99 1.06 0.96 0.99 0.40 | 0.81 0.93 0.96 0.98 0.99 0.99 | 0.92 1.00 1.00 0.98 0.98 0.93 | 0.85 1.00 1.02 1.00 1.01 1.00 | 0.90 0.97 1.00 1.00 1.00 1.00 | 0.57 0.80 1.00 1.00 1.00 1.00 |
| set | 0.34 0.41 1.01 0.99 1.01 1.00 | 0.39 0.45 1.06 0.97 1.00 1.00 | 0.37 0.49 1.03 1.00 1.00 1.02 | 0.53 0.52 1.12 1.00 1.00 1.00 | 1.00 0.89 1.00 1.00 1.00 1.00 | 1.00 0.89 1.00 1.00 1.00 1.00 | 0.59 0.89 1.00 1.00 1.00 1.00 |
### target, abi / compiler-rt (G3)

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 1.08 0.94 0.53 0.64 0.59 0.87 | 1.12 1.04 0.44 0.57 0.58 0.88 | 1.07 1.20 0.83 0.96 0.95 0.98 | 0.99 0.98 0.93 1.03 0.93 0.97 | 0.85 0.78 0.84 0.86 0.96 0.97 | 0.78 0.78 0.90 0.88 0.96 0.99 | 0.78 0.85 0.89 0.88 0.96 0.95 |
| move | 0.94 0.77 0.76 0.79 0.67 0.97 | 1.04 0.76 0.74 0.81 0.66 0.98 | 1.20 0.65 0.42 0.75 0.93 0.96 | 0.94 0.64 0.54 0.75 0.89 0.97 | 0.89 0.73 0.73 0.71 0.92 0.92 | 0.82 0.53 0.69 0.72 0.86 0.89 | 0.76 0.52 0.69 0.79 0.91 0.93 |
| set | 0.55 0.25 0.09 0.05 0.04 0.11 | 0.74 0.27 0.07 0.05 0.03 0.12 | 0.74 0.39 0.11 0.08 0.07 0.07 | 0.92 0.38 0.11 0.04 0.03 0.04 | 0.72 0.28 0.12 0.07 0.06 0.06 | 0.53 0.20 0.11 0.07 0.06 0.06 | 0.54 0.19 0.11 0.07 0.06 0.06 |
### target, inline / glibc (G4)

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.50 0.79 0.81 1.03 1.00 1.00 | 0.74 0.65 0.96 0.99 1.01 1.00 | 0.85 0.60 0.81 1.04 1.01 1.00 | 0.75 0.59 1.07 1.16 1.00 0.88 | 0.56 0.71 0.99 1.00 1.00 1.00 | 1.09 0.98 1.00 1.00 1.00 1.00 | 0.52 0.68 1.00 1.02 1.00 1.00 |
| move | 0.62 0.99 0.98 1.05 1.00 0.40 | 0.60 0.84 0.98 0.96 0.99 0.40 | 0.57 0.89 0.87 1.00 0.99 0.99 | 0.48 0.80 0.84 1.08 1.01 0.95 | 0.53 0.78 1.00 0.99 1.00 1.00 | 0.93 0.90 1.02 1.00 1.00 1.00 | 0.56 0.75 1.00 1.01 1.00 1.00 |
| set | 0.57 0.34 0.78 1.00 1.03 1.00 | 0.25 0.20 0.78 0.96 1.03 1.00 | 0.43 0.30 0.80 1.00 1.00 1.02 | 0.28 0.19 0.61 0.89 1.00 1.02 | 0.29 0.52 0.98 0.99 1.00 1.00 | 0.65 0.73 1.00 1.00 1.00 1.00 | 0.33 0.74 1.00 1.00 1.00 1.00 |
### baseline (x86_64 / generic), abi / glibc

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.62 0.95 1.30 1.04 1.00 1.00 | 0.85 1.28 1.60 1.04 1.00 1.00 | 0.79 1.02 1.19 0.99 0.99 1.00 | 0.97 1.15 1.22 1.05 1.00 0.87 | 1.25 1.02 0.99 1.00 1.00 1.00 | 1.57 0.98 1.00 1.00 1.00 1.00 | 0.84 0.68 1.00 1.00 1.00 1.00 |
| move | 0.72 1.00 1.04 0.96 0.99 0.40 | 0.90 1.03 1.11 0.97 0.98 0.40 | 0.83 0.95 0.97 0.96 0.99 0.99 | 0.97 1.03 1.07 0.97 0.98 0.94 | 0.88 1.01 1.00 1.00 1.01 1.00 | 0.98 1.00 1.00 1.00 1.00 1.00 | 0.78 0.89 1.00 1.00 1.00 1.00 |
| set | 0.34 0.54 1.27 1.01 1.01 1.00 | 0.33 0.54 1.56 1.02 1.01 1.00 | 0.39 0.46 1.18 1.00 1.00 1.02 | 0.52 0.57 1.07 0.94 1.01 1.03 | 1.00 0.90 1.00 1.00 1.00 1.00 | 1.14 0.89 1.00 1.00 1.00 1.00 | 0.64 0.92 1.00 1.00 1.00 1.00 |
### baseline, abi / compiler-rt (G6)

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.84 0.97 0.55 0.44 0.36 0.87 | 0.84 0.98 0.60 0.45 0.35 0.81 | 0.97 1.18 0.77 0.65 0.54 0.92 | 1.01 1.09 0.80 0.62 0.47 0.85 | 1.01 0.75 0.61 0.47 0.46 0.60 | 1.12 0.74 0.73 0.50 0.51 0.71 | 1.11 0.70 0.66 0.49 0.51 0.63 |
| move | 1.04 0.80 0.77 0.63 0.44 0.91 | 1.03 0.79 0.80 0.64 0.41 0.90 | 1.07 0.72 0.85 0.83 0.57 0.68 | 1.00 0.76 0.81 0.70 0.48 0.65 | 1.10 0.68 0.70 0.52 0.53 0.67 | 1.20 0.65 0.73 0.56 0.53 0.69 | 1.16 0.65 0.73 0.59 0.52 0.66 |
| set | 0.60 0.34 0.11 0.05 0.03 0.11 | 0.64 0.36 0.11 0.05 0.04 0.12 | 0.82 0.38 0.13 0.08 0.07 0.07 | 0.83 0.40 0.11 0.04 0.03 0.04 | 0.56 0.13 0.06 0.03 0.03 0.03 | 0.44 0.09 0.05 0.03 0.03 0.03 | 0.41 0.10 0.05 0.03 0.03 0.03 |

### dist/small, inline / glibc (target)

| | c7i SPR | c8i GNR | c7a Zen4 | c8a Zen5 | c7g V1 | c8g V2 | c9g V3 |
|---|---|---|---|---|---|---|---|
| copy | 0.33 | 0.36 | 0.69 | 0.84 | 1.07 | 1.01 | 0.94 |
| move | 0.89 | 0.92 | 0.95 | 0.96 | 1.03 | 0.98 | 0.98 |
| set | 0.58 | 0.59 | 0.52 | 0.44 | 1.12 | 1.01 | 0.98 |

Floors (A/A median / p90, %): c7i: 0.95/3.48 | c8i: 0.23/1.05 | c7a: 0.52/11.91 | c8a: 0.30/4.90 | c7g: 0.27/1.76 | c8g: 0.28/2.14 | c9g: 0.21/1.39

Target G2/G3: c7i: copyFAIL:FAIL, moveFAIL:FAIL, setFAIL:PASS | c8i: copyFAIL:FAIL, moveFAIL:FAIL, setFAIL:FAIL | c7a: copyPASS:FAIL, movePASS:FAIL, setPASS:FAIL | c8a: copyFAIL:FAIL, movePASS:FAIL, setFAIL:FAIL | c7g: copyFAIL:FAIL, moveFAIL:FAIL, setPASS:PASS | c8g: copyPASS:FAIL, moveFAIL:FAIL, setPASS:PASS | c9g: copyPASS:FAIL, movePASS:FAIL, setPASS:PASS

Baseline G6: c7i: copyFAIL, moveFAIL, setPASS | c8i: copyFAIL, moveFAIL, setPASS | c7a: copyFAIL, moveFAIL, setFAIL | c8a: copyFAIL, moveFAIL, setPASS | c7g: copyFAIL, moveFAIL, setPASS | c8g: copyFAIL, moveFAIL, setPASS | c9g: copyFAIL, moveFAIL, setPASS

## Open gaps (next work, ordered)

1. c8i copy 65-256 B 1.11-1.17 and move 65-256 B 1.06; set 65-256 1.06;
   c8a set 65-256 1.12; c7a set 65-256 1.03; c7i copy 257-1K 1.06.
   x86i's three candidates all lost on the fleet (below); the tier may be
   at a structural floor against glibc's avx512 loop shape.
2. Baseline builds vs glibc 65-256 B: 1.13-1.60 (the level-entry ladder; the
   x86f dispatch candidate that lowered the stub limit lost).
3. c7a 0-16 B move vs compiler-rt 1.20; c7a/c8a set 0-16 vs compiler-rt
   0.74-0.92; c7g/c8g/c9g set 0-16 baseline vs glibc 1.00-1.14.
4. c7a A/A p90 11.9%: its noisiness remains.

## x86i, 2026-09-30 (all three candidates rejected)

Runs: 20260930T050203Z-x86i-gate2 (default; .text byte-identical to main on
all 7 targets — the zero-drift rework held), 062445Z chunks, 072023Z
endpairs, 080840Z mask16. Candidate detail: docs/slop/results/x86i-candidates.md.

- x86i_chunks: no win on any targeted tier (c8i copy 65-256 1.149 vs main
  1.112; c7a set 65-256 +2.9%). Rejected.
- x86i_endpairs: c8i copy 0-16 +26% and 65-256 worse (1.162 vs 1.111).
  Rejected.
- x86i_mask16: c7a move 0-16 abi 2.09x (the masked memmove path is 2x
  slower through the C ABI on Zen 4; inline unaffected). Rejected.
- Harness: `bench run --x86-experiment` now passes -Dx86-experiment per
  source with a declared-value fallback (11403d0, 42976fc), so future
  experiment lanes need no scratch tuning flips.
5. G4 dist/small: copy 0.33-0.94 except c7g 1.07 and c8g 1.01; move
   0.89-1.03; set 0.44-1.12. The 0.90 target is met on x86 copy, not on the
   Gravitons (plan amended to a per-arch target 2026-09-29).
6. c7g copy/aligned|page-offset 128 B is bimodal on main itself (2.71 vs
   3.08 ns slots; armi gate, 20260930T014016Z): its G2 mark flips run to
   run without any code change. Treat a c7g 128 B copy flag as a rerun
   request, not a regression.

## armi, 2026-09-30 (rejected)

- c7g move fwd-gap31 16-31 B vs compiler-rt (1.74-1.77): closed by proof,
  not code. glibc's fast case is 2.31 ns = fastmem's current cost on the
  other rows; every reroute lands a passing row at 1.17-1.26x glibc, and
  every separating gate costs the stay-SVE rows more than their zero
  margin. Third rejection after neon32 and v1move-ft; stop trying.
- v1mid (V1 comptime-VL mid path): rejected twice over. Correctness:
  truncates 33..64 copies at VL=16 and over-reads in hybrid_n32/ft
  (reproduced natively on a V3 host with sve_default_vector_length=16;
  same trap as the reverted p3-armc). Fleet: 96 B rows win 11-13% but
  move/fwd-half/256 loses 35% and the bwd 768s lose 7-12%.
- set-split (generic memset 4..15 split at 8): clean code, but regresses
  the box it targeted (c8g baseline set 1..7 +11-14%; c7g dist/small
  +14%). c9g 4..15 wins 14%; not worth the trade. Rejected.
- Baseline set 0-16 vs glibc on the Gravitons stays open (1.00-1.14).

## Zen 5 memset NT gate, 2026-09-28 (x86h-set48, a07cd08)

- x86h measured temporal vs NT for the znver5 memset at 32, 48, and 64 MiB:
  temporal wins all three. The znver5 memset never uses NT now (the largent
  48 MiB NT switch is reverted); c8a set 32-48 MiB vs glibc is closed.
- The dispatch table expects nt: False for the znver5 set large policy
  (57ee94d).
- Rejected in the same lane: a lowered dispatch stub limit and a zen4
  variant (both lost on the fleet; second rejection for each).

## Large NT, 2026-09-27 (largent, 13c9509)

- c7i copy/move/disjoint 64 MiB vs glibc: 1.11-1.13 -> 1.00-1.01.
- c8a set 64 MiB vs glibc: 1.39-1.40 -> 0.94; 48 MiB: 1.48-1.53 -> 1.15.
- Zen 5 memset NT starts at 48 MiB (32 MiB loses to temporal 2.04x).
  Superseded by x86h-set48: temporal wins at 48 and 64 MiB too, so the
  znver5 memset never uses NT.
- c8a copy/page-offset 16 MiB 0.73 -> 0.86 vs glibc (changed with the
  composite; still a win, watch it).
