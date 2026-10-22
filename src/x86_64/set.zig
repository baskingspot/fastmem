//! Byte fills with straight-line classes and model-specific large paths.
const builtin = @import("builtin");

const ops = @import("ops.zig");
const w = ops.width;
const V = ops.Vector;
const tuning = @import("tuning.zig");
const t = tuning.selected;

const tail_call = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;
inline fn pair(comptime width: u32, dst: [*]u8, value: u8, n: usize) void {
    const T = if (width < 16) @Int(.unsigned, width * 8) else @Vector(width, u8);
    const v: T = if (width < 16) (@as(T, @intCast(value)) * (~@as(T, 0) / 255)) else @splat(value);
    ops.store(T, dst, v);
    ops.store(T, dst + n - width, v);
}

pub inline fn small(
    comptime max: u32,
    comptime masked: bool,
    dst: [*]u8,
    value: u8,
    n: usize,
) bool {
    if (n > max) return false;
    if (n >= w) {
        const v: V = @splat(value);
        ops.store(V, dst, v);
        ops.store(V, dst + n - w, v);
        if (n > 2 * w) {
            ops.store(V, dst + w, v);
            ops.store(V, dst + n - 2 * w, v);
            if (n > 4 * w) {
                ops.store(V, dst + 2 * w, v);
                ops.store(V, dst + 3 * w, v);
                ops.store(V, dst + n - 3 * w, v);
                ops.store(V, dst + n - 4 * w, v);
            }
        }
    } else {
        if (comptime masked and tuning.small_masked_set and ops.mask_available and w == 64) {
            if (@intFromPtr(dst) & 0xfff <= 0xfc0) {
                ops.maskedSet(dst, value, n);
                return true;
            }
        }
        if (w == 64 and n >= 32) {
            pair(32, dst, value, n);
        } else if (n >= 16) {
            pair(16, dst, value, n);
        } else if (n >= 8) {
            pair(8, dst, value, n);
        } else if (n >= 4) {
            pair(4, dst, value, n);
        } else if (n >= 2) {
            pair(2, dst, value, n);
        } else if (n == 1) {
            dst[0] = value;
        }
    }
    return true;
}

pub inline fn set(dst: [*]u8, value: u8, n: usize) void {
    // The ladder also folds for constant-length slices, without a constant mask cost.
    if (!small(tuning.inline_max, false, dst, value, n)) _ = kernel(dst, value, n);
}

pub noinline fn kernel(
    dst: ?*anyopaque,
    value: c_int,
    n: usize,
) align(t.abi_alignment) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    const medium_first = t.medium_first or tuning.medium_entry;
    if (comptime medium_first and ops.high_available) {
        if (n >= 64) {
            @branchHint(.likely);
            return mediumReordered(dst, value, n);
        }
    }
    if (n <= 16) {
        if (n == 0) return dst;
        const d: [*]u8 = @ptrCast(dst.?);
        if (n >= 8) {
            pair(8, d, byte, n);
        } else if (n >= 4) {
            pair(4, d, byte, n);
        } else if (n >= 2) {
            pair(2, d, byte, n);
        } else {
            d[0] = byte;
        }
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    if (comptime tuning.reordered and ops.high_available) {
        if (n < 64) {
            @branchHint(if (tuning.medium_layout) .unlikely else .none);
            if (n <= 32) {
                pair(16, d, byte, n);
            } else {
                ops.highSet(32, 2, d, value, n);
            }
        } else {
            return mediumReordered(dst, value, n);
        }
        return dst;
    }
    if (n <= 32) {
        pair(16, d, byte, n);
        return dst;
    }
    if (comptime ops.high_available) {
        if (n > 512) return @call(.always_tail, largeKernel, .{ dst, value, n });
        if (n < 64) {
            ops.highSet(32, 2, d, value, n);
        } else if (n <= 128) {
            ops.highSet(64, 2, d, value, n);
        } else if (n <= 256) {
            ops.highSet(64, 4, d, value, n);
        } else {
            ops.highSet(64, 8, d, value, n);
        }
        return dst;
    }
    return @call(tail_call, mediumKernel, .{ dst, value, n });
}

inline fn mediumReordered(dst: ?*anyopaque, value: c_int, n: usize) ?*anyopaque {
    if (comptime tuning.medium_chunks) return mediumChunks(dst, value, n);
    const d: [*]u8 = @ptrCast(dst.?);
    if (n <= 128) {
        ops.highSet(t.medium_vec, 128 / t.medium_vec, d, value, n);
    } else if (n <= 256) {
        ops.highSet(t.medium_vec, 256 / t.medium_vec, d, value, n);
    } else if (n <= 512) {
        ops.highSet(64, 8, d, value, n);
    } else {
        return @call(.always_tail, largeKernel, .{ dst, value, n });
    }
    return dst;
}

inline fn mediumChunks(dst: ?*anyopaque, value: c_int, n: usize) ?*anyopaque {
    const d: [*]u8 = @ptrCast(dst.?);
    if (n <= 128) {
        ops.highSet(t.medium_vec, 128 / t.medium_vec, d, value, n);
    } else if (n <= 256) {
        ops.highSet(t.medium_vec, 256 / t.medium_vec, d, value, n);
    } else if (n <= 512) {
        if (tuning.medium_chunks and n <= 384) {
            ops.highSet(64, 6, d, value, n);
        } else {
            ops.highSet(64, 8, d, value, n);
        }
    } else if (tuning.medium_chunks and n <= 1024) {
        if (n <= 768) {
            ops.highSet(64, 12, d, value, n);
        } else {
            ops.highSet(64, 16, d, value, n);
        }
    } else {
        return @call(.always_tail, largeKernel, .{ dst, value, n });
    }
    return dst;
}

noinline fn mediumKernel(dst: ?*anyopaque, value: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const d: [*]u8 = @ptrCast(dst.?);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    if (!small(8 * w, true, d, byte, n))
        return @call(tail_call, largeKernel, .{ dst, value, n });
    return dst;
}

noinline fn largeKernel(dst: ?*anyopaque, value: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (comptime tuning.nt_set_grouped and ops.high_available) {
        if (t.memset_nt_min) |threshold| {
            if (n >= threshold) return @call(.always_tail, streamGrouped, .{ dst, value, n });
        }
    }
    large(@ptrCast(dst.?), @truncate(@as(c_uint, @bitCast(value))), n);
    return dst;
}

fn large(dst: [*]u8, value: u8, n: usize) void {
    @disableIntrinsics();
    if (comptime !(tuning.nt_set_grouped and ops.high_available)) {
        if (t.memset_nt_min) |threshold| {
            if (n >= threshold) return stream(dst, value, n);
        }
    }
    if (t.rep_stosb_min) |threshold| {
        if (n > threshold) return ops.repSet(dst, value, n);
    }
    const v: V = @splat(value);
    ops.store(V, dst, v);
    ops.store(V, dst + w, v);
    ops.store(V, dst + 2 * w, v);
    ops.store(V, dst + 3 * w, v);
    var offset = 4 * w - (@intFromPtr(dst) & (w - 1));
    if (comptime tuning.temporal_set_256 and ops.high_available) {
        if (offset < n - 4 * w) ops.temporalSetLoop(dst + offset, dst + n - 4 * w, v);
    } else {
        while (offset < n - 4 * w) : (offset += 4 * w) {
            ops.storeAligned(dst + offset, v);
            ops.storeAligned(dst + offset + w, v);
            ops.storeAligned(dst + offset + 2 * w, v);
            ops.storeAligned(dst + offset + 3 * w, v);
        }
    }
    ops.store(V, dst + n - 4 * w, v);
    ops.store(V, dst + n - 3 * w, v);
    ops.store(V, dst + n - 2 * w, v);
    ops.store(V, dst + n - w, v);
}

fn stream(dst: [*]u8, value: u8, n: usize) void {
    @disableIntrinsics();
    const v: V = @splat(value);
    ops.store(V, dst, v);
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset <= n - 4 * w) : (offset += 4 * w) {
        ops.streamStore(dst + offset, v);
        ops.streamStore(dst + offset + w, v);
        ops.streamStore(dst + offset + 2 * w, v);
        ops.streamStore(dst + offset + 3 * w, v);
    }
    ops.fence();
    ops.store(V, dst + n - 4 * w, v);
    ops.store(V, dst + n - 3 * w, v);
    ops.store(V, dst + n - 2 * w, v);
    ops.store(V, dst + n - w, v);
}

noinline fn streamGrouped(dest: ?*anyopaque, value: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const dst: [*]u8 = @ptrCast(dest.?);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    const v: V = @splat(byte);
    ops.store(V, dst, v);
    var offset: u64 = w - (@intFromPtr(dst) & (w - 1));
    while (n - offset >= 8 * w) : (offset += 8 * w) {
        ops.streamSetBlock(dst + offset, v);
    }
    // Order the NT stores before any overlapping temporal tail store.
    ops.fence();
    while (offset < n - w) : (offset += w) ops.storeAligned(dst + offset, v);
    ops.store(V, dst + n - w, v);
    return dest;
}

/// The dispatch layer handles every size through its small limit before this entry.
pub noinline fn kernelAboveSmall(
    dst: ?*anyopaque,
    value: c_int,
    n: usize,
) align(t.abi_alignment) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n <= tuning.dispatch_small_max) unreachable;
    if (comptime ops.high_available) return mediumReordered(dst, value, n);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    if (!small(8 * w, true, @ptrCast(dst.?), byte, n))
        return @call(tail_call, largeKernel, .{ dst, value, n });
    return dst;
}
