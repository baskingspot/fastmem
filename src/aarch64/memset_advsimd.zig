// memset - fill memory with a constant byte
//
// Copyright (c) 2012-2024, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memset.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534, with the >128 tail of
// string/aarch64/memset-sve.S at the same commit (that tail uses no SVE
// instructions: the 256-byte ZVA gate and the 16/48-offset store loop).
// This is the generic aarch64 (non-SVE) kernel, the G6 baseline.
// The below-16 tree is inverted (1..3 falls through, cbz first), the
// layout the SVE kernel's neon body already uses: the upstream order
// paid 2-3 predicted-taken branches at 0..15 bytes, which measured
// 1.20-1.43x glibc at set 0-16 on Neoverse V1/V2 (baseline builds,
// run 20260926T044944Z-final-baseline).
//
// Port notes (the only intentional differences from upstream):
// - Naked Zig functions and @export replace the ENTRY, ALIAS, and END macros.
//   The compiler emits symbol types, sizes, and hidden visibility.
//   Register aliases become architectural names. `instance.zig` tags every
//   local label with the package instance id, because all inline assembly of
//   one binary shares one label namespace (two fastmem copies in one link).
// - The symbol is renamed __memset_aarch64 -> fastmem_advsimd_set and given
//   .hidden visibility. It exports only when fastmem_options.export_kernels
//   is set; the kernel-bytes pin sets it.
// - SKIP_ZVA_CHECK is not defined, so the runtime DCZID_EL0 check on
//   the ZVA path is kept, as upstream writes it without the define.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - Exports require non-SVE aarch64 ELF at comptime and the export_kernels
//   option. Other builds omit these instructions.

const builtin = @import("builtin");
const options = @import("fastmem_options");
const instance = @import("instance.zig");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    !builtin.cpu.has(.aarch64, .sve);

comptime {
    if (enabled and options.export_kernels) {
        @export(&setEntry, .{ .name = "fastmem_advsimd_set", .visibility = .hidden });
    }
}

pub fn setEntry() align(64) callconv(.naked) void {
    asm volatile (instance.instanced(
            \\hint 34
            \\    cbz    x2, .Lfm_simd_set_ret0
            \\    dup    v0.16B, w1
            \\    cmp    x2, 64
            \\    b.hi    .Lfm_simd_set_128
            \\    cmp    x2, 16
            \\    b.hs    .Lfm_simd_set_ge16
            \\
            \\    // Set 0..15 bytes: the inverted tree, 1..3 falls through.
            \\    add    x4, x0, x2
            \\    cmp    x2, 4
            \\    b.hs    .Lfm_simd_set_ge4
            \\    lsr    x3, x2, 1
            \\    strb    w1, [x0]
            \\    strb    w1, [x0, x3]
            \\    strb    w1, [x4, -1]
            \\.Lfm_simd_set_ret0:
            \\    ret
            \\
            \\    // Set 4..15 bytes.
            \\.Lfm_simd_set_ge4:
            \\    lsr    x3, x2, 3
            \\    sub    x5, x4, x3, lsl 2
            \\    str    s0, [x0]
            \\    str    s0, [x0, x3, lsl 2]
            \\    str    s0, [x5, -4]
            \\    str    s0, [x4, -4]
            \\    ret
            \\
            \\    .p2align 4
            \\    // Set 16..64 bytes.
            \\.Lfm_simd_set_ge16:
            \\    add    x4, x0, x2
            \\    mov    x3, 48
            \\    and    x3, x3, x2, lsr 1
            \\    sub    x5, x4, x3
            \\    str    q0, [x0]
            \\    str    q0, [x0, x3]
            \\    str    q0, [x5, -16]
            \\    str    q0, [x4, -16]
            \\    ret
            \\
            \\    .p2align 4
            \\.Lfm_simd_set_128:
            \\    add    x4, x0, x2
            \\    bic    x3, x0, 15
            \\    cmp    x2, 128
            \\    b.hi    .Lfm_simd_set_long
            \\    stp    q0, q0, [x0]
            \\    stp    q0, q0, [x0, 32]
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\    ret
            \\
            \\    .p2align 4
            \\.Lfm_simd_set_long:
            \\    cmp    x2, 256
            \\    b.lo    .Lfm_simd_set_no_zva
            \\    tst    w1, 255
            \\    b.ne    .Lfm_simd_set_no_zva
            \\    mrs    x5, dczid_el0
            \\    and    x5, x5, 31
            \\    cmp    x5, 4        // ZVA size is 64 bytes.
            \\    b.ne    .Lfm_simd_set_no_zva
            \\
            \\    str    q0, [x0]
            \\    str    q0, [x3, 16]
            \\    bic    x3, x0, 31
            \\    stp    q0, q0, [x3, 32]
            \\    bic    x3, x0, 63
            \\    sub    x2, x4, x3    // Count is now 64 too large.
            \\    sub    x2, x2, 128    // Adjust count and bias for loop.
            \\
            \\    sub    x8, x4, 1    // Write last bytes before ZVA loop.
            \\    bic    x8, x8, 15
            \\    stp    q0, q0, [x8, -48]
            \\    str    q0, [x8, -16]
            \\    str    q0, [x4, -16]
            \\
            \\    .p2align 4
            \\.Lfm_simd_set_zva64_loop:
            \\    add    x3, x3, 64
            \\    dc    zva, x3
            \\    subs    x2, x2, 64
            \\    b.hi    .Lfm_simd_set_zva64_loop
            \\    ret
            \\
            \\    .p2align 4
            \\.Lfm_simd_set_no_zva:
            \\    str    q0, [x0]
            \\    sub    x2, x4, x3    // Count is 16 too large.
            \\    sub    x2, x2, #(64 + 16)    // Adjust count and bias for loop.
            \\.Lfm_simd_set_no_zva_loop:
            \\    stp    q0, q0, [x3, 16]
            \\    stp    q0, q0, [x3, 48]
            \\    add    x3, x3, 64
            \\    subs    x2, x2, 64
            \\    b.hi    .Lfm_simd_set_no_zva_loop
            \\    stp    q0, q0, [x4, -64]
            \\    stp    q0, q0, [x4, -32]
            \\    ret
            \\
            \\// END (__memset_aarch64)
        ) ::: .{ .memory = true });
}

pub const fastmem_advsimd_set: *const fn ([*]u8, u8, usize) callconv(.c) void = @ptrCast(&setEntry);
