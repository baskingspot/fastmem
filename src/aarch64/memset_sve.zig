// memset - fill memory with a constant byte
//
// Copyright (c) 2024-2024, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memset-sve.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534. The neon small-path
// variant reuses the store tree of string/aarch64/memset-advsimd.S at
// the same pinned commit (already ported in memset_advsimd.zig).
//
// Port notes (the only intentional differences from upstream):
// - Naked Zig functions and @export replace the ENTRY, ALIAS, and END macros.
//   The compiler emits symbol types, sizes, and hidden visibility.
//   Register aliases become architectural names. `instance.zig` tags every
//   local label with the package instance id, because all inline assembly of
//   one binary shares one label namespace (two fastmem copies in one link).
// - The symbol is renamed __memset_aarch64_sve -> fastmem_sve_set and given
//   .hidden visibility. It exports only when fastmem_options.export_kernels
//   is set; the kernel-bytes pin sets it.
// - SKIP_ZVA_CHECK is not defined, so the runtime DCZID_EL0 check on
//   the ZVA path is kept, as upstream writes it without the define.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Exports require SVE and ELF at comptime and the export_kernels option.
//   Other builds do not emit these instructions.
// - The below-16 path is selected at comptime per CPU model
//   (src/aarch64/tuning.zig): the upstream predicated SVE store (.sve),
//   or the advsimd store tree (.neon) inverted so that 1..3 bytes fall
//   through every branch (predicted-taken branches dominate at these
//   sizes). Everything at 16 and above is upstream in both variants.

const builtin = @import("builtin");
const options = @import("fastmem_options");
const instance = @import("instance.zig");
const tuning = @import("tuning.zig");

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    builtin.cpu.has(.aarch64, .sve);

// Upstream: entry, 16..64 block, and the predicated store below 16.
const body_sve =
    \\    dup    v0.16B, w1
    \\    cmp    x2, 16
    \\    b.lo    .Lfm_sve_set_16
    \\
    \\    add    x4, x0, x2
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_set_128
    \\
    \\    // Set 16..64 bytes.
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
    \\.Lfm_sve_set_16:
    \\    whilelo p0.b, xzr, x2
    \\    st1b    z0.b, p0, [x0]
    \\    ret
    \\
;

// Neon variant: the below-16 store tree from memset-advsimd.S (same
// pinned commit), inverted so 1..3 bytes fall through. The >= 16
// blocks are upstream, reordered so the > 64 check comes first and
// keeps its single taken branch. Every store is sized to the count, so
// guard-page tails stay safe. The n == 0 test sits at the top: this
// body is the Neoverse V1 default, and V1 needs n == 0 cheap (the .sve
// body's empty-predicate SVE store measured 1.91x compiler-rt there,
// run 20260924T102308Z-p3-arm-small). Every other class pays one
// not-taken cbz; per-class branch counts are unchanged.
const body_neon =
    \\    cbz    x2, .Lfm_sve_set_ret0
    \\    dup    v0.16B, w1
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_set_128
    \\    cmp    x2, 16
    \\    b.hs    .Lfm_sve_set_ge16
    \\
    \\    add    x4, x0, x2
    \\    cmp    x2, 4
    \\    b.hs    .Lfm_sve_set_ge4
    \\    lsr    x3, x2, 1
    \\    strb    w1, [x0]
    \\    strb    w1, [x0, x3]
    \\    strb    w1, [x4, -1]
    \\.Lfm_sve_set_ret0:
    \\    ret
    \\
    \\    // Set 4..15 bytes.
    \\.Lfm_sve_set_ge4:
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
    \\.Lfm_sve_set_ge16:
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
    \\.Lfm_sve_set_128:
    \\    add    x4, x0, x2
    \\
;

// The 65..128 block and the long path, upstream. The neon body enters
// with x4 and x3 computed; the sve body computed them in its entry.
const tail_sve =
    \\    .p2align 4
    \\.Lfm_sve_set_128:
    \\
;

const tail_common =
    \\    bic    x3, x0, 15
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_set_long
    \\    stp    q0, q0, [x0]
    \\    stp    q0, q0, [x0, 32]
    \\    stp    q0, q0, [x4, -64]
    \\    stp    q0, q0, [x4, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\.Lfm_sve_set_long:
    \\    cmp    x2, 256
    \\    b.lo    .Lfm_sve_set_no_zva
    \\    tst    w1, 255
    \\    b.ne    .Lfm_sve_set_no_zva
    \\
    \\    mrs    x5, dczid_el0
    \\    and    x5, x5, 31
    \\    cmp    x5, 4        // ZVA size is 64 bytes.
    \\    b.ne    .Lfm_sve_set_no_zva
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
    \\.Lfm_sve_set_zva64_loop:
    \\    add    x3, x3, 64
    \\    dc    zva, x3
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_set_zva64_loop
    \\    ret
    \\
    \\.Lfm_sve_set_no_zva:
    \\    str    q0, [x0]
    \\    sub    x2, x4, x3    // Count is 16 too large.
    \\    sub    x2, x2, #(64 + 16)    // Adjust count and bias for loop.
    \\.Lfm_sve_set_no_zva_loop:
    \\    stp    q0, q0, [x3, 16]
    \\    stp    q0, q0, [x3, 48]
    \\    add    x3, x3, 64
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_set_no_zva_loop
    \\    stp    q0, q0, [x4, -64]
    \\    stp    q0, q0, [x4, -32]
    \\    ret
    \\
;

const body = switch (tuning.set_small) {
    .sve => body_sve ++ tail_sve,
    .neon => body_neon,
} ++ tail_common;

comptime {
    if (enabled and options.export_kernels)
        @export(&setEntry, .{ .name = "fastmem_sve_set", .visibility = .hidden });
}

pub fn setEntry() align(64) callconv(.naked) void {
    asm volatile (instance.instanced(
            ".arch armv8-a+sve\n    hint 34\n" ++ body,
        ) ::: .{ .memory = true });
}

pub const fastmem_sve_set: *const fn ([*]u8, u8, usize) callconv(.c) void = @ptrCast(&setEntry);
