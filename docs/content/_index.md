+++
title = "fastmem"
+++

Fast memcpy, memmove, and memset for Zig.

Zig code gets these operations from compiler-rt. compiler-rt's `memset` is a
byte loop, and its `memcpy` and `memmove` are slower than glibc on most CPUs.
fastmem replaces them with kernels tuned per CPU model, measured against glibc
and compiler-rt on seven EC2 targets. It imports only `std` and has no libc
dependency.

You can call the kernels directly, or export them as the memory symbols for a
link unit.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="benchmark-dark.svg">
  <img src="benchmark.svg" alt="fastmem speedup over compiler-rt by size tier: memset reaches 16x the median and up to 25x above 16 KiB; copy and move stay near 1x to 2x" width="700" height="336">
</picture>

- [Kernels](#kernels): AVX-512 and AVX2 kernels with per-model tuning, Arm Optimized Routines on aarch64, and a generic fallback.
- [Runtime dispatch](#runtime-dispatch): one x86_64 Linux baseline binary selects AVX-512, AVX2, or generic kernels from CPUID.
- [Correctness](#correctness): the guard-page suite, the per-model codegen gates, and the export-layer binary checks.
- [Performance](#performance): the scorecard against glibc and compiler-rt on all seven targets.
- [Limits](#limits): the export layer is ELF only and needs the LLVM backend; other targets get the generic vector fallback.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

Add the package to `build.zig.zon`:

```sh
zig fetch --save https://baskingspot.dev/fastmem/v0.1.1.tar.gz
```

fastmem builds with Zig 0.16 only.

## Import it

Add the module in `build.zig`:

```zig
const fastmem = b.dependency("fastmem", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("fastmem", fastmem.module("fastmem"));
```

## Explicit calls

Call fastmem where you want it. Nothing else in the program changes.

```zig
const fastmem = @import("fastmem");

fastmem.copy(u8, dest, source); // non-overlapping; dest.len >= source.len
fastmem.move(u8, dest, source); // overlap-safe
fastmem.set(u8, dest, 0);
```

`copy`, `move`, and `set` are generic over the element type, and the slice
lengths are in elements. `copy` has the `memcpy` contract: the ranges must not
overlap, and `dest` must hold at least `source.len` elements. `move` allows
overlap. `set` writes `value` to every element. For `T` other than `u8`, the
vector kernel applies only when `T` has a unique in-memory representation and
the value's bytes are all equal; the second check runs at runtime. Every other
value takes an element-wise loop. The functions are `inline`.
Small sizes compile to straight-line code at the call site. Larger sizes call
the kernel directly, with no PLT and no ifunc.

Debug builds assert the length and overlap contracts for `copy` and `move`.

## Replacing the symbols

To make every `@memcpy`, `@memmove`, and `@memset` in a link unit use
fastmem, add one line to the root source file:

```zig
comptime { @import("fastmem").exportSymbols(); }
```

This gives the link strong, hidden `memcpy`, `memmove`, and `memset`
definitions. They win over compiler-rt and glibc. The export applies to
aarch64 and x86_64 ELF targets, and it needs the LLVM backend. In Debug
builds, set `exe.use_llvm = true` in the build, or pass `-fllvm` to
`zig build-exe`.

Call `exportSymbols()` from the program that owns the final link, not from a
library that another program imports. A library that exports the symbols adds
strong definitions to every consumer's link, and a consumer with its own
definitions gets a link error. A shared library that you build and ship can
opt in for its own link unit.

Remove your own definitions of the three symbols before you enable the
export. A second definition is a compile or link error. The export also
covers C objects in the same link unit; a C compiler can still inline an
operation. It does not replace fortified aliases such as `__memcpy_chk`, and
it does not reach into an already-built shared library.

Small or constant-size builtins can stay inline, so the export replaces the
operations that become symbol calls, not every builtin.

# Kernels

| Target                                 | Kernel                                                                                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| x86_64 with AVX-512                    | Zig vector kernels with per-model tuning: `rep movsb` and non-temporal thresholds, size-class dispatch, zmm registers without `vzeroupper` |
| x86_64 with AVX2 (`x86_64_v3`)         | the same kernels with ymm                                                                                                                  |
| x86_64 Linux without AVX2 (`baseline`) | the kernels above, selected at run time from CPUID (see [Runtime dispatch](#runtime-dispatch)); the generic fallback on hosts without AVX2 |
| aarch64 with SVE                       | Arm Optimized Routines `memcpy-sve` / `memset-sve`, plus per-model small-size paths                                                        |
| aarch64 without SVE                    | Arm Optimized Routines AdvSIMD                                                                                                             |
| other targets                          | a generic Zig vector fallback                                                                                                              |

The aarch64 kernels are ports of Arm Optimized Routines (MIT), and
`src/x86_64/compact.zig` adapts Zig compiler-rt. `THIRD_PARTY.md` lists every
port, its pinned revision, and its license.

`fastmem.impl` names the kernel that a build selected:

```zig
std.debug.print("{s} {s} {s}\n", .{ fastmem.impl.copy, fastmem.impl.move, fastmem.impl.set });
```

In a runtime-dispatch build, `fastmem.impl` names the stub family and
`fastmem.dispatch.kernelName()` names the kernel that the host selected.

# Runtime dispatch

An x86_64 Linux build whose target CPU lacks AVX2 selects its kernels at run
time. One `-Dcpu=baseline` binary runs the AVX-512 kernels on an AVX-512 host,
the AVX2 kernels on an AVX2 host, and the generic kernels on anything older.

Dispatch is active when all of these hold:

- The target is x86_64 Linux with the ELF object format.
- The target CPU lacks AVX2, for example `baseline`, `x86_64`, or `x86_64_v2`.
- The build option `-Dx86-dispatch` is true. It is true by default.

Every other build selects its kernels at compile time and contains no dispatch
code.

| Level            | Required features | Selected on                                                               |
| ---------------- | ----------------- | ------------------------------------------------------------------------- |
| `generic`        | none              | hosts without the full x86-64-v3 feature set                              |
| `x86_64_v3`      | x86-64-v3         | AVX2 hosts, including Skylake-SP, Cascade Lake, Cooper Lake, and Ice Lake |
| `x86_64_v4`      | x86-64-v4         | AVX-512 hosts that are not one of the model rows                          |
| `sapphirerapids` | x86-64-v4         | Intel family 6, model 0x8f                                                |
| `graniterapids`  | x86-64-v4         | Intel family 6, model 0xad                                                |
| `znver4`         | x86-64-v4         | AMD family 0x19, Zen 4 model ranges                                       |
| `znver5`         | x86-64-v4         | AMD family 0x1a                                                           |

The model rows carry the REP and non-temporal thresholds measured on that
model. An unknown AVX-512 model gets `x86_64_v4`, which cannot select REP on
AMD and cannot start non-temporal stores below the cache size.

The API reports what the host selected:

```zig
if (fastmem.dispatch.enabled) {
    const level = fastmem.dispatch.level().?;
    const name = fastmem.dispatch.kernelName().?;
    const facts = fastmem.dispatch.detect().?;
}
```

`level` returns `?Level`, `kernelName` returns `?[:0]const u8`, and `detect`
returns the CPUID and XCR0 facts that the selection read. All three return
`null` in a build without dispatch. `force` is a test hook; the public module
does not provide it.

To turn dispatch off, pass the dependency option:

```zig
const fastmem = b.dependency("fastmem", .{
    .target = target,
    .@"x86-dispatch" = false,
});
```

A dispatch build inlines sizes up to 128 bytes. Larger sizes call the selected
kernel through a pointer, with no per-call CPUID check. The dispatcher reads
CPUID and XCR0 once, on the first call.

# Correctness

The guard-page suite runs about 28 million cases per build. Each case places
the source or destination against a guard page, so an over-read, an over-write,
or a wrong direction faults. The suite runs in ReleaseFast, ReleaseSafe, and
Debug, on the target hardware.

The codegen gates check the generated code, not only its behavior. The x86
gate checks vector widths, the ABI entry shape, and that no kernel calls a
memory symbol. It runs for every fleet CPU model. The aarch64 gate pins each
kernel's instruction bytes to the measured `GOLDEN` set, so a kernel change
needs a deliberate update of those bytes.

The export layer has its own binary checks: strong and hidden definitions, no
`memcpy`/`memmove`/`memset` references inside the kernels, no entries in
`.dynsym`, and no recursion through Zig helpers. The checks link with and
without libc, with and without compiler-rt, and in Debug, ReleaseSafe, and
ReleaseFast.

Run the checks from the repository:

```sh
just test          # unit tests, export checks, shipped-binary builds
just test-guard    # the full guard-page matrix on this host
just codegen-x86   # the x86 codegen gates for every fleet CPU model
```

# Performance

Against compiler-rt, `memset` is 8x to 25x faster above 16 KiB. Against glibc,
`memset` is 1.7x to 2.9x faster at 0 to 16 bytes on x86_64 and on Graviton V3,
and at parity on Graviton V1 and V2. From 65 bytes up, every target is near
parity.

Copy and move are mostly 1x to 2x faster than compiler-rt, with a few target
and tier combinations reaching 2.5x. On some x86_64 targets at 17 to 64 bytes
they are 8% to 20% slower.

The measurement is the 2026-09-27 seven-target run at commit `418197e`: six
rounds in ReleaseFast with an A/A control, and the correctness sweep behind
it. The chart is generated by `just plot` from that record.

# Limits

- The export layer is aarch64 or x86_64 ELF with the LLVM backend. In Debug
  builds it needs `-fllvm` or `exe.use_llvm = true`.
- A consumer that enables `exportSymbols()` must not set `no_builtin = true`
  on its own module. That setting can turn builtin calls into inline loops,
  which a symbol export cannot intercept.
- The export does not define fortified aliases such as `__memcpy_chk`, and it
  does not replace the private memory calls of an already-built shared
  library.
- Targets without a dedicated kernel get the generic Zig vector fallback.
  Non-ELF aarch64 targets, such as macOS, also get the generic kernels.
- Runtime dispatch covers x86_64 Linux ELF only. Other x86_64 targets select
  their kernels at compile time.
- Zig 0.16 has no per-function target features. A dispatch build compiles each
  level as a separate object, and the inline layer is fixed at 128 bytes.
- A hypervisor that masks AVX-512 on a model host gets `x86_64_v3`. The
  dispatcher does not read the CPUID stepping, so Cooper Lake gets the
  32-byte row while a comptime `cooperlake` build gets 64-byte vectors.
- The library never calls `memcpy`, `memmove`, or `memset` through a symbol.
  `exportSymbols()` is the only path that defines them.
