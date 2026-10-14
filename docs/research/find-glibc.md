# glibc `memmem` behavior

## Scope and method

The investigation inspected the seven benchmark targets on 2026-10-14.
It used the libc binaries on those hosts, not glibc source.
No search code derives from this inspection.
Raw binaries, probes, command records, and disassembly remain under `.bench-cache/glibc/memmem/`.
This document contains behavior observations, not performance results.

The probe uses a specific `dlopen("libc.so.6")` handle.
It resolves `memmem`, `memchr`, and `memcmp` through `dlsym` and records `dladdr` evidence.
Each downloaded library matches its remote SHA-256 record.
The inspection uses bounded disassembly windows for the selected functions and their actual callees.

Evidence paths in this document use `E` for `.bench-cache/glibc/memmem/`.
Exact acquisition commands are in `E/commands.md` and `E/<target>/commands.log`.
Probe source is in `E/probe.c`.

## Library identity

All seven targets use glibc 2.40, release `stable`, Nix package `2.40-224`.
Library bytes match within each architecture.
Each host records its own resolution and identity evidence.

| Targets | `memmem` offset | ELF build ID | SHA-256 |
|---|---|---|---|
| c7i, c8i, c7a, c8a | `0xb0520` | `12792584c1e1da1379dc6924d7aade11b4e6037d` | `9d05c2032271eee7aeaf312ec97dc855ed3ce45d76dc8ba5ba36b3282b5d0719` |
| c7g, c8g, c9g | `0xa7320` | `b1d7a5a3917a8db06dcc631add2a7f629357d4b5` | `0191421da03983236f50cfef0b4819f18c8a10fc18b79314b2fef0b18139dc38` |

The offsets are relative to the libc load base.
Sources are `E/<target>/probe.txt`, `elf.txt`, and `linkage.txt` for each target.
`memmem` is an ordinary ELF `FUNC`, not an `IFUNC`, on both architectures.

## Needle classes

Both architecture builds use the same length classes.
The boundary at 256/257 is a binary branch threshold, not a measured crossover.

| Needle length | Observed behavior |
|---|---|
| 0 | Returns the start of the haystack. |
| 1 | Uses the internal bounded byte-search path. |
| 2 | Uses a dedicated scalar two-byte search. |
| 3–256 | Uses an adjacent-byte-pair hash/skip filter and comparison verification. |
| Above 256 | Calls the actual `two_way_long_needle` destination. |

Source windows are `E/c7i/memmem.dis` at `0xb0520–0xb07b2` and `E/c7g/memmem.dis` at `0xa7320–0xa75dc`.
The other acquired binaries match the corresponding architecture hash.

The middle class uses a 256-entry byte table.
Needles of 16–256 bytes also use an eight-byte precheck before full comparison.
The precheck position can change after a failed comparison.
No branch in this middle-class body switches to the long-needle algorithm after candidate failures.
Sources are the same windows, especially `0xb058c–0xb06af` and `0xa7388–0xa7480`.

The long-needle helper has separate periodic and nonperiodic paths.
It uses period-related state, scalar candidate verification, and a 256-entry machine-word skip table.
Its comparison call occurs in preprocessing, not repeated whole-needle verification.
Sources are `E/c7i/two_way_long_needle.dis` at `0xb00c0` and `E/c7g/two_way_long_needle.dis` at `0xa6f20`.
Binary inspection does not establish a formal complexity proof.

## Architecture differences

All four x86 targets resolve `memchr` to `__memchr_evex` at offset `0x18ca80`.
They resolve `memcmp` to `__memcmp_evex_movbe` at offset `0x18cd00`.
The selected helpers use 32-byte vectors, not 64-byte vectors.
Live internal linkage slots match the separately resolved helper addresses on every x86 target.
Sources are `E/<target>/linkage.txt`, `__memchr_evex.dis`, and `__memcmp_evex_movbe.dis`.

All three Arm targets resolve byte search to `__memchr_generic` at offset `0xae280`.
That helper uses 16-byte NEON vectors, not SVE.
The one-byte `memmem` path branches directly to that helper.
The comparison function at offset `0xa6b80` is not an IFUNC.
Its larger path enters NEON bulk comparison at a comparison length of 160 bytes.
Sources are the Arm `linkage.txt`, `__memchr_generic.dis`, and `memcmp.dis` files.

These helper choices are specific to the recorded libc builds and host state.
They do not imply that other libc builds lack different implementations.

## Diagnostic correctness sample

The probe made 72 untimed guard-page calls on each host.
All 504 calls passed.
The sample checks absence, a final-position match, and shorter-haystack rejection at length boundaries through 1024 bytes.
Both input ends abut inaccessible pages.
Each `E/<target>/probe.txt` records the result and the observed 4096-byte page size.
This sample is not the fastmem correctness gate.

## Benchmark implications

The following hypotheses require measurement:

- Setup cost matters for small haystacks and long needles.
- Dense false candidates expose verification costs.
- Periodic and nearly periodic inputs exercise different long-needle behavior.
- Fixed Zig needles can avoid some runtime setup costs.

The suite must include boundaries at needle lengths 15/16/17 and 255/256/257.
It must also include candidate-producing cases around comparison and SIMD boundaries.
Random absent searches alone do not establish verification performance.
The fastmem design uses permitted upstream sources rather than the observed glibc implementation.
