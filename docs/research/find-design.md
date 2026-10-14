# Subslice search design research

## Decision

Use a minimal forward-search port of Rust `memchr::memmem` as the first implementation candidate.
Select its MIT license option.
Keep the generic `std.mem.find` signature and optimize runtime `u8` input first.
This decision selects an implementation reference, not a performance winner.
Fleet measurements must establish the result.

The upstream pin is `bd6068c30e9074a90c285e47912fa0b047d07597`.
Its [Cargo manifest][cargo] identifies version 2.8.3 and `Unlicense OR MIT`.
Its [MIT license][license] names Andrew Gallant, copyright 2015.
Every derivative file must identify its upstream files and commit.
The port must retain the permission notice and appear in `THIRD_PARTY.md`.

## Zig precedent

Zig 0.16 provides `std.mem.find(comptime T: type, haystack: []const T, needle: []const T) ?usize`.
It returns the first element index, zero for an empty needle, and `null` for absence.
The pinned source is `lib/zig/std/mem.zig:1419–1421,1536–1561` in the flake toolchain.
The public fastmem entry uses that signature.
No compiler builtin, compiler-rt entry, or libc export is necessary.

The stdlib uses scalar-element search for a one-element needle.
It uses linear search for short haystacks, short needles, or types without a unique representation.
Larger inputs use byte-based Boyer–Moore–Horspool with a `[256]usize` table.
The thresholds are 52 haystack elements and more than four needle elements.
Source: `std/mem.zig:1486–1497,1536–1561`.

Generic equality is not always byte equality.
Floats, padding, zero-sized types, and comptime types require their original semantics.
The stdlib also accepts identical pointers before element comparison, which matters for aliased NaN input.
Its multibyte search rejects unaligned byte matches and continues to later aligned matches.
Sources: `std/mem.zig:732–752,1547–1561,1589–1615`.

The initial generic and comptime paths therefore delegate to stdlib.
The optimized byte path needs a separate correctness and complexity argument.
A byte-path guarantee does not apply to that generic fallback.

## Upstream algorithm portfolio

The [one-shot entry][entry] uses Rabin–Karp directly for haystacks shorter than 64 bytes.
This avoids construction of the larger search state.
The [strategy selector][searcher] uses internal byte search for one-byte needles.
It uses complete SIMD packed-pair search for needles of 2–32 bytes.
Other needles use Two-Way search, with a SIMD prefilter when available.

The port needs these internal components:

| Component | Pinned upstream source |
|---|---|
| One-shot policy | `src/memmem/mod.rs` |
| Strategy and adaptive state | `src/memmem/searcher.rs` |
| Tiny-input hash | `src/arch/all/rabinkarp.rs` |
| Critical factorization and search | `src/arch/all/twoway.rs` |
| Pair selection | `src/arch/all/packedpair/mod.rs` |
| Static byte ranks | `src/arch/all/packedpair/default_rank.rs` |
| Vector search and tails | `src/arch/generic/packedpair.rs` |
| Vector and mask semantics | `src/vector.rs` |
| Exact internal equality | `src/arch/all/mod.rs` |
| Internal forward byte search | Relevant portions of `src/arch/all/memchr.rs` and ISA-specific helpers |

Every path refers to the [same complete upstream tree][tree].
The port does not need public prepared finders, ownership conversions, reverse search, or iterators.
Rust union/function-pointer machinery does not define the search algorithm.
Zig can use target specialization where it preserves the selected behavior.

### Pair selection and bounded loads

The [pair selector][pair] uses static background frequency ranks, not a haystack histogram.
It selects distinct offsets, but the byte values can be equal.
Automatic selection examines offsets 0–254.
Longer needles remain valid because the pair is only a necessary match predicate.
A rare byte outside that prefix can reduce selectivity, not correctness.

The [generic vector search][vector-search] distinguishes candidate search from complete search.
Its two shifted vector loads must fit the input before any result mask applies.
Its minimum haystack length is `max(needle.len, max(pair_offsets) + vector_width)`.
Complete search checks the remaining needle length before verification.
Candidate search can return a position too close to the end, which Two-Way must reject.

Candidate enumeration must preserve increasing start positions.
Complete-search tails mask previously examined candidates.
Prefilter tails have a different absence invariant.
A result mask cannot make an out-of-bounds load safe.

### Two-Way search

The [Two-Way implementation][twoway] computes a critical split and period-related state from the needle.
It uses different paths for small and large periods.
The small-period path retains verified overlap after shifts.
The port must preserve suffix tie rules, mismatch shifts, and periodic memory.

Its approximate byte set folds byte values into 64 classes.
An absent candidate-tail class permits a whole-needle skip.
A present class only means that the byte can occur in the needle.
Collisions cannot justify a skip.
This test remains useful after the SIMD prefilter becomes inactive.

[Crochemore and Perrin][paper] provide the constant-space linear-time foundation.
Production port details come from the permissively licensed memchr source, not paper pseudocode.
No new algorithm replaces these invariants in the first candidate.

### Adaptive prefilter

The [adaptive state][searcher] tracks prefilter displacements within one search.
It tries 50 actual skips before it can disable the prefilter.
It then requires an average displacement of eight bytes.
Zero-displacement candidates count toward the decision.
A disabled prefilter remains inactive for the rest of that call.

The counters use saturating updates.
The port must widen the threshold multiplication to avoid overflow at large counter values.
That change is an explicit arithmetic safety adaptation.
It does not replace the upstream effectiveness policy with a new work budget.

### Complexity boundaries

The complete packed-pair path verifies at most 32 bytes per candidate.
That fixed cap bounds its worst-case verification cost.
The length-33 path must not become unbounded pair-plus-whole-needle verification.
Source: the rationale in `do_packed_search` in the [strategy source][searcher].

Rabin–Karp needs exact confirmation after a hash match.
Its rolling arithmetic wraps explicitly.
The public tiny-haystack threshold bounds its adversarial work.
The port must not extend that fallback to arbitrary haystack lengths without a separate argument.
Source: [Rabin–Karp implementation][rabinkarp].

## ISA policy

The upstream fidelity baseline uses SSE2, AVX2, and aarch64 NEON.
The [AVX2 facade][avx2] falls back to SSE2 when its wider minimum window does not fit.
It does not always jump directly from AVX2 to a scalar tail.
NEON preserves its native syndrome-mask semantics rather than an assumed x86 movemask layout.

AVX-512 and SVE substring kernels remain benchmark challengers.
The widest vector is not an established winner.
A baseline x86 build can reuse fastmem's CPU detection and target-specific objects.
It must not execute an unsupported vector constructor before it selects a safe fallback.
Copy, move, and set policies remain unchanged.

## Alternatives considered

| Source | Finding | Port status |
|---|---|---|
| [LLVM libc][llvm] | The inspected `inline_memmem.h` uses brute force and marks optimization as future work. | Permissive, but not the primary performance reference. |
| [Arm Optimized Routines][aor] | The inspected aarch64 directories provide byte-search mechanisms, not a complete substring-search portfolio. | Permitted source, with per-file notices. |
| [musl][musl] | Short scalar windows and Two-Way search use larger byte-indexed metadata. | MIT candidate for later comparisons. |
| [Arm-authored newlib][newlib] | A bounded pair-hashed medium path uses a small table. | The caller file is BSD-3-Clause. Its separate Two-Way header needs a separate license check. |
| [Muła SIMD examples][mula] | Pair filters cover several ISAs, but some examples permit overreads. | BSD-2-Clause mechanisms, not bounds-safe drop-in code. |

No code derives from glibc.
Its independently observed behavior appears in [find-glibc.md](find-glibc.md).

## Measurement questions

The first benchmark must measure the faithful port with one-shot setup inside each call.
It must separate direct userland calls from equal-overhead indirect calls.
Fixed needle contents and fixed needle lengths need distinct cases.
No claim can treat bytes after an early match as searched bytes.

Adversarial cases must include these families:

- Uniform and short-period data.
- Long near-matches with dense pair survivors.
- A long needle with its only rare byte after offset 254.
- A saturated approximate byte set.
- Very few legal starts with a large needle.
- False candidates immediately before the final true match.
- Scalar, SIMD, and algorithm threshold boundaries.

Later experiments can compare these alternatives independently:

- Selector policy and prefix/suffix samples.
- Local equality shapes.
- Prefilter enabled versus disabled.
- Compact byte sets versus larger shift tables.
- SIMD widths and loop unroll factors.

The benchmark contract and acceptance criteria are in [find-plan.md](../find-plan.md).
No performance superiority is established by this research.

[cargo]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/Cargo.toml
[license]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/LICENSE-MIT
[tree]: https://github.com/BurntSushi/memchr/tree/bd6068c30e9074a90c285e47912fa0b047d07597
[entry]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/memmem/mod.rs
[searcher]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/memmem/searcher.rs
[pair]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/all/packedpair/mod.rs
[vector-search]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/generic/packedpair.rs
[twoway]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/all/twoway.rs
[rabinkarp]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/all/rabinkarp.rs
[avx2]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/x86_64/avx2/packedpair.rs
[paper]: https://doi.org/10.1145/116825.116845
[llvm]: https://github.com/llvm/llvm-project/blob/main/libc/src/string/memory_utils/inline_memmem.h
[aor]: https://github.com/ARM-software/optimized-routines/tree/master/string/aarch64
[musl]: https://git.musl-libc.org/cgit/musl/plain/src/string/memmem.c
[newlib]: https://github.com/mirror/newlib-cygwin/blob/master/newlib/libc/string/memmem.c
[mula]: https://github.com/WojciechMula/sse4-strstr
