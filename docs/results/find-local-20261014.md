# Local find candidates, 2026-10-14

> The run owner removed the local raw runs and temporary binaries after acceptance on 2026-10-15.
> The committed summaries and regression data remain.

These measurements select local experiments. They do not establish fleet acceptance.
These local campaigns used no cloud resources.
A separate [fleet report](find-early-standard-20261015.md) records the later acceptance of the early-packed candidate.

## Sources and method

The baseline is `8bb798790829082f981e3b1830b7216ccf86381e`.
The parent reused its accepted generic ARM executable without a rebuild or proof replay.
Each candidate changes only `src/find.zig` relative to the documented experiment base.
Both candidates passed their full local test gate and an independent source review.

| Candidate | Commit | Change |
|---|---|---|
| Directional vectors | `a7ee982298854cf0418d7716845423d96f6282f9` | Bounded SIMD verification in the Two-Way right and left scans |
| Few starts | `1821bf5a648cedd8b3cce6900f952fac2b9a6a5d` | Initial equality and at most 17 complete candidate comparisons |

The host is `launchpad`, an aarch64 Linux system.
All binaries use Zig 0.16.0, `ReleaseFast`, and `aarch64-linux-gnu/generic`.
The processes use CPU affinity on logical CPU 3.
This setup does not reserve the CPU or restrict other processes.

The parent waited for the owned gates before each campaign.
The driver checked selected QEMU processes once before the samples.
No continuous process trace exists, so these orchestration checks do not prove isolation.

Each candidate has a separate campaign with these properties:

- Six processes per variant.
- The unchanged baseline, the candidate, and an exact baseline A/A duplicate.
- The existing balanced schedule with seed one.
- All 219 standard cases, including 210 runtime cases and nine fixed cases.
- Three samples per cell and one millisecond per sample.
- One millisecond of warmup per cell.

The driver uses the existing schedule, strict parser, analysis, and estimator APIs.
Every process passed the complete inventory, checksum, result, resolution, and metadata checks.
Each campaign contains 18 raw files.
Outliers remain in the analysis.
No simultaneous multiplicity correction applies.

The local libc is Nix glibc `2.42-84`, not fleet glibc `2.40`.
An independent process probe and the ELF symbol table agree on the `memmem` offset, `0xaa764`.
The ELF defines a weak `FUNC`, not an `IFUNC`.
The libc file hash is `5a88b3d2149f32a4aa083c5bfcdb37ef49c082f09d0c96aba9c8529f070e0b6c`.
The stdlib reference remains Zig 0.16.0 `std.mem.find`.
Rust is not a measured reference.

## Aggregate local results

The primary statistic uses the geometric mean of per-case latency medians for each process.
The independent estimator compares the six process values between variants.
The estimator reports a 95.887 percent interval level.
Ratios below one favor the candidate or A/A duplicate over the baseline.

| Candidate | Candidate / baseline | Interval | A/A / baseline | A/A interval |
|---|---:|---|---:|---|
| Directional vectors | 0.98817 | [0.96211, 1.00246] | 1.00076 | [0.97286, 1.02018] |
| Few starts | 0.79415 | [0.78754, 0.80254] | 1.00280 | [0.98947, 1.02389] |

The few-starts candidate reduces this local geometric-mean latency by about 20.6 percent.
The directional-vector interval includes one, and its small point estimate does not clear the aggregate A/A uncertainty.
These geometric means give every runtime stress case equal weight.
They do not represent application frequency.

## Individual cases and regressions

These rows use the existing per-case independent estimator.
They compare the candidate with the unchanged fastmem baseline, not the stdlib.
The latency columns contain medians of the six process medians.

| Candidate | Case | Candidate / baseline | Candidate latency | Baseline latency |
|---|---|---:|---:|---:|
| Few starts | `rare/end/4097/4096` | 0.004626 | 120.16 ns | 25,972.63 ns |
| Few starts | `periodic/absent/64/4` | 1.13976 | 16.27 ns | 14.21 ns |
| Directional vectors | `rare/absent/262144/1024` | 0.21102 | 20,924.09 ns | 99,184.80 ns |
| Directional vectors | `near/absent/65536/33` | 1.72347 | 75,792.58 ns | 43,990.32 ns |
| Directional vectors | `low/middle/262144/33` | 1.76367 | 147,542.67 ns | 83,928.77 ns |

The few-starts campaign has one significant primary regression with an interval entirely above 1.10.
The directional-vector campaign has seven such regressions:

- `low/absent/508/127`: 1.18084.
- `low/middle/4096/257`: 1.27751.
- `low/end/4096/1024`: 1.18180.
- `near/absent/65536/33`: 1.72347.
- `near/absent/65536/257`: 1.17037.
- `rare/absent/262144/512`: 1.39334.
- `low/middle/262144/33`: 1.76367.

The saved analyses retain every row, interval, noise floor, and outlier label.
The local near-equal result does not replace the earlier c7g result.
The host and libc differ from that fleet campaign.

## Disposition and limits

The parent retained the original few-starts candidate for further tests, not acceptance.
The short packed case motivated the early-packed refinement below.
The original directional-vector candidate is not ready for default use.
Its long-scan gains do not excuse the short-scan regressions.

The observations motivate scalar first-byte checks and an earlier packed return.
They do not prove either latency cause.
Each refinement needs a commit before a new measurement.

The standard corpus measures the bounded path only at `H-N=1`.
It does not select an optimal cutoff between one and sixteen.
Correctness tests cover every legal start through `H-N=16` and both boundary sides.
That correctness evidence does not establish performance for those additional starts.

The early-packed candidate later passed native fleet guards and its separate exact-byte review.
The separate fleet report records its performance disposition.
Raw codegen reports retain their `pending-review` and manual-review labels.
The machine-readable performance verdict remains `not-evaluated`.
This local record grants no cloud authority.

## Evidence paths

The run directories are:

- `bench-results/find-local-20261014/a7ee982298854cf0418d7716845423d96f6282f9/`
- `bench-results/find-local-20261014/1821bf5a648cedd8b3cce6900f952fac2b9a6a5d/`

Each directory contains `manifest.json`, `summary.json`, `analysis.json`, and `raw/`.
The manifests record executable hashes, complete arguments, the schedule, and raw-file hashes.
These directories contain byte-identical copies of the completed private local runs.
The original directories beneath `.bench-cache/find-optimization/` remain unchanged.
No build, proof, sample, or analysis ran again for these copies.

The saved manifests retain their original absolute paths.
The receipt `bench-results/find-local-20261014/copy-receipt.json` records both locations and hashes by relative path.

Additional evidence is below `.bench-cache/find-optimization/`:

- `local-builds/vector-native.json`
- `local-preflight/receipt.json`
- `local-vector-screen.log`
- `local-few-screen.log`
- `local_screen.py`

The candidate executable hashes are:

- Directional vectors: `4c37371e07bfa8f56b2610ad6d47f50fb988f1b8972c8997ed055ca36b30dbf2`.
- Few starts: `59024656cbda93dc5e45c175d4d47b608a82be73ca0bde6f6e959d2cb543ab0e`.

The baseline executable hash is `08d6ebea84346bf5e9c383b87fad16074a9474a5f3e82d6387e0577de360ddcd`.

## Refined candidates

Both refinements passed their full local gate and an independent source review.
The parent measured each new commit in a separate campaign with the same method and fresh baseline/A/A processes.
The completed earlier campaigns were not repeated.
Each new campaign contains 18 valid raw files.
Independent statistics and timed-consumer byte review passed for both refined campaigns.
That review reproduced all 420 primary revision rows and checked all 21 complete timed bodies per candidate.
These checks do not establish a complete kernel proof or fleet acceptance.

| Refinement | Commit | Candidate / baseline | Interval | A/A interval |
|---|---|---:|---|---|
| Scalar heads before directional SIMD | `577ac9ed763181fcb7a682f3ddc8785302fbf83d` | 0.97408 | [0.96967, 0.98049] | [0.99340, 1.00950] |
| Early packed return before long setup | `3656d4593aa7c66373729bcb1e9632384fbf9061` | 0.76509 | [0.75976, 0.77433] | [0.99942, 1.00540] |

The early-packed candidate reduces the local primary geometric-mean latency by about 23.5 percent relative to the baseline.
It has no significant primary revision regression with an interval entirely above 1.10.
The `periodic/absent/64/4` estimate is `0.60076`, with interval `[0.59628,0.60367]`.
Its latency medians are 8.49 ns versus 14.14 ns.
This result selected the early-packed candidate for the later fleet campaign.

The scalar-head candidate has a measurable aggregate benefit in this local campaign.
Two significant primary regressions above ten percent remain:

- `near/absent/65536/33`: `1.79018`, interval `[1.72047,1.83627]`.
- `low/middle/262144/33`: `1.31811`, interval `[1.30067,1.36119]`.

Both regressions involve a 33-byte needle.
The result does not establish their latency cause.
Actual symbol inspection confirms that the directional helpers are inlined into `find.find` in this generic ARM executable.
A separate helper call is not present.
The parent does not accept this vector candidate for default use.

The new run directories are:

- `bench-results/find-local-20261014/577ac9ed763181fcb7a682f3ddc8785302fbf83d/`
- `bench-results/find-local-20261014/3656d4593aa7c66373729bcb1e9632384fbf9061/`

These directories contain byte-identical copies of the completed private campaigns.
The receipt is `bench-results/find-local-20261014/refinement-copy-receipt.json`.
The original directories and their absolute-path manifests remain unchanged.

The new executable hashes are:

- Scalar heads: `e0d8e0d226a7dfd485af7dc5e3cf9b52bd19103340343bbfe632043b125cfdee`.
- Early packed return: `71ff019a6751de304e87c753d6287067d517d67e76d05d95030816ff90390d16`.

A later approval permitted one new seven-target fleet for up to two hours.
It required candidate selection and local gates before launch.
The separate fleet report records those measurements and the exact-ID teardown.
This report contains only local measurements.
All machine-readable fleet performance verdicts remain `not-evaluated`.

## Two-block directional entry

Commit `f9739316289859e02bb0b3e03e7e75ef3b9d4928` requires two complete blocks after the scalar head before SIMD entry.
It retains the existing block loop and scalar tail.
The full local gate and independent source review passed.
Its separate six-round campaign completed with 18 valid raw files.

The local aggregate latency ratio is `0.96251`, with interval `[0.95802,0.96909]`.
This represents about 3.75 percent lower geometric-mean latency than the baseline.
The A/A interval is `[0.99435,1.00374]`.
The campaign has no primary point-estimate regression above ten percent.
It retains 19 smaller significant primary regressions in the complete analysis.

The two previously problematic cases now have these estimates:

- `near/absent/65536/33`: `0.98005`, interval `[0.97297,1.02632]`.
- `low/middle/262144/33`: `1.01078`, interval `[0.99485,1.01596]`.

The `rare/absent/262144/1024` estimate is `0.20866`, with interval `[0.20550,0.21079]`.
These results support another local experiment, not an isolated latency explanation or a universal regression ceiling.
Independent statistics and native timed-consumer byte review passed for this retained campaign.
Six primary intervals still extend above 1.10.

The run directory is `bench-results/find-local-20261014/f9739316289859e02bb0b3e03e7e75ef3b9d4928/`.
The receipt is `bench-results/find-local-20261014/two-block-copy-receipt.json`.
The executable hash is `7fb8e02abaead0a5921225c585d1c0f356d42f74ab7531c3176ad16aa8b373b1`.
The original campaign remains unchanged.

## Combined experiment

The parent combined the early-packed and two-block sources in a separate worktree.
The public entry matches the early-packed candidate exactly.
The directional helpers and Two-Way body match the two-block candidate exactly.
All 15 existing tests retain their original bodies and expectations.
No new kernel policy is present.

The combined source review and all requested local gates passed.
The parent committed the reviewed bytes as `673373822932805cedd756be1d31475824122839`.
The source hash is `6800158249fd97db01eca7555b1964ecfde2eb4d370ea93e2e51040b2d71077b`.
A separate campaign used the early-packed candidate as its baseline, with fresh baseline, candidate and A/A processes.
All 18 raw files passed the strict driver checks.
Independent statistics and native timed-consumer review passed for this campaign.
The review preserves all round-two outliers and all nine material losses.

The incremental latency ratio is `0.97512`, with interval `[0.96896,0.98226]`.
The A/A ratio is `0.99930`, with interval `[0.99156,1.01570]`.
The additional geometric-mean latency reduction is about 2.49 percent.
Nine significant primary regression intervals lie wholly above 1.10:

| Runtime case | Ratio | Interval |
|---|---:|---|
| `rare/end/513/512` | 1.35251 | [1.34508,1.36012] |
| `rare/end/1025/1024` | 1.34270 | [1.33236,1.61304] |
| `rare/end/4097/4096` | 1.32278 | [1.32047,1.63665] |
| `random/end/2/1` | 1.13447 | [1.12516,1.14007] |
| `random/end/3/1` | 1.12444 | [1.11288,1.14013] |
| `prefix/absent/4096/257` | 1.14918 | [1.14567,1.15485] |
| `prefix/absent/65536/257` | 1.22903 | [1.18069,1.25226] |
| `prefix/absent/65536/1024` | 1.23265 | [1.18498,1.24129] |
| `prefix/absent/65536/4096` | 1.18266 | [1.16698,1.20290] |

The parent rejects this combination for integration in this round.
The additional aggregate gain does not justify these unresolved regressions.
The three near-equal cases return before Two-Way in the source.
That fact does not isolate an elapsed-time cause.
The selected fleet candidate remains the early-packed commit `3656d4593aa7c66373729bcb1e9632384fbf9061`.

The run directory is `bench-results/find-local-20261014/compare-673373822932805cedd756be1d31475824122839-vs-3656d4593aa7c66373729bcb1e9632384fbf9061/`.
The receipt is `bench-results/find-local-20261014/combined-copy-receipt.json`.
The executable hash is `f6fb03b8ef99086e7cca2c69bd7dddcbdba8a9bfbaf14c693086420a61e9b075`.
The combined commit, original campaign and raw labels remain unchanged.
Six local campaigns contain 108 valid raw files.
Independent raw, statistical and native timed-consumer review passed for all six campaigns.
Canonical copies are not additional observations.
