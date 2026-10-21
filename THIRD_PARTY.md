# Third-party code

fastmem is MIT (`LICENSE`). This file lists every file that is a port of
upstream code, per the licensing rules in `docs/fastmem-plan.md`.

## Arm Optimized Routines

Upstream: https://github.com/ARM-software/optimized-routines
License: MIT OR Apache-2.0 WITH LLVM-exception (per-file SPDX header;
fastmem uses the MIT option). The upstream copyright and SPDX lines are
kept verbatim at the top of each ported file.

Pinned commit: `5e20a93f440ca771bcdb757cc13c3beee217e534`
(2026-09-15, newest commit touching `string/aarch64` at fetch time;
includes `23c4393006122497ea989725c9e34d253bc1e62b`, "Improve
__memcpy_aarch64_sve": the cntb hoist and `.p2align` layout).

| Ported file                      | Upstream file                                                                                        | Port                                                                                                                                      |
| -------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `src/aarch64/memcpy_sve.zig`     | `string/aarch64/memcpy-sve.S`                                                                        | Faithful translation to Zig container-level global asm; symbols renamed to `fastmem_sve_copy` / `fastmem_sve_move` with hidden visibility |
| `src/aarch64/memset_sve.zig`     | `string/aarch64/memset-sve.S`                                                                        | Same; symbol `fastmem_sve_set`; the runtime DCZID_EL0 check on the ZVA path is kept                                                       |
| `src/aarch64/memcpy_advsimd.zig` | `string/aarch64/memcpy-advsimd.S`                                                                    | Same; symbols `fastmem_advsimd_copy` / `fastmem_advsimd_move`                                                                             |
| `src/aarch64/memset_advsimd.zig` | `string/aarch64/memset.S`; the >128 tail follows `string/aarch64/memset-sve.S` (no SVE instructions) | Same; symbol `fastmem_advsimd_set`; the runtime DCZID_EL0 check on the ZVA path is kept                                                   |

Port-level deviations (each is documented in the file header): the
`asmdefs.h` macros (`ENTRY` / `ENTRY_ALIAS` / `END`, register aliases,
`L()`) are expanded by hand; the GNU_PROPERTY note (link-level BTI/PAC
marking) is omitted because no other object in a Zig link carries it;
the BTI landing pad (`hint 34`) is kept. Local labels are renamed with a
unique prefix per port (`.Lfm_sve_cpy_*`, `.Lfm_sve_set_*`,
`.Lfm_simd_cpy_*`, `.Lfm_simd_set_*`): module-level asm in one
compilation shares a label namespace across files. A `.p2align 6` is
added above the memmove alias labels so both entries stay 64-byte
aligned in the fused module asm. No algorithmic change; each port
assembles to a standalone .text byte-identical to upstream.

### MIT permission notice (Arm Optimized Routines)

fastmem uses the MIT option of the upstream dual license. Per its terms,
the notice from the upstream `LICENSE` file is reproduced here:

> Copyright (c) 1999-2022, Arm Limited.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## x86_64 kernels

Except for `compact.zig`, the x86 kernels independently implement `docs/research/x86_64-design.md`, section 5.
No glibc source or disassembly entered these files.
The memo uses glibc only as a behavioral reference.

The head/tail vocabulary also follows llvm-libc's design in `libc/src/string/memory_utils/op_generic.h`.
That reference uses commit `b19a36aaf4b9aaea539b903bd515b54a9f23a639` and the Apache-2.0 WITH LLVM-exception license.
No llvm-libc source was ported.

## Zig compiler-rt

`src/x86_64/compact.zig` adapts `copyRange4` and the three-byte fragment from `lib/compiler_rt/memmove.zig`.
Upstream: https://codeberg.org/ziglang/zig

Pinned commit: `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8` (Zig 0.16.0).
The source matches the file in the pinned Nix toolchain.
The port uses scalar and vector pointers instead of arrays to avoid LLVM stack spills.
The callers provide the size checks and retain runtime safety in safe modes.
The MIT copyright notice also appears in the source header.

### MIT permission notice (Zig)

> The MIT License (Expat)
>
> Copyright (c) Zig contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
> THE SOFTWARE.

## Zig standard library (facts only)

Upstream: https://github.com/ziglang/zig, `lib/std/zig/system/x86.zig`
(Zig 0.16.0). License: MIT.

`src/x86_64/cpuid.zig` uses the Intel and AMD family and model numbers of
the Zig host detection for the models that fastmem tunes. It contains no
Zig standard library code. The feature bit positions come from the Intel
SDM and the AMD APM.
