# Subslice search

## Mission

Add a fast userland replacement for Zig 0.16 `std.mem.find`.
The byte path must compete with both the standard library and glibc `memmem`.
The operation needs no compiler builtin, compiler-rt replacement, or libc symbol export.

## Public contract

The entry point is `fastmem.find(comptime T: type, haystack: []const T, needle: []const T) ?usize`.
It returns the element index of the first match, or `null` when no match exists.
An empty needle matches at index zero.
A needle that exceeds the haystack length never matches.
The function permits overlap between the input slices and never writes either input.

The initial optimized path targets `u8`.
Other element types retain `std.mem.find` semantics through a standard library fallback.
Comptime calls must work.
The function needs no allocator or libc dependency.
All reads must stay within the supplied slices, not just within mapped pages.

`exportSymbols()`, the existing C-ABI entries, and the copy, move, and set policies remain unchanged.
A private benchmark wrapper can use the C ABI for a fair call-overhead comparison with glibc.
The public API does not expose that wrapper.
A reusable finder, reverse search, and `findPos` are outside the initial scope.

## Research contract

Rust `memchr::memmem` is the primary design candidate.
The upstream project offers MIT or Unlicense terms: <https://github.com/BurntSushi/memchr>.
An attributed forward-search port takes precedence over a new algorithm stack when its design fits this repository.
The port uses upstream commit `bd6068c30e9074a90c285e47912fa0b047d07597` and preserves its MIT notice.
The source and algorithm inventory appears in [find-design.md](research/find-design.md).
The binary behavior investigation appears in [find-glibc.md](research/find-glibc.md).
Reverse search and iterator APIs remain outside the initial scope.

Algorithm research covers these tactics:

- Packed comparisons for short needles.
- SIMD candidate filters with two selected bytes.
- Needle preprocessing costs and byte selection.
- Skip tables and bounded Horspool search.
- Two-Way search and worst-case linear fallback.
- Fixed needles and compile-time specialization.

Research notes cite primary sources and licenses.
Permitted ports retain upstream attribution and update `THIRD_PARTY.md`.
The glibc investigation extracts behavior from the resolved fleet binaries.
Raw glibc binaries and disassembly stay under `.bench-cache/glibc/`.
No implementation derives from glibc code or transcribed instructions.

## Correctness contract

An independent byte loop defines the byte-path test oracle.
Generic tests preserve stdlib equality behavior, including its identical-pointer shortcut for aliased NaN input.
Tests cover these cases:

- Empty inputs, oversized needles, and single-element needles.
- First matches at the start, middle, and final legal position.
- Multiple and overlapping matches.
- Embedded zero bytes and every byte value.
- Uniform, periodic, and near-match inputs.
- Needle lengths around scalar and SIMD boundaries.
- Independent haystack and needle alignments.
- Guard pages before and after both input slices.
- Read-only input pages and shared input storage.
- Generic element types and comptime calls.
- Differential fuzz input with independent lengths and offsets.

Guard tests run on all seven fleet CPUs and their portable builds.
ReleaseFast, ReleaseSafe, and Debug must pass.
Codegen checks must reject external search delegation and out-of-line libc comparison calls in the optimized byte path.
Existing tests, export checks, lint, and shipped binaries must still pass.

## Measurement contract

Search measurements use a separate binary and record format.
They do not change the existing memory-operation schema or its acceptance rules.
The harness reuses fleet transport, CPU isolation, provenance, round schedules, and exact statistical estimators.
The existing `bench watch` command monitors every fleet measurement run.

Each timed call includes one-shot needle setup.
The references are pinned Zig 0.16 `std.mem.find` and `memmem` from the host libc.
The binary proves the glibc library path, base address, and symbol offset.
Every implementation must return the independently computed answer before measurement.
A result-dependent checksum prevents dead-code elimination.
No throughput claim counts bytes beyond the first match as searched bytes.

The suite varies these dimensions:

- Haystack and needle lengths.
- Match position and absence.
- Random bytes, text, low-entropy data, and adversarial periodic data.
- Independent pointer alignments.
- Runtime needles and fixed needles.

Each accepted result uses at least five rounds and includes an A/A duplicate.
Reports retain outliers and state the actual confidence level.
They separate direct userland calls from equal-overhead indirect calls.
The primary target is a geometric mean below stdlib on every fleet CPU and portable build.
A significant regression above ten percent requires investigation and an explicit disposition.
A geometric mean cannot hide a pathological complexity regression.
All performance claims name a run directory and a file under `docs/results/`.

## Ownership and delivery

The kernel owner controls the public entry point, search algorithms, and runtime dispatch.
The benchmark owner controls the search measurement binary and Python adapter.
The correctness owner controls the guard and fuzz matrix.
The parent integrates shared build changes from the isolated component branches.
The kernel owner also adds the private module import for each existing x86 dispatch level.
Independent review runs alongside fleet correctness tests.
Parent acceptance requires both review and measured evidence.

The mission budget is 4,000,000 tokens.
Complex work uses `openai-codex/gpt-6.1-sol`.
Routine extraction and mechanical work use `fireworks/accounts/fireworks/models/deepseek-v4p1-flash`.
