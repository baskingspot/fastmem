# Subslice search: bounded starts, 2026-10-15

The parent accepts `3656d4593aa7c66373729bcb1e9632384fbf9061` with the explicit regressions below.
It reduces aggregate latency against the previous fastmem implementation on all fourteen host/build combinations.
The observed reductions range from 12.198 to 24.262 percent.
This result does not establish a per-case or application-weighted speedup.
The worst primary stdlib comparison remains **14.030460 times slower**.

## Source and evidence

The baseline is `8bb798790829082f981e3b1830b7216ccf86381e`.
The selected source adds an initial long comparison and a bounded candidate search.
It returns short packed searches before long-needle setup.
The existing guards retain their order.
The bounded path checks at most 17 starts in ascending order.
The remaining long path performs one initial comparison before the existing Two-Way algorithm.

All private production helper sources remain identical to the baseline:

- Equality.
- Byte search.
- Rabin–Karp.
- Pair selection.
- Packed search.
- Two-Way.

Source identity does not establish generated-code identity or isolate an elapsed-time cause.

The x86 search vector policy remains SSE2 or AVX2.
The ARM policy remains NEON.
No new AVX-512 or SVE selection enters.

Generic and comptime calls retain stdlib semantics.
Memory-operation policies and exported symbols remain unchanged.
The byte kernel needs no allocator or libc.

The retained evidence includes:

- Target: `bench-results/20261015T002751Z-find-early-target-standard`.
- Portable: `bench-results/20261015T002752Z-find-early-baseline-standard`.
- Correctness: `bench-results/20261015T001331Z-find-selected-test`.
- [Machine results and executable identities](find-early-standard-20261015.json).
- [Every material selected-fastmem regression and disposition](find-early-standard-20261015-regressions.tsv).
- [The six local experiments](find-local-20261014.md).

The selected `src/find.zig` SHA-256 is `326f486ae21e069251b3323592066314105f929925291f8f6fcbb10d11f5d53e`.
Only `src/find.zig` differs from the experiment base `def61b90c62358e5ab05e69dc9b01af9ae393ea1`.
The Rust memchr attribution and MIT notice remain in `THIRD_PARTY.md` and the source.
Rust is not a measured reference.

## Method and validation

Each host/build campaign uses these parameters:

- Six independent processes per baseline, selected source and exact baseline A/A duplicate.
- Ten samples per cell, with a two-millisecond sample target and one-millisecond warmup.
- The balanced six-order schedule and seed one.
- All 219 cases: 210 runtime cases and nine separate fixed cases.
- All 1,068 timed cells per sample.

The runtime geometric means give every stress case equal weight.
These weights do not represent application frequencies.
Each timed call includes needle setup.
The glibc comparison uses the common indirect C-ABI boundary.
The primary stdlib comparison uses direct runtime calls.

The parent reuses proven build prefixes through symlinks.
The original commands, sidecars and executable bytes remain unchanged.
The standard validators pass before samples.
No build or byte proof repeats for this reuse.

Independent review checks all 252 new raw files.
It parses 2,691,360 sample records and reproduces all 65,436 saved comparison rows.
It also reproduces every aggregate.
Noise floors and outlier flags match.

All eighteen distinct baseline/selected executable hashes match their accepted matrices.
The nine selected executable configurations retain their separate source and byte review authorities.
The selected kernel does not inherit the original kernel's correctness acceptance.

## Results

Every value below is a latency ratio.
Below one favors selected fastmem.
The stdlib columns use geometric means of per-case paired ratios.
The selected/old columns compare the six independent process latency geometric means.
These are different estimators.

| CPU | Target / stdlib | Portable / stdlib | Target selected / old | Portable selected / old |
|---|---:|---:|---:|---:|
| c7i, Sapphire Rapids | 0.114197 | 0.143460 | 0.803558 | 0.782492 |
| c8i, Granite Rapids | 0.112466 | 0.137824 | 0.812008 | 0.825288 |
| c7a, Zen 4 | 0.107551 | 0.145779 | 0.786675 | 0.878021 |
| c8a, Zen 5 | 0.105243 | 0.125874 | 0.760909 | 0.803901 |
| c7g, Neoverse V1 | 0.143987 | 0.191136 | 0.797241 | 0.766705 |
| c8g, Neoverse V2 | 0.127161 | 0.160183 | 0.794987 | 0.757383 |
| c9g, Neoverse V3 | 0.127830 | 0.163411 | 0.787527 | 0.762493 |

Every selected/old aggregate interval lies below one.
Every one of the six primary round means also remains below stdlib for each host/build.
Target and portable observations occur sequentially.
Their differences do not isolate dispatch causality.
The machine report retains all process vectors and intervals.

The target primary stress means correspond to about 6.9–9.5 times the stdlib rate.
The portable means correspond to about 5.2–7.9 times the stdlib rate.
These reciprocal ratios do not predict application throughput.

| CPU | Target / glibc, indirect | Portable / glibc, indirect | Target fixed / stdlib | Portable fixed / stdlib |
|---|---:|---:|---:|---:|
| c7i | 0.247154 | 0.253233 | 0.164436 | 0.192451 |
| c8i | 0.250476 | 0.260768 | 0.157785 | 0.177990 |
| c7a | 0.268473 | 0.290438 | 0.193400 | 0.232316 |
| c8a | 0.235173 | 0.239750 | 0.190422 | 0.176973 |
| c7g | 0.390141 | 0.430627 | 0.328350 | 0.351138 |
| c8g | 0.336245 | 0.372264 | 0.241014 | 0.263763 |
| c9g | 0.341736 | 0.379560 | 0.243071 | 0.272296 |

### The previous near-equal slowdown

Portable c7g `rare/end/4097/4096` now measures 247.572441 ns versus stdlib's 1,934.667706 ns.
Its selected/stdlib ratio is `0.127937`, with interval `[0.127329,0.130220]`.
The fresh old-fastmem control measures 36,089.939276 ns.
The selected/old ratio is `0.006866`, with interval `[0.006822,0.006973]`.
The historical 18.584237 slowdown remains unchanged in the [original report](find-standard-20261014.md).
Both stdlib comparisons use Zig 0.16.0, not Rust.

The standard corpus exercises the bounded path only at `H-N=1`.
Correctness through difference sixteen does not select an optimal performance cutoff.

## Regressions and parent disposition

The parent retains all **501 significant primary intervals wholly above 1.10** as explicit tradeoffs.
There are 389 selected/stdlib rows and 112 selected/old-fastmem rows.
Counts preserve distinct hosts, build modes and comparisons, not unique input strings.
The TSV also includes indirect and fixed losses, for 1,834 selected-fastmem rows in total.

| Semantic entry path | Primary losses / stdlib | Primary losses / old fastmem | Bounded investigation |
|---|---:|---:|---|
| Tiny Rabin–Karp | 161 | 6 | The branch and helper source remain unchanged. |
| Packed short needle | 17 | 74 | The entry returns before long setup. Helper source remains unchanged. |
| Equal lengths | 1 | 11 | The guard and equality helper source remain unchanged. |
| Single byte | 7 | 3 | The branch and vector/tail helper source remain unchanged. |
| Initial comparison and Two-Way | 203 | 18 | The entry adds one equality check before unchanged helper algorithms. |

No material primary loss occurs in the new bounded-start or initial-long-match path.
This observation does not establish a ceiling outside the corpus or confidence intervals.
The existing [untimed controls](find-standard-20261014.md#untimed-diagnosis) describe baseline helper work.
They do not measure the new candidate or establish its elapsed-time causes.
Additional call sites can change generated code despite identical helper sources.
The cause of each individual timing loss remains unresolved.

The parent accepts these losses because all fourteen aggregate goals pass with substantial measured improvements against the old implementation.
The acceptance uses the documented stress weights, not a claim that each input improves.
No target's aggregate requires retention of the old policy.
The source does not add a model-specific exception without measurements.

Important retained losses include:

- Target c8a `rare/absent/262144/1024`: `14.030460` versus stdlib, interval `[14.007715,14.065481]`.
- Portable c8a for the same input: `10.821605` versus stdlib, interval `[10.779032,10.902712]`.
- Portable c8i `text/end/31/3`: `1.620753` versus old fastmem, interval `[1.618213,1.623477]`.
- Target c8i for that tiny input: `1.592959` versus old fastmem, interval `[1.555187,1.597807]`.
- Portable c7a retains 65 material primary revision losses despite a `0.878021` aggregate selected/old ratio.

Each TSV row contains measured latencies and intervals.
It also contains noise floors and outlier indices.
The row records its semantic-path investigation and parent disposition.
The original rare-absence and scalar-verification limitations remain open optimization targets.
They are not corrected by this entry change.

The combined SIMD experiment remains rejected for this round.
Its local aggregate improves another 2.49 percent, but nine material losses include 32–35 percent near-equal regressions.
The selected change instead improves every fleet aggregate by 12–24 percent.
Neither decision implies a universal regression threshold or a causal explanation.
All six local campaigns and their 108 raw files remain intact.

## Uncertainty, references and isolation

The independent intervals have exact coverage of 95.887445887 percent.
The paired case intervals have coverage of 96.875 percent.
Six processes are six independent rounds, not sixty independent observations.
No simultaneous multiplicity correction applies.

Every aggregate A/A interval includes one.
The analysis retains 4,144 cell/round outlier flags and all flagged observations.
Some individual floor groups reach 43.0112 percent.
The analysis does not replace those floors with the tighter aggregate A/A interval.
There are 644 selected-primary upper interval bounds above 1.10, including unresolved intervals.
Five threshold-only regression rows fail their actual floor.
The significant-regression TSV excludes those rows.
The machine report preserves the count without a false significance claim.

Fleet glibc is `2.40-224`, separate from local glibc `2.42-84`.
Every new probe and raw agrees on the library path and base.
The `memmem` offset and executable exclusion also agree.
Matching cached ELF metadata identifies an ordinary `FUNC`, not an `IFUNC`.
The protocol records no fresh remote libc hash or Build-ID.
Cached file identity is not a new remote cryptographic attestation.
No glibc implementation instructions or source enter the kernel.

The retained isolation method is `systemd-cpuset-taskset-v1`.
Intel reserves the core with logical CPUs 1 and 3 and samples on CPU 1.
AMD and ARM reserve CPU 3.
Protocol records show the isolation lifecycle and restoration.
They do not provide a continuous scheduler trace.
They also do not provide continuous IRQ or frequency traces.

Original codegen sidecars retain `pending-review` and `manual-review-required`.
Producer summaries retain `performance_verdict: not-evaluated`.
This report supplies the separate exact-byte parent disposition without a raw-label change.

## Correctness and cleanup

All 42 selected native configurations pass the three optimization modes.
The full guard matrix completes 90,464,472 calls across the seven new hosts.
The modes are:

- ReleaseFast.
- ReleaseSafe.
- Debug.

The selected source also passes these retained local gates:

- Full tests.
- Lint.
- Cross-endian tests.
- Fuzz tests.

The parent does not repeat unchanged successful gates.

The parent terminated only the seven new exact owned instance IDs.
The final AWS query at **2026-10-15T00:49:16Z** records all seven as terminated, with no active owned IDs.
The account is `396684171460`, in `us-west-2`.
The single approved fleet authority is consumed.
No extension or replacement occurred.
The parent adopted no old instance and changed no infrastructure.
The original fleet's journals, evidence and termination receipts remain unchanged.
