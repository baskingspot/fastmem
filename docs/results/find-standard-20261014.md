# Subslice search: 2026-10-14

The measured candidate passes the aggregate goal on all seven CPUs and their portable builds.
This is not a universal speedup: the worst primary case is **18.584237 times slower** than stdlib.
The initial port retains the regressions below, with explicit limits and follow-up experiments.

## Source and runs

Measured source: `8bb798790829082f981e3b1830b7216ccf86381e`.
References: Zig 0.16.0 `std.mem.find` and the independently resolved host glibc `memmem`.
The byte kernel ports Rust memchr 2.8.3 under MIT terms.
`THIRD_PARTY.md` records upstream commit `bd6068c30e9074a90c285e47912fa0b047d07597` and its notice.
No implementation comes from glibc source or transcribed instructions.

- Target builds: `bench-results/20261014T181738Z-find-target-standard`.
- Portable builds: `bench-results/20261014T182414Z-find-baseline-standard`.
- Machine results and executable hashes: [find-standard-20261014.json](find-standard-20261014.json).
- Complete significant fastmem regressions: [find-standard-20261014-regressions.tsv](find-standard-20261014-regressions.tsv).

Each campaign uses these parameters:

- Six independent processes per variant.
- Ten samples per process.
- A two-millisecond sample target.
- Seed one.

The inventory contains 210 runtime cases and nine fixed cases, with 1,068 timed cells per sample.
Every timed call includes needle setup.
A/A reuses the exact baseline executable and command.
These are equal-case stress weights, not estimates of application frequencies.

## Results

Each ratio is fastmem/reference nanoseconds per call.
Below one favors fastmem.
The primary comparison is direct runtime calls against stdlib.
The glibc comparison uses the common indirect C-ABI boundary for both implementations.
Fixed needles remain a separate comparison in the machine results.

| CPU | Target / stdlib | Portable / stdlib | Target / glibc, indirect | Portable / glibc, indirect |
|---|---:|---:|---:|---:|
| c7i, Sapphire Rapids | 0.144501 | 0.174301 | 0.301805 | 0.323848 |
| c8i, Granite Rapids | 0.137988 | 0.162720 | 0.304601 | 0.320933 |
| c7a, Zen 4 | 0.136567 | 0.160424 | 0.329361 | 0.330198 |
| c8a, Zen 5 | 0.136318 | 0.146569 | 0.299096 | 0.293976 |
| c7g, Neoverse V1 | 0.181004 | 0.248165 | 0.483253 | 0.549611 |
| c8g, Neoverse V2 | 0.158904 | 0.212677 | 0.422741 | 0.488981 |
| c9g, Neoverse V3 | 0.161445 | 0.215597 | 0.431012 | 0.490104 |

All six per-round primary geometric means also remain below one for every build.
Target and portable campaigns occur separately, so their difference does not establish a causal effect of dispatch.

## Confidence and provenance

The estimator uses per-round medians and log-ratio Hodges–Lehmann estimates.
Implementation intervals have exact signed-rank coverage of 96.875 percent.
Independent A/A intervals have coverage of 95.887445887 percent.
Sixty samples are not sixty independent rounds.
Outliers remain in the analysis.
The intervals have no simultaneous multiplicity correction.

Each noise floor uses the 95th percentile of absolute log A/A ratios for its exact length pair and runtime/fixed path.
A significant effect must clear the larger of that floor and the configured minimum effect, which is zero here.
Three source-listed regressions clear ten percent but not their measured noise floors.
The companion TSV excludes those rows.
Four additional primary point estimates exceed ten percent without confidence of an effect above ten percent.
The report does not claim those marginal effects.

Independent review reproduced all 14 saved analyses from 168 raw round files.
The parent checked every actual executable hash against the accepted nine-configuration proof.
The parent also checked these retained records:

- Source identities and exact A/A reuse.
- Commands and owned instance IDs.
- Topology and isolation selection.
- glibc resolution evidence.

The retained isolation protocol is `systemd-cpuset-taskset-v1`.
Intel reserves CPU 1 and excludes sibling 3 from housekeeping.
AMD and ARM reserve CPU 3.

The accepted proof is `.bench-cache/find-guarded-proof/8bb7987/`.
Its independent manual acceptance applies to these exact bytes.
Original sidecars still state `pending-review` or `manual-review-required`.
Original summaries still state `performance_verdict: not-evaluated`.
Those labels alone do not establish acceptance.
This report records the separate parent disposition.

## Regressions and disposition

There are 529 significant primary regressions across target/build/case combinations, not 529 unique inputs.
The TSV contains all 1,996 significant fastmem comparison regressions, with ratios, intervals, noise floors, and dispositions.
It separates direct/stdlib, indirect/stdlib, indirect/glibc, and fixed/stdlib comparisons.
Call-boundary comparisons and stdlib/glibc comparisons do not enter that count.

| Primary case family | Count | Initial-port disposition |
|---|---:|---|
| Tiny haystacks | 156 | Retain scalar equality and bounded Rabin–Karp costs below 64 bytes. |
| Packed short needles | 26 | Retain pair selection and complete verification for needles through 32 bytes. |
| Early long matches | 98 | Retain one-shot factorization and scalar verification before the first match. |
| Long needles with near-equal lengths | 42 | Retain setup costs when only a few candidate positions exist. |
| Rare-byte absence | 41 | Retain the first-255-byte pair selection and scalar Two-Way verification. |
| Dense near-match absence | 55 | Retain the upstream adaptive filter and its measured scalar verification costs. |
| Other Two-Way cases | 104 | Retain scalar verification and setup in the remaining long-needle paths. |
| Single-byte runtime cases | 7 | Retain 16/32-byte vectors and the scalar tail. |

These are accepted tradeoffs for the initial candidate, not claims that the cases improved.
No model-specific policy changes enter without new measurements.
The implementation does not claim to replace every stdlib search with a faster operation.

The worst primary row is portable c7g `rare/end/4097/4096`: **18.584237**, interval **[18.513346, 18.611036]**.
Its median times are 36,115.459091 ns versus 1,943.719853 ns.
Target c8a `rare/absent/262144/1024` reaches **14.302614**, interval **[14.138063, 14.417406]**.
The worst indirect/glibc row is portable c9g `periodic/start/4096/127`: **14.837949**, interval **[14.670604, 15.027835]**.
Fixed regressions occur only in `text/end/4096/1`.
Their worst ratio is target c8a **1.978609**, interval **[1.900845, 2.015260]**.

## Untimed diagnosis

The parent instrumented copies of the unchanged kernel, not the measured binaries.
The 262 controls cover these deterministic benchmark profiles:

- Rare-byte needles.
- Prefix matches.
- Dense near matches.

Separate byte controls vary length and alignment.
Logical vector widths are 16 and 32 bytes.
These counts are not instruction counts, ISA timings, or a universal complexity proof.
The original 256 controls and six added equal-length controls ran separately.

For a 4,096-byte prefix match, setup ranks 255 bytes, makes 8,190 suffix comparisons, and scans 4,096 bytes for the byteset.
The match then needs 4,096 scalar verification comparisons.
A rare match at offset one needs 8,490 suffix comparisons and another 4,096 scalar verification comparisons.
At equal lengths, the existing shortcut instead needs 256 or 128 vector comparisons, with no factorization or byteset setup.
These controls expose extra setup and scalar verification work near equal lengths.
They do not isolate its contribution to elapsed time.

Rare absence with a 262,144-byte haystack and 1,024-byte needle needs 247,608 scalar verification comparisons.
The width-32 filter also evaluates 2,729 vector blocks.
The pair cannot select the rare byte at needle offset 300 because it inspects only offsets zero through 254.
The scalar verification work remains below twice the haystack length throughout the tested rare and near-match grids.
The tested grids show substantial scalar work.
They do not demonstrate superlinear growth or establish an asymptotic bound.

No control erases nonzero Two-Way memory at a filter reset.
That proposed cause does not explain these reproduced slow cases.
The 257-byte near-match control disables the filter after 50 attempts.
At both widths, the 4,096-byte needle also disables the filter after 50 attempts for these haystack lengths:

- 131,072 bytes.
- 262,144 bytes.
- 1,048,576 bytes.

At 65,536 bytes, that needle stays active because it makes only 31 attempts.
The 33-byte and 1,024-byte controls retain an active filter when their skip average clears the upstream threshold.

A 4,096-byte single-byte scan needs 256 width-16 blocks or 128 width-32 blocks at every tested alignment.

The next bounded experiments are vectorized directional verification, a bounded near-equal-length path, and model-specific byte-search widths.
None is an unmeasured change in this candidate.
The remaining long-needle rows retain their scalar search paths without an asserted unique cause for each input.

Counter data: [find-standard-20261014-diagnostics.jsonl](find-standard-20261014-diagnostics.jsonl).
The [instrumentation patch](find-standard-20261014-diagnostics.patch) changes only ignored diagnostic copies.
The machine report records source, patch, and probe hashes.

### Reproduce the counters

1. Check the source hashes against the machine report.
2. Create `.bench-cache/find-regression-diagnostics/find/`.
3. Copy `src/find.zig` to `.bench-cache/find-regression-diagnostics/kernel.zig`.
4. Copy `src/find.zig` to `.bench-cache/find-regression-diagnostics/kernel32.zig`.
5. Copy `src/find/rank.zig` into the new `find/` directory.
6. Run `git apply --unidiff-zero docs/results/find-standard-20261014-diagnostics.patch`.
7. Run `nix develop -c zig run -O ReleaseSafe .bench-cache/find-regression-diagnostics/probe.zig`.
8. Run `nix develop -c zig run -O ReleaseSafe .bench-cache/find-regression-diagnostics/probe_equal.zig`.

## Correctness and cleanup

Correctness combines 30 unchanged configurations from `bench-results/20261014T104610Z-find-test` with 12 changed baseline configurations from `bench-results/20261014T180057Z-find-dispatch-test`.
The changed configurations pass ReleaseFast, ReleaseSafe, and Debug, with 25,846,992 full-matrix calls.
Prior guards, fuzz, source review, and executable equivalence support the unchanged paths.
The byte path remains allocation-free and libc-free, with reads inside the supplied slices.
Generic and comptime calls preserve stdlib semantics.
Memory-operation policies and exported symbols remain unchanged.

The parent terminated only the seven owned replacement instances.
The final exact-ID AWS query at **2026-10-14T18:48:28Z** reports all seven as terminated.
Account: `396684171460`. Region: `us-west-2`.
The cleanup receipt is `.bench-cache/find-replacement-teardown.json`.
The authorization for this experiment includes no replacement launch or lease extension.
