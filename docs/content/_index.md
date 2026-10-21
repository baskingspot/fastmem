+++
title = "fastmem"
+++

Fast `memcpy`, `memmove`, and `memset` for Zig. The kernels are tuned per CPU
model and measured against glibc and compiler-rt on seven EC2 targets.

- [Getting started](#getting-started)
- [Explicit calls](#explicit-calls)
- [Replacing the symbols](#replacing-the-symbols)
- [Kernels](#kernels)
- [Results](#results)
- [Limits](#limits)

# Getting started

Add the package to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/baskingspot/fastmem
```

Then add the module:

```zig
const fastmem = b.dependency("fastmem", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fastmem", fastmem.module("fastmem"));
```

The library imports only `std`.

## Explicit calls

Call fastmem where you want it. Nothing else in the program changes.

```zig
const fastmem = @import("fastmem");

fastmem.copy(u8, dest, source); // non-overlapping; dest.len >= source.len
fastmem.move(u8, dest, source); // overlap-safe
fastmem.set(u8, dest, 0);
```

The functions are `inline`. Small sizes compile to straight-line code at the
call site. Larger sizes call the kernel directly, with no PLT and no ifunc.
`copy`, `move`, and `set` are generic over the element type.

## Replacing the symbols

To make every `@memcpy`, `@memmove`, and `@memset` in the program use
fastmem, add one line to the root source file:

```zig
comptime { @import("fastmem").exportSymbols(); }
```

This gives the link strong, hidden `memcpy`, `memmove`, and `memset`
definitions. They win over compiler-rt and glibc. Remove your own definitions
of these symbols first: a second definition is a compile or link error.

# Kernels

| Target                                 | Kernel                                                                                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| x86_64 with AVX-512                    | Zig vector kernels with per-model tuning: `rep movsb` and non-temporal thresholds, size-class dispatch, zmm registers without `vzeroupper` |
| x86_64 with AVX2 (`x86_64_v3`)         | the same kernels with ymm                                                                                                                  |
| x86_64 Linux without AVX2 (`baseline`) | the kernels above, selected at run time from CPUID (`docs/runtime-dispatch.md`); the generic fallback on hosts without AVX2                |
| aarch64 with SVE                       | Arm Optimized Routines `memcpy-sve` / `memset-sve`, plus per-model small-size paths                                                        |
| aarch64 without SVE                    | Arm Optimized Routines AdvSIMD                                                                                                             |
| other targets                          | a generic Zig vector fallback                                                                                                              |

`fastmem.impl` names the kernel that a build selected. In a runtime-dispatch
build, `fastmem.dispatch.kernelName()` names the kernel that the host selected.

# Results

`docs/results/` holds one file per fleet measurement. `scorecard.md` is the
current state against glibc and compiler-rt on all seven targets.
`baseline-0.16.md` measures the problem: compiler-rt against glibc.

# Limits

- The export layer is ELF only. It needs the LLVM backend, and it does not
  work in Debug builds with the self-hosted backend.
- Targets without a dedicated kernel get the generic Zig vector fallback.
- The library never calls `memcpy`, `memmove`, or `memset` through a symbol.
  `exportSymbols()` is the only path that defines them.
