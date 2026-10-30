const std = @import("std");
const assert = std.debug.assert;

const common = @import("common.zig");

/// Comptime tuning of the forward loop, one entry per call site (memcpy.zig,
/// memmove.zig).
// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const Options = struct {
    tight_loop: bool = true,
    medium_straight_line: bool = false,
    align_peel_min_bytes: usize = common.stride,
};

/// Forward loop for non-overlapping copies and overlap-safe forward moves.
pub inline fn run(
    comptime options: Options,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    @disableIntrinsics();
    var d = dest;
    var s = src;
    var remaining = len;

    if (remaining < common.stride) return common.copySmall(d, s, remaining);

    // Keep the exact hot tiers out of the generic loop so the common
    // benchmarked sizes do not pay extra branch/update overhead.
    if (remaining == common.stride) {
        common.storeVn(
            common.vectors_per_stride,
            d,
            0,
            common.loadVn(common.vectors_per_stride, s, 0),
        );
        return;
    }
    // The 2-stride exact tier is a win on 16-byte-vector targets, but it
    // regresses the AVX2 256B misaligned and cross-lane copy cases.
    if (common.chunk_bytes == 16 and remaining == common.stride * 2) {
        const head = common.loadVn(common.vectors_per_stride, s, 0);
        const tail = common.loadVn(common.vectors_per_stride, s, remaining - common.stride);
        common.storeVn(common.vectors_per_stride, d, 0, head);
        common.storeVn(common.vectors_per_stride, d, remaining - common.stride, tail);
        return;
    }

    // On targets where LLVM generates a bloated loop body, bypass the
    // loop for medium sizes with straight-line loads then stores.
    // All loads complete before any stores — safe for overlapping regions.
    if (options.medium_straight_line) {
        if (remaining <= common.stride) {
            common.storeVn(
                common.vectors_per_stride,
                d,
                0,
                common.loadVn(common.vectors_per_stride, s, 0),
            );
            return;
        }
        if (remaining <= common.stride * 2) {
            const head = common.loadVn(common.vectors_per_stride, s, 0);
            const tail = common.loadVn(common.vectors_per_stride, s, remaining - common.stride);
            common.storeVn(common.vectors_per_stride, d, 0, head);
            common.storeVn(common.vectors_per_stride, d, remaining - common.stride, tail);
            return;
        }
    }

    // Align the hot loop only when enough work remains.
    if (remaining >= options.align_peel_min_bytes) {
        const mask = @as(usize, common.chunk_bytes - 1);
        const align_base = @intFromPtr(d);
        const loop_misalignment = align_base & mask;
        if (loop_misalignment > 0) {
            const prefix = @as(usize, common.chunk_bytes) - loop_misalignment;
            common.copySmall(d, s, prefix);
            d += prefix;
            s += prefix;
            remaining -= prefix;
        }
    }

    if (remaining < common.stride) return common.copySmall(d, s, remaining);
    copyLargeForward(options, d, s, remaining);
}

inline fn copyLargeForward(
    comptime options: Options,
    dest: [*]u8,
    src: [*]const u8,
    len: usize,
) void {
    @disableIntrinsics();
    assert(len >= common.stride);

    if (options.tight_loop) {
        // Pointer bumping: known models produce tight codegen.
        var d = dest;
        var s = src;
        var remaining = len;
        while (remaining >= common.stride) {
            common.storeVn(
                common.vectors_per_stride,
                d,
                0,
                common.loadVn(common.vectors_per_stride, s, 0),
            );
            d += common.stride;
            s += common.stride;
            remaining -= common.stride;
        }
        if (remaining > 0) common.copySmall(d, s, remaining);
    } else {
        // Single offset: generic targets produce bloated codegen with
        // multiple induction variables; a single offset keeps the loop
        // body smaller.
        var off: usize = 0;
        while (off + common.stride <= len) : (off += common.stride) {
            common.storeVn(
                common.vectors_per_stride,
                dest + off,
                0,
                common.loadVn(common.vectors_per_stride, src + off, 0),
            );
        }
        const remaining = len - off;
        if (remaining > 0) common.copySmall(dest + off, src + off, remaining);
    }
}
