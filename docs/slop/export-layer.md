# Opt-in memory symbols

`fastmem.exportSymbols()` gives one ELF link unit strong, hidden definitions of three memory symbols:

- `memcpy`
- `memmove`
- `memset`

Each definition has the address of the corresponding `fastmem.abi` entry.
The export adds no wrapper or trampoline.
In an x86_64 dispatch build, the `fastmem.abi` entries handle 0 to 128 bytes themselves and dispatch larger sizes (`docs/slop/runtime-dispatch.md`).
An import alone does not replace these symbols.

## Enable the exports

1. Add fastmem as a Zig package dependency.
2. Add its public module to the executable root module.

```zig
const fastmem = b.dependency("fastmem", .{ .target = target });
exe.root_module.addImport("fastmem", fastmem.module("fastmem"));
```

3. Add this line to the root source file.

```zig
comptime { @import("fastmem").exportSymbols(); }
```

4. Remove your own definitions of the three memory symbols before you enable the exports.
5. For Debug builds, set `exe.use_llvm = true` or pass `-fllvm` to `zig build-exe`.

## API choice

The root comptime call makes the executable owner responsible for the replacement.
A dependency import cannot enable it by accident.
Call it only from the program or shared library that owns the final link, never
from a library that another program imports.
A library that exports the symbols adds strong definitions to every consumer's
link, and a consumer with its own definitions gets a link error.
The same API also works with `zig test` and shared libraries.

The package module sets `no_builtin = true` for the kernels.
The consumer module keeps its normal builtin behavior.
The consumer must not set `no_builtin = true` for this feature.
That setting can replace builtin calls with inline loops, which symbol exports cannot intercept.

Both architectures use `@export` with `.strong` linkage and `.hidden` visibility.
The aarch64 entries are naked Zig functions with their original assembly instructions.
The API casts their addresses to the libc function types.
The byte tests pin each kernel to its measured instruction bytes.
No assembler-only alias bypasses Zig symbol checks.

## Guarantees

For runtime byte lengths, the ReleaseFast and ReleaseSafe consumer probes call the fastmem ABI entries.
The probes cover links both with and without libc.
They also cover links both with and without the compiler-rt `__udivti3` helper.
The strong definitions take precedence over compiler-rt in separate archive objects and over glibc.
Compiler-rt inside the same Zig compilation receives a collision error.

The exported kernel bodies contain no branch to any memory entry.
The binary tests follow every direct branch target, including common helpers and standard-library functions.
They exclude only named panic handlers for invalid inputs.
The dispatch entries jump through pointers above 128 bytes, so the audit also starts at every `fastmem_x86_*` function.
An unresolved direct target fails the audit.
A compiled negative fixture proves that the audit detects recursion through `std.mem.replace`.

A ReleaseSafe panic handler can use memory functions for its diagnostic output.
The checks do not claim a proof for arbitrary indirect control flow.

The generic ABI entries and fallback helpers also use `@disableIntrinsics()`.
Baseline x86_64 probes pass without the module-level `no_builtin` setting.
The public module retains that setting as another safeguard.

The three symbols do not appear in `.dynsym`.
This holds for the executable probes and the shared-library probes.
LLD can convert hidden global symbols to local symbols in the final image.
The relocatable-object tests check that each original definition is `GLOBAL HIDDEN`, not `WEAK`.

### Kernel symbols

The aarch64 kernels hold their entries in inline assembly.
The inline layer also enters the copy kernel at a mid label for sizes above 64 bytes.
All modules of one binary share one assembler label namespace, because Zig compiles them into one object.
Two fastmem package copies in one link would therefore define the same labels.

The package instance id (`instanceId` in `build.zig`) prefixes every local kernel label (`src/aarch64/instance.zig`).
Each copy emits its own kernel bytes.
A content-hash mismatch then costs duplicated bytes, not a link error.

The hidden entry symbols `fastmem_sve_*` and `fastmem_advsimd_*` exist only in the kernel-bytes pin.
That pin sets the `fastmem_options.export_kernels` flag.
A consumer copy does not set the flag and exports no kernel symbol.
`exportSymbols()` stays the only export site for a consumer.
On x86_64, the dispatch symbols already carry the instance id (`docs/slop/runtime-dispatch.md`).

## Scope and limits

The API accepts aarch64 and x86_64 ELF targets with the LLVM backend.
The binary suite tests Linux with Zig 0.16.0.
Other object formats and non-LLVM backends receive a compile error.

The target CPU selects the kernel at compile time, with one exception.
An x86_64 Linux build without AVX2 selects its kernels at run time (`docs/slop/runtime-dispatch.md`).
There the exported symbols handle 0 to 128 bytes inline. Larger sizes make a pointer load and an indirect jump.
The executable must run on a CPU that supports its target features.

Small or constant-size builtins can remain inline.
The export only replaces operations that become symbol calls.
It does not force every builtin through a function.

### Debug

The API refuses non-LLVM backends because their symbol visibility is not part of this guarantee.
Debug with LLVM passes the linked binary checks and the runtime consumer tests on both architectures.

The separate `-fno-llvm` Debug probes establish this actual Zig 0.16 behavior for runtime byte lengths:

| Backend | `@memcpy` | `@memmove` | `@memset` |
|---|---|---|---|
| x86_64 | Symbol call | Symbol call | Inline `rep stosb` |
| aarch64 | Symbol call | Symbol call | Symbol call |

These results replace the earlier assumption that every Debug memory builtin stays inline.
The probes retain runtime safety checks and use a trap-only panic handler.

### Shared libraries

A shared library can opt in for its own link unit.
Its internal calls bind to its hidden fastmem definitions.
Those definitions do not interpose the executable or other shared libraries.
The tests inspect both direct calls and `.dynsym` in `-dynamic` library builds.
Separate shared-library probes disable compiler-rt with `-fno-compiler-rt`.
Compiler-rt cannot mask an incorrect export visibility in those probes.

An executable export does not replace the private memory operations of an already-built shared library.
For example, handoff's AWS-LC shared library keeps its own glibc calls.

### C objects

C objects in the same link bind their ordinary memory calls to fastmem too.
This behavior is intentional: the opt-in covers the link unit, not only Zig source files.
A C compiler can still inline an operation.
The C fixture uses `addCSourceFile` with `-fno-builtin` so its calls remain visible in the binary test.

The export layer does not define fortified aliases such as `__memcpy_chk`.
The Zig builtin probes do not call those aliases.
Compiler-rt can still supply unused fortified definitions, notably in Debug builds.
Fortified C calls keep their existing bounds-check behavior.

### Competing definitions

Consumers must remove their own definitions of all three memory symbols before the opt-in.
This requirement includes all export kinds:

- Strong exports.
- Weak exports.
- Exports without explicit linkage.

Zig rejects a competing export on both architectures with this diagnostic:

```text
error: exported symbol collision: memset
```

The diagnostic names the conflicting symbol.
The collision tests cover each symbol and each export kind on both architectures.
They also reject `zig build-obj -fcompiler-rt`, which inserts compiler-rt into the same compilation.
Normal executable links can retain compiler-rt in its separate archive object.

The earlier aarch64 assembler aliases silently lost to competing Zig definitions.
The current naked entries remove that failure mode.
Handoff still requires removal of its existing `memset` export before the opt-in.

## Test commands

Run the binary matrix through the flake:

```sh
nix develop -c zig build test-export
```

Run the upstream standard-library subset:

```sh
nix develop -c zig build test-export-std
```

`zig build test` also runs `test-export`.
The standard-library subset is a separate step because its four builds take several minutes.

The checks need Python and LLVM tools from the flake.
Linux hosts execute compatible Linux binaries.
Cross-architecture execution requires an available user-mode QEMU executable.
Other hosts compile and inspect the Linux probes without execution.
The standard-library step follows the same rule.
Its non-Linux matrix uses explicit Linux targets rather than the native target.

The binary matrix covers these cases:

- Both architectures, both release modes, libc on or off, and u128 division on or off.
- Debug with LLVM, Debug builtin probes without LLVM, and refusal of non-LLVM exports.
- Opt-out controls and relocatable-object linkage.
- Dynamic executables and shared libraries, including libraries without compiler-rt.
- Competing exports and compiler-rt inside the same compilation.
- Original aarch64 instruction bytes and fallback kernels without module-level intrinsic suppression.
- Generic aarch64, Neoverse V1/V2/V3, x86_64 baseline, and x86_64_v3.
- An `x86_64-dispatch` row: x86_64 baseline with runtime dispatch, in every link mode above.
- Two fastmem package copies in one link: x86_64 baseline for the dispatch instances, and aarch64 for the instance-tagged kernel labels. The dispatch test hook stays out of the public module (`test-export-packages`).

The libc-free consumer tests execute every length from 0 through 8192 bytes.
They check copy, fill, and both move directions against byte-level expectations.
They also execute the C calls.
Cross-built glibc executables and shared libraries receive binary inspection, not execution.
The SVE-specific matrix entries receive binary inspection.
The native standard-library and handoff tests exercise SVE on launchpad.

## Ecosystem validation

The [validation record](results/export-layer-0.16.md) contains the tested revisions and results.
The upstream subset passes 254 tests in each of four configurations.
The earlier handoff validation passed both release modes with the export active, including its live socket tests.
That validation predates the naked-entry revision.
