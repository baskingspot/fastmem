# Small-size A/B: C-ABI entry fixes on both architectures

Runs (raw data in the lane worktrees, copied to `bench-results/`):
- x86: `20260924T101602Z-p3-x86b`. v0 = main 36c960f, v1 = entry-only
  (f1638dc), v2 = high-register entry (8fb8317). 5 rounds.
- aarch64: `20260924T102308Z-p3-arm-small`. v0 = main, v1 =
  `fleet-control-sve` (trampoline fix, SVE small path), v2 = 989e3ac
  (per-model small path). 6 rounds.

Correctness before these runs: x86 24/24 (Fast/Safe/Debug, target and
x86_64_v3); aarch64 6/6 (ReleaseFast). Both are merged in a54b3ac.

## fastmem_abi / glibc, geometric mean by tier (0-16 / 17-64 / 65-256 B)

| Target | op | v0 | v1 | v2 (merged) |
|---|---|---|---|---|
| c7i | copy | 1.32 1.17 1.17 | 0.70 1.03 1.34 | 0.71 0.80 1.17 |
| c7i | move | 1.22 1.08 1.03 | 0.76 0.96 1.04 | 0.77 0.87 1.03 |
| c7i | set | 0.98 1.04 1.14 | 0.34 0.64 1.41 | 0.36 0.41 1.14 |
| c8i | copy | 1.78 1.63 1.45 | 0.87 1.30 1.51 | 0.94 1.11 1.42 |
| c8i | move | 1.55 1.23 1.07 | 0.90 1.05 1.07 | 0.95 0.98 1.07 |
| c8i | set | 1.02 1.08 1.32 | 0.33 0.65 1.69 | 0.35 0.40 1.34 |
| c7a | copy | 1.06 1.02 0.99 | 0.90 0.90 1.00 | 0.88 0.92 1.14 |
| c7a | move | 1.04 0.98 0.95 | 0.91 0.91 0.95 | 0.90 0.93 0.98 |
| c7a | set | 1.05 1.09 1.29 | 0.50 0.67 1.18 | 0.49 0.52 1.14 |
| c8a | copy | 1.30 1.21 1.10 | 1.09 1.12 1.18 | 1.09 1.07 1.13 |
| c8a | move | 1.22 1.09 1.04 | 1.06 1.02 1.03 | 1.06 1.01 1.01 |
| c8a | set | 0.98 0.99 1.10 | 0.54 0.67 1.25 | 0.53 0.52 1.12 |
| c7g | copy | 1.01 0.99 1.04 | 1.00 1.00 0.99 | 1.00 1.00 1.00 |
| c7g | move | 1.00 1.00 1.01 | 1.00 1.00 1.00 | 1.00 1.00 1.00 |
| c7g | set | 1.16 0.98 1.06 | 1.27 0.99 1.01 | 1.26 0.97 1.01 |
| c8g | copy | 1.29 1.13 1.00 | 1.00 1.00 1.00 | 1.00 1.00 1.00 |
| c8g | move | 1.21 1.05 1.00 | 1.00 1.00 1.00 | 1.00 1.00 1.00 |
| c8g | set | 1.33 1.04 1.02 | 1.00 0.89 1.00 | 1.00 0.89 1.00 |
| c9g | copy | 1.03 0.99 0.99 | 1.00 1.00 1.00 | 0.57 0.70 1.01 |
| c9g | move | 1.03 1.00 0.99 | 1.00 1.00 1.00 | 0.64 1.00 0.99 |
| c9g | set | 1.08 1.02 1.01 | 1.00 0.89 1.00 | 0.59 0.90 1.01 |

## fastmem_abi / builtin (compiler-rt), merged variant (0-16 / 17-64 / 65-256 B)

| Target | copy | move | set |
|---|---|---|---|
| c7i | 0.96 0.97 0.64 | 1.14 0.69 0.78 | 0.67 0.26 0.10 |
| c8i | 0.93 0.96 0.69 | 1.11 0.71 0.80 | 0.68 0.27 0.09 |
| c7a | 1.21 1.29 0.92 | 1.27 0.62 0.39 | 1.06 0.43 0.13 |
| c8a | 1.13 1.02 1.02 | 1.08 0.65 0.49 | 0.90 0.39 0.11 |
| c7g | 0.91 0.79 0.84 | 1.08 0.65 0.73 | 0.91 0.25 0.12 |
| c8g | 0.78 0.78 0.90 | 0.89 0.65 0.73 | 0.52 0.20 0.11 |
| c9g | 0.83 0.76 0.88 | 0.88 0.79 0.75 | 0.54 0.20 0.11 |

## Findings

1. The ABI trampoline was the whole c8g gap. Removing it (v1) takes c8g
   from 1.29 to 1.00 at 0-16 B.
2. The x86 scalar entry takes the 0-16 B tier from 1.2-1.8x glibc to
   0.7-1.09x. Small memset is 2-3x faster than glibc on all x86 targets.
3. The V3 NEON small path makes c9g 0.57-0.70x glibc and 0.83-0.88x
   compiler-rt at 0-16 B.
4. Remaining gaps:
   - x86 65-256 B: copy 1.13-1.42x glibc, set 1.12-1.34x.
   - compiler-rt still wins x86 move at 0-16 B (1.08-1.27x) and AMD copy
     at 0-64 B (1.02-1.29x). c7g move at 0-16 B is 1.08x.
   - c7g set at 0-16 B is 1.26x glibc.
