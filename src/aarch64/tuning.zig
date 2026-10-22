//! Comptime tuning table for the aarch64 kernels: which small-size
//! (<= 64 byte) path the SVE kernels use, per CPU model.
//!
//! Variants for copy/move (the kernels share the small path, like AOR's
//! aliased memmove entry):
//! - sve:    the AOR memcpy-sve.S predicated pair for 0..2*VL
//!           (whilelo/ld1b/st1b; 0..64 on V1's 256-bit VL, 0..32 on
//!           V2/V3's 128-bit VL).
//! - neon:   the AOR memcpy-advsimd.S tbz tree for 0..15, one
//!           overlapping 16-byte pair for 16..32, then the unchanged
//!           mid block above 32. Fixed boundaries, no cntb/whilelo.
//! - hybrid: the tbz tree below 16, the SVE predicated pair for
//!           16..2*VL.
//! - hybrid_n32: the tbz tree below 16, one overlapping 16-byte NEON
//!   pair for 16..31, the SVE predicated pair for 32..2*VL. A fleet
//!   experiment for V1 move (not a default anywhere): the V1 predicated
//!   pair measures 4.7-5.7 ns under the gap31 profiles at 24..31 (and
//!   bwd at 16..31) where the NEON pair runs 1.16 ns; the 32 test sits
//!   after the 2*VL test so 65..128 stays byte-identical to main
//!   (docs/slop/results/armh-graviton-gaps.md).
//! - hybrid_ft: the SVE predicated pair for 16..2*VL with the >= 16
//!   class on the fall-through and the tree out of line (the 1..3 class
//!   pays the taken branch). A fleet experiment for the V1 move
//!   96..128 gap to glibc's memmove entry; expected to fail G3 at 1..3
//!   (docs/slop/results/armh-graviton-gaps.md).
//!
//! Move selects its small path independently. Its NEON head transfers exactly
//! one vector at 16 bytes. The rejected plain NEON pair wrote the same bytes twice.
//! The previous hybrid head did not duplicate that store.
//! The candidate improves local V3 calls at 16–32 bytes.
//! V1 retains the hybrid head after the NEON candidate regressed fleet measurements.
//! V2/V3 retain the new NEON classes. Evidence appears in docs/slop/results/scorecard.md.
//!
//! For set:
//! - sve:    the AOR memset-sve.S predicated store below 16.
//! - neon:   the AOR memset-advsimd.S store tree below 16, inverted so
//!           1..3 bytes fall through every branch.
//!
//! The neon/hybrid tree blocks reuse the small-size classes of the
//! in-tree advsimd ports (same upstream files, same pinned commit, same
//! license); every access in them is sized to the count, so guard-page
//! tails stay safe.
//!
//! Evidence for the per-model defaults: docs/slop/results/aor-g2-graviton.md
//! (run 20260924T064442Z-aor-g2). Below 16 bytes, compiler-rt's
//! scalar/NEON small path beats the SVE predicated pair on Neoverse V3
//! (fastmem_abi/builtin copy 1.50, move 1.40) and ties on V2
//! (copy 1.00, move 1.07), while the SVE pair wins on V1 (copy 0.87).
//! The fleet A/Bs variants as separate revisions that flip these
//! defaults; the -Dsmall-copy / -Dsmall-set build options override them
//! for local runs.

const std = @import("std");
const mem = std.mem;
const aarch64_cpu = std.Target.aarch64.cpu;
const stringToEnum = std.meta.stringToEnum;
const builtin = @import("builtin");

const options = @import("fastmem_options");

pub const CopySmall = enum { sve, neon, hybrid, hybrid_n32, hybrid_ft };
pub const SetSmall = enum { sve, neon };

const on_neoverse_v1 = builtin.cpu.model == &aarch64_cpu.neoverse_v1;
const on_neoverse_v2 = builtin.cpu.model == &aarch64_cpu.neoverse_v2;
// memcpy_sve.zig reads this for the V3 copy-head layout.
pub const on_neoverse_v3 = builtin.cpu.model == &aarch64_cpu.neoverse_v3;

// V1 (c7g): the SVE small paths lose to the tree there. The predicated
// pair costs 2.05-2.45x compiler-rt on the gap1 1..3 B move cases
// (wide masked stores do not forward to the next iteration's narrow
// loads) and ~2x at n == 0 across all three ops (empty-predicate SVE
// memory ops still cost the chain), and the predicated set store
// measures 1.26x glibc at 0-16 B while the inlined tree beats glibc
// 2-3x on the same rows (run 20260924T102308Z-p3-arm-small). Move
// keeps the SVE pair at 16..2*VL (64 on V1): it beats compiler-rt's
// stack-spilling 16..63 class there (fwd-gap1/16: 0.61x builtin).
// V2 (c8g): the tree below 16 fixes the gap1 1..3 B move stalls
// (3.86x compiler-rt with the SVE pair) and the flat 1.02-1.05x at
// copy 1..3 B; hybrid also swaps the 33..64 mid block for the neon
// mid entry, which lost to compiler-rt on V2 in that form
// (copy/aligned/48: 1.15x). V2 set stays sve: 1.000 vs both
// references at every size.
// Fleet A/B p3-armc (docs/slop/results/p3-armc.md): hybrid copy on V1/V2
// lost (c8g copy 17-64 B 1.12x glibc, c7g copy 65-256 B 1.06x), so copy
// keeps the SVE pair there; move and set follow the A/B winners.
const default_copy_small: CopySmall = if (on_neoverse_v3) .neon else .sve;
// V1 retains its SVE pair through 2*VL after the NEON regression in
// bench-results/20260926T085954Z-smallmove (docs/slop/results/scorecard.md).
// V2/V3 retain the NEON classes and the exact-16 transfer.
const default_move_small: CopySmall = if (on_neoverse_v1)
    .hybrid
else if (on_neoverse_v2 or on_neoverse_v3)
    .neon
else
    .sve;
const default_set_small: SetSmall = if (on_neoverse_v3) .neon else .sve;

// The 33..64 shape of the move entry's neon mid block. pair is the
// upstream ldp/stp shape (what glibc runs); chunk is the 4x16-byte
// block. V3 keeps chunk: the pair block measured +25% at
// move/fwd-half/48 on this host while no V3 move goal row needed it
// (its gap*/64 rows sit at 1.05-1.09, under the 1.10 case bar). V2
// takes pair as the candidate for its fleet-measured move
// bwd-gap31/64 = 1.129x glibc (run 20260926T112106Z-smallmove-v1);
// fleet-unverifiable locally, so the A/B read-first list names it.
// Only consulted when the move head is neon.
pub const MidKind = enum { chunk, pair };
pub const move_mid: MidKind = if (on_neoverse_v3) .chunk else .pair;

pub const copy_small: CopySmall = blk: {
    if (mem.eql(u8, options.small_copy, "auto")) break :blk default_copy_small;
    break :blk stringToEnum(CopySmall, options.small_copy) orelse
        @compileError("unknown -Dsmall-copy value: " ++ options.small_copy);
};

pub const move_small: CopySmall = blk: {
    if (mem.eql(u8, options.small_move, "auto")) break :blk default_move_small;
    break :blk stringToEnum(CopySmall, options.small_move) orelse
        @compileError("unknown -Dsmall-move value: " ++ options.small_move);
};

// Mid-entry alias for the inline layer's > 64 byte copy/move calls
// (fastmem_sve_copy_gt64 in memcpy_sve.zig): enter the shared mid block
// directly, skipping the head's small-size dispatch. The skipped branches
// are predicted-taken on every > 64 call; a predicted-taken branch is
// measurable on Neoverse V2 at benchmark loop scale (the abi trampoline
// cost 1.283x on c8g set 0-16, docs/slop/results/small-path-aarch64b.md).
// Neutral on V3 locally; the fleet decides V1/V2. -Dmid-entry overrides
// for local runs.
pub const mid_entry: bool = blk: {
    if (mem.eql(u8, options.mid_entry, "auto")) break :blk default_mid_entry;
    if (mem.eql(u8, options.mid_entry, "on")) {
        // The alias lives in the neon mid block of the SVE kernels;
        // without a neon head the block is not emitted and the option
        // would be a silent no-op. Other targets ignore the option.
        const on_sve = builtin.cpu.arch == .aarch64 and
            builtin.cpu.has(.aarch64, .sve);
        if (on_sve and copy_small != .neon and move_small != .neon)
            @compileError("-Dmid-entry=on needs a neon copy or move head");
        break :blk true;
    }
    if (mem.eql(u8, options.mid_entry, "off")) break :blk false;
    @compileError("unknown -Dmid-entry value: " ++ options.mid_entry);
};

const default_mid_entry = false;

pub const set_small: SetSmall = blk: {
    if (mem.eql(u8, options.small_set, "auto")) break :blk default_set_small;
    break :blk stringToEnum(SetSmall, options.small_set) orelse
        @compileError("unknown -Dsmall-set value: " ++ options.small_set);
};
