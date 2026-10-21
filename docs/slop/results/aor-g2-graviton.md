# AOR SVE kernels on Graviton: first G2 measurement

Run: `bench-results/20260924T064442Z-aor-g2/` (main 5be06d6 plus the P2
merge, AOR `5e20a93` ports). Standard suite, 5 rounds, A/A on, analyzed
with the robust estimator (58d46e3). Ratios are time ratios: below 1 means
fastmem is faster.

Correctness: `bench-results/20260924T063944Z-test/`: 14/14 PASS (target
and baseline CPU builds, 28,047,836 cases each, copy/move/set).

## Geometric mean by size tier (fixed profiles)

| fastmem_abi / glibc | 0-16 | 17-64 | 65-256 | 257-1K | 1K-16K | >16K |
|---|---|---|---|---|---|---|
| c7g copy | 1.02 | 0.99 | 1.03 | 1.00 | 1.00 | 1.00 |
| c7g move | 1.01 | 1.00 | 1.01 | 0.99 | 1.00 | 1.00 |
| c7g set | 1.28 | 0.93 | 1.02 | 1.00 | 1.00 | 1.00 |
| c8g copy | 1.28 | 1.13 | 0.99 | 1.00 | 1.00 | 1.00 |
| c8g move | 1.21 | 1.05 | 1.00 | 1.00 | 1.00 | 1.00 |
| c8g set | 1.33 | 1.04 | 1.02 | 1.01 | 1.00 | 1.00 |
| c9g copy | 1.03 | 0.99 | 0.98 | 1.00 | 1.00 | 1.01 |
| c9g move | 1.03 | 1.00 | 0.99 | 1.00 | 1.00 | 1.00 |
| c9g set | 1.08 | 1.02 | 1.02 | 1.00 | 1.00 | 1.00 |

| fastmem_abi / builtin | 0-16 | 17-64 | 65-256 | 257-1K | 1K-16K | >16K |
|---|---|---|---|---|---|---|
| c7g copy | 0.87 | 0.78 | 0.87 | 0.86 | 0.97 | 0.98 |
| c7g move | 1.02 | 0.65 | 0.73 | 0.69 | 0.90 | 0.91 |
| c7g set | 0.78 | 0.23 | 0.12 | 0.07 | 0.06 | 0.06 |
| c8g copy | 1.00 | 0.88 | 0.90 | 0.88 | 0.96 | 0.99 |
| c8g move | 1.07 | 0.66 | 0.73 | 0.71 | 0.84 | 0.86 |
| c8g set | 0.71 | 0.23 | 0.11 | 0.07 | 0.06 | 0.06 |
| c9g copy | 1.50 | 1.08 | 0.87 | 0.88 | 0.96 | 0.96 |
| c9g move | 1.40 | 0.75 | 0.75 | 0.79 | 0.91 | 0.92 |
| c9g set | 1.01 | 0.22 | 0.11 | 0.07 | 0.06 | 0.06 |

## Verdicts and findings

- Above 64 bytes the port is at parity with glibc on all three targets,
  as expected: glibc 2.40 uses the same AOR code.
- G2 fails only because of sizes up to 64 bytes. On c8g the same algorithm
  is 13-33% slower than glibc there. Candidate causes: code alignment in
  our binary, the `abi` entry branch, and the BTI landing pad. None is
  verified.
- G3 fails at small sizes: compiler-rt is up to 1.5x faster than the AOR
  kernel below 16 bytes on c9g, and 1.4x for move. fastmem needs its own
  small-size path. That is the challenger work of P3.
- memset is 8-16x faster than compiler-rt above 256 bytes on all three.
- G4 `dist/small` (inline / glibc): 0.88 (c7g), 1.00 (c8g), 1.00 (c9g)
  for copy. The 0.90 target is not met on c8g and c9g.
