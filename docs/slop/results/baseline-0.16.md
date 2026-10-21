# Baseline: compiler-rt vs glibc on Zig 0.16 (P1d)

Run: `bench-results/20260924T041207Z-baseline-016/` (gitignored raw data).
Commit 35ee1b5 plus the label fix. Standard suite, 5 rounds, A/A on, seven
targets, glibc 2.40 (NixOS 25.11 AMI), `-Dcpu` from `bench.toml`.

`builtin` is compiler-rt: `@memcpy`/`@memmove`/`@memset` with a runtime
length, called through the resolved symbol (what Zig programs get today).
`glibc` is resolved with `dlsym` and verified in each raw file. Ratios are
`builtin / glibc` time: above 1 means compiler-rt is slower.

This page reports geometric means of point estimates. The significance
marks of this run are not reliable (see "Measurement quality" below). The
effects on this page are large compared to the round-to-round variation.

## Geometric mean of builtin / glibc, fixed profiles, by size tier

memcpy:

| Target | 0-16 | 17-64 | 65-256 | 257-1K | 1K-16K | >16K | dist/small | dist/mixed |
|---|---|---|---|---|---|---|---|---|
| c7i | 0.62 | 0.82 | 1.95 | 1.68 | 1.69 | 1.16 | 0.54 | 1.64 |
| c8i | 0.84 | 1.18 | 2.27 | 1.57 | 1.71 | 1.11 | 0.99 | 1.62 |
| c7a | 0.83 | 0.84 | 1.26 | 1.00 | 1.04 | 1.02 | 0.87 | 1.02 |
| c8a | 0.96 | 1.03 | 1.11 | 0.99 | 1.03 | 0.90 | 1.05 | 1.05 |
| c7g | 1.14 | 1.29 | 1.19 | 1.16 | 1.03 | 1.03 | 1.41 | 1.11 |
| c8g | 1.28 | 1.29 | 1.10 | 1.14 | 1.03 | 1.01 | 1.08 | 1.09 |
| c9g | 0.69 | 0.91 | 1.12 | 1.14 | 1.05 | 1.05 | 1.06 | 1.08 |

memmove:

| Target | 0-16 | 17-64 | 65-256 | 257-1K | 1K-16K | >16K | dist/small | dist/mixed |
|---|---|---|---|---|---|---|---|---|
| c7i | 0.65 | 1.30 | 1.35 | 1.20 | 1.54 | 0.32 | 1.04 | 1.40 |
| c8i | 0.98 | 1.51 | 1.35 | 1.17 | 1.54 | 0.31 | 1.34 | 1.57 |
| c7a | 0.75 | 1.48 | 2.29 | 1.52 | 1.18 | 1.02 | 1.87 | 1.17 |
| c8a | 0.98 | 1.48 | 2.00 | 1.58 | 1.23 | 0.93 | 1.63 | 1.17 |
| c7g | 0.94 | 1.39 | 1.35 | 1.44 | 1.11 | 1.09 | 1.34 | 1.13 |
| c8g | 1.14 | 1.68 | 1.38 | 1.40 | 1.18 | 1.16 | 1.25 | 1.17 |
| c9g | 0.75 | 1.45 | 1.36 | 1.25 | 1.11 | 1.08 | 1.30 | 1.10 |

memset:

| Target | 0-16 | 17-64 | 65-256 | 257-1K | 1K-16K | >16K | dist/small | dist/mixed |
|---|---|---|---|---|---|---|---|---|
| c7i | 0.57 | 1.54 | 11.75 | 19.47 | 28.74 | 9.33 | 5.19 | 22.26 |
| c8i | 0.53 | 1.53 | 14.64 | 20.32 | 28.82 | 8.35 | 4.87 | 21.93 |
| c7a | 0.45 | 1.22 | 9.33 | 13.19 | 14.64 | 14.71 | 3.22 | 13.49 |
| c8a | 0.60 | 1.33 | 10.38 | 26.78 | 29.18 | 23.00 | 4.16 | 24.88 |
| c7g | 1.39 | 3.18 | 8.49 | 14.17 | 15.78 | 15.89 | 5.08 | 13.92 |
| c8g | 1.88 | 4.55 | 8.91 | 14.36 | 15.81 | 16.02 | 7.39 | 14.03 |
| c9g | 1.08 | 4.57 | 8.96 | 14.75 | 16.30 | 16.60 | 6.62 | 15.47 |

## Findings

1. memset is the largest gap. compiler-rt memset is 8x to 29x slower
   than glibc above 64 bytes on every target, x86 and aarch64. The
   aarch64 memo found that compiler-rt memset is a byte loop (E8). This
   is the first fix that the Zig ecosystem needs.
2. memcpy on Intel (c7i, c8i) is 1.6x to 2.3x slower than glibc from 65
   bytes to 16 KiB. On AMD (c7a, c8a) compiler-rt memcpy is near glibc.
   On Graviton it is 1.1x to 1.3x slower.
3. memmove is 1.2x to 2.3x slower from 17 bytes to 16 KiB on every
   target.
4. compiler-rt is faster than glibc below 16 bytes on most x86 targets
   and on c9g.
5. glibc is slow for forward overlapping moves with a small gap on Intel.
   For `move/fwd-gap{1,31,33}` above 16 KiB, glibc takes 15x as long as
   compiler-rt on c7i (285 us against 19 us for 1 MiB). Backward and
   disjoint moves are at parity. The probable cause is `rep movsb` with a
   short distance (the `rep_movsb_threshold` is 16 KiB, and
   `Avoid_Short_Distance_REP_MOVSB=0` on these hosts). The mechanism is
   unverified. The x86 lane must confirm it. It is a place where fastmem
   can be much faster than glibc.

## Measurement quality

- The whole-round geometric means stay within 3% on every target. The
  rounds are stable.
- Single cases have sporadic spikes: one case in one round of ten is up
  to 4.7x slower (c8a `copy/const/64`: 0.402 ns in nine rounds, 1.903 ns
  in one). A spike lasts for the whole case, so the median of the samples
  in the round does not remove it.
- The floor takes the maximum of the CI endpoints over its group. One
  spike therefore sets the floor of the whole group. The median floors are
  2-4% on Intel and Graviton and 12-14% on AMD, and the maxima reach 18% to
  373%. The significance marks and the G2/G3 verdicts of this run are not
  usable. The P1 stats fix addresses this.
- Large cases (256 KiB, 1 MiB) are bimodal per round on c9g (3378 or 4012
  ns). Physical page placement is a probable cause (unverified).
