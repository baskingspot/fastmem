// memcpy - copy memory area
//
// Copyright (c) 2019-2023, Arm Limited.
// SPDX-License-Identifier: MIT OR Apache-2.0 WITH LLVM-exception
//
// Ported from ARM-software/optimized-routines string/aarch64/memcpy-sve.S
// @ 5e20a93f440ca771bcdb757cc13c3beee217e534 (includes 23c4393006122497,
// "Improve __memcpy_aarch64_sve": the cntb hoist and .p2align layout).
// The neon/hybrid small-path variants reuse the tbz tree of
// string/aarch64/memcpy-advsimd.S at the same pinned commit (already
// ported in memcpy_advsimd.zig).
//
// Port notes (the only intentional differences from upstream):
// - Naked Zig functions and @export replace the ENTRY, ALIAS, and END macros.
//   The compiler emits symbol types, sizes, and hidden visibility.
//   Register aliases become architectural names. `instance.zig` tags every
//   local label with the package instance id, because all inline assembly of
//   one binary shares one label namespace (two fastmem copies in one link).
// - Symbols are renamed __memcpy_aarch64_sve -> fastmem_sve_copy and
//   __memmove_aarch64_sve -> fastmem_sve_move and given .hidden visibility.
//   The entries export only when fastmem_options.export_kernels is set; the
//   kernel-bytes pin sets it. A consumer copy exports nothing.
// - The GNU_PROPERTY note (BTI/PAC marking of the linked binary) is
//   omitted: it is link-level metadata, and no other object in a Zig
//   link carries it. The BTI landing pad (`hint 34`) is kept.
// - Immediate expressions are written #( ...); upstream writes them
//   bare. Both forms assemble to the same bytes.
// - Each entry retains 64-byte alignment. The instruction bytes match the
//   earlier assembly kernels, including padding after a separate move head.
// - Exports require SVE and ELF at comptime and the export_kernels option.
//   Other builds do not emit these instructions.
// - The small-size paths (count <= 64) are selected at comptime per CPU
//   model (src/aarch64/tuning.zig), separately for the copy and move
//   entries. .sve is the upstream predicated pair for 0..2*VL and the
//   upstream mid block; .neon replaces <= 32 with the tbz tree (0..15,
//   laid out so 1..3 bytes fall through every branch) and one
//   overlapping 16-byte pair for 16..32, then shares the neon mid block
//   (33..64 in the upstream ldp/stp pair shape for copy; the chunk or
//   pair shape for move, per tuning.move_mid); .hybrid is the tree
//   below 16 and the SVE pair for 16..2*VL. The move NEON head uses one
//   exact transfer at 16 bytes. It has a separate entry even when copy
//   also selects NEON. Other equal variants share an entry. Both heads
//   branch into the shared mid/long blocks. Everything above 64 bytes
//   is upstream in all variants.
//
// Why the non-sve heads exist: on Neoverse V3 the predicated SVE pair
// loses to plain NEON/scalar code below 32 bytes (fleet run
// 20260924T064442Z-aor-g2: fastmem_abi/builtin copy 1.50, move 1.40 at
// 0-16), and predicted-taken branches dominate the smallest classes, so
// the tree is laid out to minimize taken branches per class, not
// instruction count.

const std = @import("std");
const comptimePrint = std.fmt.comptimePrint;
const mem = std.mem;
const builtin = @import("builtin");

const options = @import("fastmem_options");

const instance = @import("instance.zig");
const tuning = @import("tuning.zig");
const copy_v = tuning.copy_small;
const move_v = tuning.move_small;

const enabled = builtin.cpu.arch == .aarch64 and
    builtin.target.ofmt == .elf and
    builtin.cpu.has(.aarch64, .sve);

// The move NEON head has an exact 16-byte class, unlike copy.
// The NEON-headed and hybrid_n32 move entries have classes the copy
// entry lacks (exact-16; the NEON 16..32 block), so they never alias.
const aliased = copy_v == move_v and move_v != .neon and move_v != .hybrid_n32;
// The hybrid head routes n > 2*VL straight to the SVE mid block (its
// 128-byte check sits in the head), so hybrid needs mid_sve too.
const need_sve_mid = copy_v != .neon or move_v != .neon;
const need_neon_mid = copy_v == .neon or move_v == .neon;
// The neon mid block's 33..64 shape for the copy entry and the gt64
// alias is the pair block. The move entry gets its own 33..64 block
// when tuning.move_mid says chunk (V3: the pair block measured +25% at
// move/fwd-half/48 there while the chunk block passes every V3 move
// goal row; V2 takes the pair block as the candidate for its
// fleet-measured bwd-gap31/64 = 1.129x glibc).
const move_mid_chunk = tuning.move_mid == .chunk and move_v == .neon;
// Neoverse V3 copy: the neon head ends in the 16..32 test laid out so
// that n > 32 falls through into the mid block instead of branching to
// it. One fewer predicted-taken branch at 33..128 and above (the mid
// block itself was 1.25x glibc at misaligned/48 after the pair swap
// with both taken branches in place). Only valid when mid_neon follows
// the copy head directly, which needs the SVE mid absent.
const v3_copy_fallthrough = tuning.on_neoverse_v3 and copy_v == .neon and !need_sve_mid;

// The V3 copy fall-through dispatches 96/64 itself (ge16 checks 128)
// and uses a 65..128 tail split at 96 bytes: each sub-class runs its
// own self-contained block, so neither pays the other's boundary
// compare (the single-block shape puts a taken b.ls on 65..96 and a
// not-taken one on 97..128, on top of the entry branch). That brings
// the copy fall-through at 97..128 to 20 instructions and 2 taken
// branches against the 21/2 of glibc's __memcpy_sve (fleet c9g copy
// misaligned/cross-lane 127 measured 1.09-1.13x glibc in run
// 20260927T162241Z-final-standard; the data path is already
// instruction-identical, so the gap was dispatch overhead). The
// gt32/mov_gt32 entries keep the single upstream block: routing them
// through the split would cost the move path one taken branch at
// 97..128 (review of 0cb3bf3), and with the split gated to the
// fall-through, V2's bytes are identical to main.

// Upstream small head: one predicated pair covers 0..2*VL.
const head_sve =
    \\    cntb    x6
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, x6, lsl 1
    \\    b.hi    .Lfm_sve_cpy32_128
    \\
    \\    whilelo p0.b, xzr, x2
    \\    whilelo p1.b, x6, x2
    \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
    \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
    \\    st1b    z0.b, p0, [x0, 0, mul vl]
    \\    st1b    z1.b, p1, [x0, 1, mul vl]
    \\    ret
    \\
;

// The 0..15 fallthrough tree shared by the neon and hybrid heads,
// entered with the n < 16 test already done: testing small first keeps
// 1..3 bytes at zero predicted-taken branches and 15 instructions
// (compiler-rt's memmove runs 14 at 1..3; the extra one is the BTI
// landing pad). The previous layout ran the 128/32/16 range checks
// first, which put 20 instructions on the 1..3 path and measured
// 1.333x compiler-rt there on Neoverse V3 (fleet run
// 20260924T102308Z-p3-arm-small, copy and move at every 1..3 profile).
// Classes are ordered so the smallest sizes fall through (tbz tree of
// memcpy-advsimd.S, inverted). Every access is sized to the count, so
// guard-page tails stay safe; all loads precede all stores within a
// class, so overlapping moves stay correct. The end pointers (x4/x5)
// are computed inside the 4..15 classes instead of hoisted: the 1..3
// class derives its tail index from the count directly.
fn tree(comptime p: []const u8) []const u8 {
    return comptimePrint(
        \\    tbnz    x2, 3, .Lfm_sve_{s}_ge8
        \\    tbnz    x2, 2, .Lfm_sve_{s}_ge4
        \\    cbz    x2, .Lfm_sve_{s}_ret0
        \\    lsr    x14, x2, 1
        \\    sub    x15, x2, 1
        \\    ldrb    w6, [x1]
        \\    ldrb    w8, [x1, x14]
        \\    ldrb    w10, [x1, x15]
        \\    strb    w6, [x0]
        \\    strb    w8, [x0, x14]
        \\    strb    w10, [x0, x15]
        \\    ret
        \\.Lfm_sve_{s}_ge4:
        \\    add    x4, x1, x2
        \\    ldr    w6, [x1]
        \\    ldr    w8, [x4, -4]
        \\    add    x5, x0, x2
        \\    str    w6, [x0]
        \\    str    w8, [x5, -4]
        \\    ret
        \\.Lfm_sve_{s}_ge8:
        \\    add    x4, x1, x2
        \\    ldr    x6, [x1]
        \\    ldr    x7, [x4, -8]
        \\    add    x5, x0, x2
        \\    str    x6, [x0]
        \\    str    x7, [x5, -8]
        \\    ret
        \\.Lfm_sve_{s}_ret0:
        \\    ret
        \\
    , .{ p, p, p, p, p, p });
}

// Neon head: the tree first (n < 16), then fixed boundaries, no
// cntb/whilelo. 16..32 is one overlapping 16-byte pair. Testing small
// first costs one extra predicted-taken branch at 33..128 (the n >= 16
// branch); the 1..3 class is the one the fleet shows failing G3, so
// the trade goes this way.
fn headNeon(comptime p: []const u8) []const u8 {
    // The rejected plain NEON pair duplicated this store. The old hybrid head did not.
    if (comptime mem.eql(u8, p, "mov")) return comptimePrint(
        \\    cmp x2, 16
        \\    b.hs .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_mov_ge16:
        \\    cmp x2, 32
        \\    b.hi {s}
        \\    ldr q0, [x1]
        \\    cmp x2, 16
        \\    b.eq .Lfm_sve_mov_one
        \\    add x4, x1, x2
        \\    ldur q1, [x4, -16]
        \\    add x5, x0, x2
        \\    str q0, [x0]
        \\    stur q1, [x5, -16]
        \\    ret
        \\.Lfm_sve_mov_one:
        \\    str q0, [x0]
        \\    ret
        \\
    , .{if (move_mid_chunk) ".Lfm_sve_mov_gt32" else ".Lfm_sve_cpy_gt32"});
    if (comptime (mem.eql(u8, p, "cpy") and v3_copy_fallthrough))
        // Inverted 32 test: 16..32 branches out, 33+ falls through into
        // the mid block, which copyEntry must emit immediately after.
        // ge16 is exactly 16 bytes of pure dispatch (the 32 and 128
        // tests), so the mid96 entry lands 16-aligned with no padding on
        // the fall-through path. le32 computes its own end pointers: the
        // hoisted adds used to serve it from ge16, where every n > 32
        // call paid for them, and mid96 recomputes them because the
        // gt64 alias contract allows only x0-x2 on entry.
        return comptimePrint(
            \\    cmp    x2, 16
            \\    b.hs    .Lfm_sve_{s}_ge16
            \\
        , .{p}) ++ tree(p) ++ comptimePrint(
            \\    .p2align 4
            \\.Lfm_sve_{s}_le32:
            \\    add    x4, x1, x2
            \\    ldr    q0, [x1]
            \\    ldr    q1, [x4, -16]
            \\    add    x5, x0, x2
            \\    str    q0, [x0]
            \\    str    q1, [x5, -16]
            \\    ret
            \\
            \\    .p2align 4
            \\.Lfm_sve_{s}_ge16:
            \\    cmp    x2, 32
            \\    b.ls    .Lfm_sve_{s}_le32
            \\    cmp    x2, 128
            \\    b.hi    .Lfm_sve_cpy_long
        , .{ p, p, p });
    return comptimePrint(
        \\    cmp    x2, 16
        \\    b.hs    .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_{s}_ge16:
        \\    cmp    x2, 32
        \\    b.hi    .Lfm_sve_cpy_gt32
        \\    add    x4, x1, x2
        \\    ldr    q0, [x1]
        \\    ldr    q1, [x4, -16]
        \\    add    x5, x0, x2
        \\    str    q0, [x0]
        \\    str    q1, [x5, -16]
        \\    ret
        \\
    , .{p});
}

// Hybrid head: the tree below 16, the predicated SVE pair for
// 16..2*VL. The cntb sits in the >= 16 block: the tree never needs it.
// The >= 16 block checks 128 before 2*VL and routes (2*VL, 128]
// straight to the SVE mid block. Review tracing of the armg change
// (docs/slop/results/armg-mid-paths.md) shows this changes nothing at
// 65..128 — the old neon mid entry's re-checks exactly offset the new
// cmp — and buys one taken branch plus two instructions only at
// > 128 (V1 fleet rows move/disjoint,fwd-gap4096/256 measured 1.09x
// glibc in run 20260926T112106Z-smallmove-v1). The remaining 65..128
// gap to glibc's memmove is the tree-first cmp 16/b.hs itself; the
// alternative head with >= 16 on the fall-through is untried because
// c7g move 1..3 sits at exactly 1.000x compiler-rt with no margin for
// its taken branch. The pair path pays one not-taken cmp; glibc's
// memmove entry checks 128 first too.
fn headHybrid(comptime p: []const u8) []const u8 {
    return comptimePrint(
        \\    cmp    x2, 16
        \\    b.hs    .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_{s}_ge16:
        \\    cntb    x6
        \\    cmp    x2, 128
        \\    b.hi    .Lfm_sve_cpy_long
        \\    cmp    x2, x6, lsl 1
        \\    b.hi    .Lfm_sve_cpy32_128
        \\    whilelo p0.b, xzr, x2
        \\    whilelo p1.b, x6, x2
        \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
        \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
        \\    st1b    z0.b, p0, [x0, 0, mul vl]
        \\    st1b    z1.b, p1, [x0, 1, mul vl]
        \\    ret
        \\
    , .{p});
}

// Hybrid head with a NEON 16..31 class (tuning.CopySmall.hybrid_n32):
// the tree below 16, one overlapping 16-byte pair at 16..31 (the move
// flavor keeps its exact-16 single transfer), the SVE pair at 32..2*VL.
// The 32 test sits after the 2*VL test, so 65..128 executes
// byte-identically to main (review of ce61677: the b.ls shape added two
// instructions to those rows, which already fail G2 on c7g) and n = 32
// keeps the SVE pair (fleet fwd-gap31/32: inline NEON 6.15 ns vs the
// abi pair's 5.59).
// Motivation: on Neoverse V1 the predicated pair at 16..31 costs
// 4.7-5.7 ns per call under the gap31 profiles (its masked stores do
// not forward and the cost varies with lane count and address
// alignment), where the inline layer's NEON pair runs the same cases in
// 1.16 ns (fleet run 20260927T162241Z-final-standard: c7g move
// fwd-gap31/24 = 5.61 ns abi vs 1.16 inline; glibc's __memmove_sve runs
// the identical SVE pair and pays the same, so only G3 breaks). The
// 33..2*VL pays one extra not-taken cmp32/b.lo pair; the 33+
// fall-through is otherwise unchanged. Not the default anywhere; the
// fleet A/Bs it on V1 (branch fleet3/armh-move-neon32,
// docs/slop/results/armh-graviton-gaps.md).
fn headHybridN32(comptime p: []const u8) []const u8 {
    const pair = if (comptime mem.eql(u8, p, "mov"))
        // Move flavor: one exact transfer at 16 bytes, like the neon
        // move head.
        \\    ldr    q0, [x1]
        \\    cmp    x2, 16
        \\    b.eq    .Lfm_sve_{s}_one
        \\    add    x4, x1, x2
        \\    ldur    q1, [x4, -16]
        \\    add    x5, x0, x2
        \\    str    q0, [x0]
        \\    stur    q1, [x5, -16]
        \\    ret
        \\.Lfm_sve_{s}_one:
        \\    str    q0, [x0]
        \\    ret
        \\
    else
        \\    add    x4, x1, x2
        \\    ldr    q0, [x1]
        \\    ldr    q1, [x4, -16]
        \\    add    x5, x0, x2
        \\    str    q0, [x0]
        \\    str    q1, [x5, -16]
        \\    ret
        \\
    ;
    return comptimePrint(
        \\    cmp    x2, 16
        \\    b.hs    .Lfm_sve_{s}_ge16
        \\
    , .{p}) ++ tree(p) ++ comptimePrint(
        \\    .p2align 4
        \\.Lfm_sve_{s}_ge16:
        \\    cntb    x6
        \\    cmp    x2, 128
        \\    b.hi    .Lfm_sve_cpy_long
        \\    cmp    x2, x6, lsl 1
        \\    b.hi    .Lfm_sve_cpy32_128
        \\    cmp    x2, 32
        \\    b.lo    .Lfm_sve_{s}_n31
        \\    whilelo p0.b, xzr, x2
        \\    whilelo p1.b, x6, x2
        \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
        \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
        \\    st1b    z0.b, p0, [x0, 0, mul vl]
        \\    st1b    z1.b, p1, [x0, 1, mul vl]
        \\    ret
        \\
        \\    .p2align 4
        \\.Lfm_sve_{s}_n31:
    , .{ p, p, p }) ++ comptimePrint(pair, .{ p, p });
}

// Hybrid head with the >= 16 class on the fall-through
// (tuning.CopySmall.hybrid_ft): `b.lo` sends 0..15 to the out-of-line
// tree, so 16..2*VL and the mid/long dispatch run with zero
// predicted-taken branches in the head — glibc's __memmove_sve budget.
// The price is one taken branch on the 1..3 class, which sits at
// exactly 1.000x compiler-rt on c7g; p3-armc measured that shape at
// 1.33x on V3 (docs/slop/results/small-path-aarch64c.md). Untried on V1:
// armg left it as the next measurement for the c7g move
// disjoint/fwd-gap4096 96..128 rows (1.10-1.21x glibc in run
// 20260927T162241Z-final-standard), where the tree-first head pays
// cmp16/b.hs over glibc's entry. Fleet branch fleet3/armh-v1move-ft;
// reject if the 1..3 rows break as predicted.
fn headHybridFt(comptime p: []const u8) []const u8 {
    // No .p2align before ge16: after bti/cmp/b.lo it would emit one
    // nop on the >= 16 fall-through, paid by every mid-size call
    // (review of b45e58d). ge16 needs no alignment of its own.
    return comptimePrint(
        \\    cmp    x2, 16
        \\    b.lo    .Lfm_sve_{s}_tree
        \\.Lfm_sve_{s}_ge16:
        \\    cntb    x6
        \\    cmp    x2, 128
        \\    b.hi    .Lfm_sve_cpy_long
        \\    cmp    x2, x6, lsl 1
        \\    b.hi    .Lfm_sve_cpy32_128
        \\    whilelo p0.b, xzr, x2
        \\    whilelo p1.b, x6, x2
        \\    ld1b    z0.b, p0/z, [x1, 0, mul vl]
        \\    ld1b    z1.b, p1/z, [x1, 1, mul vl]
        \\    st1b    z0.b, p0, [x0, 0, mul vl]
        \\    st1b    z1.b, p1, [x0, 1, mul vl]
        \\    ret
        \\
        \\    .p2align 4
        \\.Lfm_sve_{s}_tree:
        \\
    , .{ p, p, p }) ++ tree(p);
}

fn head(comptime v: tuning.CopySmall, comptime p: []const u8) []const u8 {
    return switch (v) {
        .sve => head_sve,
        .neon => headNeon(p),
        .hybrid => headHybrid(p),
        .hybrid_n32 => headHybridN32(p),
        .hybrid_ft => headHybridFt(p),
    };
}

// Upstream mid block (33..128 via the 2*VL boundary), used by sve heads.
const mid_sve =
    \\
    \\    // Medium copies: 33..128 bytes.
    \\.Lfm_sve_cpy32_128:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy128
    \\    stp    q0, q1, [x0]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\
    \\    // Copy 65..128 bytes.
    \\.Lfm_sve_cpy128:
    \\    ldp    q4, q5, [x1, 32]
    \\    cmp    x2, 96
    \\    b.ls    .Lfm_sve_cpy96
    \\    ldp    q6, q7, [x4, -64]
    \\    stp    q6, q7, [x5, -64]
    \\.Lfm_sve_cpy96:
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// Neon mid block. 33..64 for the copy entry and the gt64 alias is the
// upstream ldp/stp pair shape (the same shape glibc's __memcpy_sve runs
// at these sizes): the earlier 4x16-byte chunk block lost to it under
// misalignment on Neoverse V3 (copy/misaligned/48 at 1.50x glibc in
// bench-results/20260926T112106Z-smallmove-v1; the pair shape runs the
// same 4.00 cycles as glibc locally). The trade, disclosed in
// docs/slop/results/armg-mid-paths.md: under 4K aliasing at exactly 64 bytes
// the pair block runs a few percent above compiler-rt's loop-class
// entry (local V3: aligned/64 1.05x, page-offset/64 1.10x), while the
// chunk block beats compiler-rt there — G2's misaligned failures were
// 1.2-1.5x, so copy pays the smaller side. The move entry keeps the
// chunk block on V3 (tuning.move_mid): the pair block measured +25% at
// move/fwd-half/48 there, and no V3 move goal row needed it. 65..128 is
// split at 96 into two self-contained blocks (each recomputes x4/x5 and
// reloads its registers): hoisting those above the 64 check measured
// 3-7% slower at 127-128 in review, and the single-block shape put the
// 96-boundary compare on both sub-class paths. The gt32 entry must stay
// 16-aligned: the move heads branch here (the V3 copy head instead
// falls through into mid96 above it, off its 16-byte ge16 block).
const mid_neon = (if (v3_copy_fallthrough) mid_neon_v3_entry else "") ++
    mid_neon_pair ++
    (if (move_mid_chunk) mid_neon_move_chunk else "") ++
    mid_neon_tail ++
    (if (v3_copy_fallthrough) mid_neon_v3_tail else "");

// Fall-through target of the V3 copy head's ge16: n in 33..128 with
// the 128 check already done. Dispatches 96/64 and runs the 33..64 pair
// block on the fall-through. At 97..128 this path executes 20
// instructions with 2 taken branches against the 21/2 of glibc's
// __memcpy_sve (fleet c9g copy misaligned/cross-lane 127 sat at
// 1.09-1.13x glibc with an instruction-identical data path — the gap
// was dispatch overhead, see docs/slop/results/armh-graviton-gaps.md). Only
// this fall-through uses the split tail; gt32/mov_gt32 keep the single
// upstream 65..128 block so the move path stays byte-identical to main.
const mid_neon_v3_entry =
    \\
    \\    .p2align 4
    \\.Lfm_sve_cpy_mid96:
    \\    cmp    x2, 96
    \\    b.hi    .Lfm_sve_cpy97_128
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy65_96
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    stp    q0, q1, [x0]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// The > 64 byte entry used by the inline layer (tuning.mid_entry). The
// instance id makes the label unique: every module of one binary shares
// one assembler label namespace. A consumer copy keeps the label local;
// the kernel-bytes pin exports it (fastmem_options.export_kernels).
const gt64_name = "fastmem_sve_copy_gt64_" ++ instance.id;
const gt64_directives = if (options.export_kernels)
    "    .globl  " ++ gt64_name ++ "\n    .hidden " ++ gt64_name ++ "\n"
else
    "";

const mid_neon_pair_head =
    \\
    \\    .p2align 4
    \\    // Entry for the inline layer's > 64 byte calls (tuning.mid_entry):
    \\    // skips the head's small-size dispatch, which the inline gate has
    \\    // already decided. Valid for any n > 64 and any overlap: the
    \\    // 33..128 blocks load before they store, and > 128 still routes
    \\    // to the long path's backward/forward dispatch. Label only; no
    \\    // instruction bytes added.
;

const mid_neon_pair = mid_neon_pair_head ++ "\n" ++ gt64_directives ++
    gt64_name ++ ":\n" ++
    \\.Lfm_sve_cpy_gt32:
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy65_128
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    stp    q0, q1, [x0]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// The V3 move mid entry: same dispatch, then the 4x16-byte chunk block
// (loads at 0, 16, n-32, n-16). Loads precede stores; valid for any
// overlap. Branches share the 65..128 block and the long path.
const mid_neon_move_chunk =
    \\    .p2align 4
    \\.Lfm_sve_mov_gt32:
    \\    cmp    x2, 128
    \\    b.hi    .Lfm_sve_cpy_long
    \\    cmp    x2, 64
    \\    b.hi    .Lfm_sve_cpy65_128
    \\    add    x4, x1, x2
    \\    ldr    q0, [x1]
    \\    ldr    q1, [x1, 16]
    \\    ldr    q2, [x4, -32]
    \\    ldr    q3, [x4, -16]
    \\    add    x5, x0, x2
    \\    str    q0, [x0]
    \\    str    q1, [x0, 16]
    \\    str    q2, [x5, -32]
    \\    str    q3, [x5, -16]
    \\    ret
    \\
;

// 65..128 for the gt32/mov_gt32 entries: the single upstream block,
// keeping the move path byte-identical to main (the split below costs
// the move entries one taken branch at 97..128 — review of 0cb3bf3).
// The split blocks serve only mid96, the V3 copy fall-through: each
// sub-class runs its own block, so 97..128 pays no boundary compare and
// 65..96 pays no taken b.ls. All blocks load every register before any
// store, so the move entries that share them stay correct for any
// overlap.
const mid_neon_tail =
    \\    .p2align 4
    \\    // Copy 65..128 bytes.
    \\.Lfm_sve_cpy65_128:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    ldp    q4, q5, [x1, 32]
    \\    cmp    x2, 96
    \\    b.ls    .Lfm_sve_cpy96n
    \\    ldp    q6, q7, [x4, -64]
    \\    stp    q6, q7, [x5, -64]
    \\.Lfm_sve_cpy96n:
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

const mid_neon_v3_tail =
    \\    .p2align 4
    \\    // Copy 65..96 bytes (from mid96).
    \\.Lfm_sve_cpy65_96:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    ldp    q4, q5, [x1, 32]
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\    // Copy 97..128 bytes (from mid96).
    \\.Lfm_sve_cpy97_128:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\    ldp    q0, q1, [x1]
    \\    ldp    q2, q3, [x4, -32]
    \\    ldp    q4, q5, [x1, 32]
    \\    ldp    q6, q7, [x4, -64]
    \\    stp    q6, q7, [x5, -64]
    \\    stp    q0, q1, [x0]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q2, q3, [x5, -32]
    \\    ret
    \\
;

// Copy more than 128 bytes (upstream, shared by all heads).
const long_path =
    \\
    \\    // Copy more than 128 bytes.
    \\.Lfm_sve_cpy_long:
    \\    add    x4, x1, x2
    \\    add    x5, x0, x2
    \\
    \\    // Use backwards copy if there is an overlap.
    \\    sub    x6, x0, x1
    \\    cmp    x6, x2
    \\    b.lo    .Lfm_sve_cpy_long_backwards
    \\
    \\    // Copy 16 bytes and then align src to 16-byte alignment.
    \\    ldr    q3, [x1]
    \\    and    x6, x1, 15
    \\    bic    x1, x1, 15
    \\    sub    x3, x0, x6
    \\    add    x2, x2, x6    // Count is now 16 too large.
    \\    ldp    q0, q1, [x1, 16]
    \\    str    q3, [x0]
    \\    ldp    q2, q3, [x1, 48]
    \\    subs    x2, x2, #(128 + 16)    // Test and readjust count.
    \\    b.ls    .Lfm_sve_cpy64_from_end
    \\.Lfm_sve_cpy_loop64:
    \\    stp    q0, q1, [x3, 16]
    \\    ldp    q0, q1, [x1, 80]
    \\    stp    q2, q3, [x3, 48]
    \\    ldp    q2, q3, [x1, 112]
    \\    add    x1, x1, 64
    \\    add    x3, x3, 64
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_cpy_loop64
    \\
    \\    // Write the last iteration and copy 64 bytes from the end.
    \\.Lfm_sve_cpy64_from_end:
    \\    ldp    q4, q5, [x4, -64]
    \\    stp    q0, q1, [x3, 16]
    \\    ldp    q0, q1, [x4, -32]
    \\    stp    q2, q3, [x3, 48]
    \\    stp    q4, q5, [x5, -64]
    \\    stp    q0, q1, [x5, -32]
    \\    ret
    \\
    \\    .p2align 4
    \\    nop
    \\
    \\    // Large backwards copy for overlapping copies.
    \\    // Copy 16 bytes and then align srcend to 16-byte alignment.
    \\.Lfm_sve_cpy_long_backwards:
    \\    cbz    x6, .Lfm_sve_cpy_return
    \\    ldr    q3, [x4, -16]
    \\    and    x6, x4, 15
    \\    bic    x4, x4, 15
    \\    sub    x2, x2, x6
    \\    ldp    q0, q1, [x4, -32]
    \\    str    q3, [x5, -16]
    \\    ldp    q2, q3, [x4, -64]
    \\    sub    x5, x5, x6
    \\    subs    x2, x2, 128
    \\    b.ls    .Lfm_sve_cpy64_from_start
    \\
    \\.Lfm_sve_cpy_loop64_backwards:
    \\    str    q1, [x5, -16]
    \\    str    q0, [x5, -32]
    \\    ldp    q0, q1, [x4, -96]
    \\    str    q3, [x5, -48]
    \\    str    q2, [x5, -64]!
    \\    ldp    q2, q3, [x4, -128]
    \\    sub    x4, x4, 64
    \\    subs    x2, x2, 64
    \\    b.hi    .Lfm_sve_cpy_loop64_backwards
    \\
    \\    // Write the last iteration and copy 64 bytes from the start.
    \\.Lfm_sve_cpy64_from_start:
    \\    ldp    q4, q5, [x1, 32]
    \\    stp    q0, q1, [x5, -32]
    \\    ldp    q0, q1, [x1]
    \\    stp    q2, q3, [x5, -64]
    \\    stp    q4, q5, [x0, 32]
    \\    stp    q0, q1, [x0]
    \\.Lfm_sve_cpy_return:
    \\    ret
    \\
;

// Both entries share the mid and long blocks. The shared section keeps
// the split move head adjacent to copy, including its original padding.
comptime {
    if (enabled and options.export_kernels) {
        @export(&move_entry, .{ .name = "fastmem_sve_move", .visibility = .hidden });
        @export(&copyEntry, .{ .name = "fastmem_sve_copy", .visibility = .hidden });
    }
}

pub const move_entry = if (aliased) copyEntry else splitMoveEntry;

fn splitMoveEntry() align(64) linksection(".text.fastmem_sve_pair") callconv(.naked) void {
    asm volatile (instance.instanced(".arch armv8-a+sve\n    hint 34\n" ++
            head(move_v, "mov") ++ ".p2align 6\n") ::: .{ .memory = true });
}

pub fn copyEntry() align(64) linksection(".text.fastmem_sve_pair") callconv(.naked) void {
    asm volatile (instance.instanced(".arch armv8-a+sve\n    hint 34\n" ++ head(copy_v, "cpy") ++
            (if (v3_copy_fallthrough) mid_neon else (if (need_sve_mid) mid_sve else "")) ++
            (if (v3_copy_fallthrough) "" else if (need_neon_mid) mid_neon else "") ++
            long_path) ::: .{ .memory = true });
}

pub const fastmem_sve_copy: *const fn (
    [*]u8,
    [*]const u8,
    usize,
) callconv(.c) void = @ptrCast(&copyEntry);
pub const fastmem_sve_move: *const fn (
    [*]u8,
    [*]const u8,
    usize,
) callconv(.c) void = @ptrCast(&move_entry);

// Present only when the neon mid block is emitted (some head is not
// .sve). root.zig references it behind `has_gt64_entry` at comptime.
pub const has_gt64_entry = enabled and need_neon_mid;
comptime {
    // The mid label lives inside copyEntry. A hidden keepalive symbol keeps
    // the entry in the object when an inline-layer call is its only
    // reference; a bare `&copyEntry` does not force codegen. The name
    // carries the instance id, so two package copies do not collide. The
    // kernel-bytes pin references the entry by name instead.
    if (has_gt64_entry and tuning.mid_entry and !options.export_kernels) {
        @export(&copyEntry, .{
            .name = "copy_entry_keep_" ++ instance.id,
            .visibility = .hidden,
        });
    }
}
const Gt64Fn = *const fn ([*]u8, [*]const u8, usize) callconv(.c) void;
pub const fastmem_sve_copy_gt64: Gt64Fn = if (has_gt64_entry)
    @extern(Gt64Fn, .{ .name = gt64_name })
else
    undefined;
