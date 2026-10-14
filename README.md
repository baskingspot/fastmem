# fastmem

Fast `memcpy`, `memmove`, and `memset` for Zig.

For byte searches, `find` replaces `std.mem.find` without a libc dependency.

Zig code gets these operations from compiler-rt. compiler-rt's `memset` is
a byte loop, and its `memcpy` and `memmove` are slower than glibc on most
CPUs. fastmem replaces them with kernels that are tuned per CPU model and
measured against glibc and compiler-rt on seven EC2 targets.

- MIT license (`LICENSE`). The aarch64 kernels are ports of Arm Optimized
  Routines (MIT). `THIRD_PARTY.md` lists every port.
- Zig 0.16.0. No libc dependency.
- Correctness: a guard-page suite of about 28 million cases per build runs
  on the target hardware in ReleaseFast, ReleaseSafe, and Debug.

## Use it

Add the package to `build.zig.zon` (`zig fetch --save <url>`), then add the
module:

```zig
const fastmem = b.dependency("fastmem", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fastmem", fastmem.module("fastmem"));
```

### Explicit calls

Call fastmem where you want it. Nothing else in the program changes.

```zig
const fastmem = @import("fastmem");

fastmem.copy(u8, dest, source); // non-overlapping; dest.len >= source.len
fastmem.move(u8, dest, source); // overlap-safe
fastmem.set(u8, dest, 0);
```

The functions are `inline`. Small sizes compile to straight-line code at
the call site. Larger sizes call the kernel directly, with no PLT and no
ifunc. `copy`, `move`, and `set` are generic over the element type.

### Subslice search

```zig
const index = fastmem.find(u8, "banana", "ana"); // Returns index 1.
```

`find(comptime T: type, haystack: []const T, needle: []const T) ?usize` returns the first element index or `null`.
An empty needle matches at index zero.
Only `u8` has an optimized kernel.
Other element types and comptime calls use `std.mem.find`.
The kernel permits overlapping slices and keeps every read within both slices.
It needs no allocator and exports no `memmem` symbol.

The [search results](docs/results/find-standard-20261014.md) include the measured aggregate gains and retained slow cases.
`docs/find-plan.md` defines the contract.
`THIRD_PARTY.md` records the Rust memchr port and its MIT notice.

### Replace the symbols (opt in)

To make every `@memcpy`, `@memmove`, and `@memset` in the program use
fastmem, add one line to the root source file:

```zig
comptime { @import("fastmem").exportSymbols(); }
```

This gives the link strong, hidden `memcpy`, `memmove`, and `memset`
definitions. They win over compiler-rt and glibc. Remove your own
definitions of these symbols first: a second definition is a compile or
link error. `docs/export-layer.md` gives the details and the limits (ELF
only, the LLVM backend, Debug builds).

## Kernels

| Target | Kernel |
|---|---|
| x86_64 with AVX-512 | Zig vector kernels with per-model tuning: `rep movsb` and non-temporal thresholds, size-class dispatch, zmm registers without `vzeroupper` |
| x86_64 with AVX2 (`x86_64_v3`) | the same kernels with ymm |
| x86_64 Linux without AVX2 (`baseline`) | the kernels above, selected at run time from CPUID (`docs/runtime-dispatch.md`); the generic fallback on hosts without AVX2 |
| aarch64 with SVE | Arm Optimized Routines `memcpy-sve` / `memset-sve`, plus per-model small-size paths |
| aarch64 without SVE | Arm Optimized Routines AdvSIMD |
| other targets | a generic Zig vector fallback |

`fastmem.impl` names the kernel that a build selected. In a runtime-dispatch
build, `fastmem.dispatch.kernelName()` names the kernel that the host selected.

## Results

`docs/results/` holds one file per fleet measurement.
`docs/results/scorecard.md` is the current state against glibc and
compiler-rt on all seven targets. `docs/results/baseline-0.16.md` measures
the problem: compiler-rt against glibc.

## Develop

The Nix flake provides every tool: `nix develop`, then `just --list`.

```sh
just test          # unit tests, export checks, shipped-binary builds
just test-guard    # the guard-page matrix on this host
just codegen-x86   # x86 codegen gates for every fleet CPU model
```

The benchmark fleet (EC2, OpenTofu, and a Python harness) is described in
`docs/bench-design.md` and `infra/README.md`. `AGENTS.md` has the working
notes for the repository, and `docs/fastmem-plan.md` has the goals and the
design rules.
