//! Independent implementation of the behavioral design in x86_64-design.md.
const builtin = @import("builtin");

const compact = @import("compact.zig");
const ops = @import("ops.zig");
const w = ops.width;
const V = ops.Vector;
const tuning = @import("tuning.zig");
const t = tuning.selected;

const tail_call = if (builtin.zig_backend == .stage2_llvm) .always_tail else .auto;
const source_loop = t.copy_source_min != null or t.fwd_source_min != null;
// Keep the temporal loops in the same kernel on both sides of dispatch.
const temporal_call = if (source_loop) .always_inline else .auto;
pub const Overlap = enum { may_overlap, disjoint };

inline fn pair(comptime T: type, dst: [*]u8, src: [*]const u8, n: usize) void {
    const a = ops.load(T, src);
    const b = ops.load(T, src + n - @sizeOf(T));
    ops.store(T, dst, a);
    ops.store(T, dst + n - @sizeOf(T), b);
}

pub inline fn small(comptime max: u32, dst: [*]u8, src: [*]const u8, n: usize) bool {
    if (n > max) return false;
    if (n >= w) {
        if (n <= 2 * w) {
            pair(V, dst, src, n);
        } else if (n <= 4 * w) {
            const a = ops.load(V, src);
            const b = ops.load(V, src + w);
            const c = ops.load(V, src + n - 2 * w);
            const d = ops.load(V, src + n - w);
            ops.store(V, dst, a);
            ops.store(V, dst + w, b);
            ops.store(V, dst + n - 2 * w, c);
            ops.store(V, dst + n - w, d);
        } else {
            const a = ops.load(V, src);
            const b = ops.load(V, src + w);
            const c = ops.load(V, src + 2 * w);
            const d = ops.load(V, src + 3 * w);
            const e = ops.load(V, src + n - 4 * w);
            const f = ops.load(V, src + n - 3 * w);
            const g = ops.load(V, src + n - 2 * w);
            const h = ops.load(V, src + n - w);
            ops.store(V, dst, a);
            ops.store(V, dst + w, b);
            ops.store(V, dst + 2 * w, c);
            ops.store(V, dst + 3 * w, d);
            ops.store(V, dst + n - 4 * w, e);
            ops.store(V, dst + n - 3 * w, f);
            ops.store(V, dst + n - 2 * w, g);
            ops.store(V, dst + n - w, h);
        }
    } else if (w == 64 and n >= 32) {
        pair(@Vector(32, u8), dst, src, n);
    } else if (n >= 16) {
        pair(@Vector(16, u8), dst, src, n);
    } else if (n >= 8) {
        pair(u64, dst, src, n);
    } else if (n >= 4) {
        pair(u32, dst, src, n);
    } else if (n >= 2) {
        pair(u16, dst, src, n);
    } else if (n == 1) {
        dst[0] = src[0];
    }
    return true;
}

// Move-only classes avoid duplicate compact transfers on dependent calls.
// Copy retains its measured entry and inline ladder.
pub inline fn moveSmall(comptime max: u32, dst: [*]u8, src: [*]const u8, n: usize) bool {
    if (n <= 3 and n <= max) {
        if (n != 0) compact.bytes(dst, src, n);
        return true;
    }
    if (n > max) return false;
    if (n >= 64) return small(max, dst, src, n);
    if (n <= 16) {
        if (n >= 8) {
            pair(u64, dst, src, n);
        } else {
            pair(u32, dst, src, n);
        }
    } else if (n <= 32) {
        pair(@Vector(16, u8), dst, src, n);
    } else {
        if (comptime tuning.available) {
            pair(@Vector(32, u8), dst, src, n);
        } else {
            const a = ops.load(@Vector(16, u8), src);
            const b = ops.load(@Vector(16, u8), src + 16);
            const c = ops.load(@Vector(16, u8), src + n - 32);
            const d = ops.load(@Vector(16, u8), src + n - 16);
            ops.store(@Vector(16, u8), dst, a);
            ops.store(@Vector(16, u8), dst + 16, b);
            ops.store(@Vector(16, u8), dst + n - 32, c);
            ops.store(@Vector(16, u8), dst + n - 16, d);
        }
    }
    return true;
}

pub noinline fn moveKernel(
    dst: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) align(t.abi_alignment) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    // Shared candidate bodies keep level objects identical after LLVM merges aliases.
    if (comptime tuning.entry_pairs and ops.high_available) return copyPairs(dst, src, n);
    if (comptime ops.high_available and (t.medium_first or tuning.medium_entry)) {
        if (n >= 64) return mediumReordered(dst, src, n);
    }
    // Zero permits null pointers, so form only non-optional pointers after it.
    if (n <= 3) {
        if (n != 0) {
            if (comptime tuning.zen4_short) {
                if (n == 1) {
                    const d: [*]u8 = @ptrCast(dst.?);
                    const s: [*]const u8 = @ptrCast(src.?);
                    d[0] = s[0];
                    return dst;
                }
            }
            compact.bytes(@ptrCast(dst.?), @ptrCast(src.?), n);
        }
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n >= 64) {
        @branchHint(.unlikely);
        if (comptime ops.high_available) return mediumReordered(dst, src, n);
        if (!small(8 * w, d, s, n)) return @call(tail_call, largeKernel, .{ dst, src, n });
        return dst;
    }
    if (n <= 16) {
        if (n >= 8) {
            pair(u64, d, s, n);
        } else {
            pair(u32, d, s, n);
        }
    } else if (n <= 32) {
        pair(@Vector(16, u8), d, s, n);
    } else {
        if (comptime ops.high_available) {
            ops.highMove(32, 2, d, s, n);
        } else {
            pair(@Vector(32, u8), d, s, n);
        }
    }
    return dst;
}

pub inline fn move(comptime overlap: Overlap, dst: [*]u8, src: [*]const u8, n: usize) void {
    if (comptime overlap == .may_overlap) {
        if (moveSmall(tuning.inline_max, dst, src, n)) return;
        _ = moveKernel(dst, src, n);
        return;
    }
    // A short-first decision skips the vector ladder without new scalar classes.
    if (comptime tuning.inline_short_first) {
        if (n < 16 and n <= tuning.inline_max) {
            _ = small(16, dst, src, n);
            return;
        }
    }
    if (small(tuning.inline_max, dst, src, n)) return;
    if (overlap == .disjoint) {
        // The disjoint specialization omits the direction test, but retains alias dispatch.
        copyLarge(dst, src, n);
    } else {
        _ = kernel(dst, src, n);
    }
}

// The ABI memcpy entry requires disjoint buffers, unlike moveKernel.
pub noinline fn kernel(
    dst: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) align(t.abi_alignment) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (comptime tuning.entry_pairs and ops.high_available)
        return copyPairs(dst, src, n);
    if (comptime tuning.reordered and ops.high_available) return reordered(dst, src, n);
    if (n <= 16) {
        if (n == 0) return dst;
        const d: [*]u8 = @ptrCast(dst.?);
        const s: [*]const u8 = @ptrCast(src.?);
        if (n >= 8) {
            pair(u64, d, s, n);
        } else if (n >= 4) {
            pair(u32, d, s, n);
        } else if (n >= 2) {
            pair(u16, d, s, n);
        } else {
            d[0] = s[0];
        }
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n <= 32) {
        pair(@Vector(16, u8), d, s, n);
        return dst;
    }
    if (comptime ops.high_available) {
        if (n > 512) return @call(.always_tail, largeKernel, .{ dst, src, n });
        if (n < 64) {
            ops.highMove(32, 2, d, s, n);
        } else if (n <= 128) {
            ops.highMove(64, 2, d, s, n);
        } else if (n <= 256) {
            ops.highMove(64, 4, d, s, n);
        } else {
            ops.highMove(64, 8, d, s, n);
        }
        return dst;
    }
    return @call(tail_call, mediumKernel, .{ dst, src, n });
}

// This copy candidate keeps the measured medium-first tree and entry alignment.
// Its small classes match the move pairs without a new wrapper around moveKernel.
inline fn copyPairs(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (n >= 64) {
        @branchHint(if (tuning.medium_fallthrough) .likely else .unlikely);
        return mediumReordered(dst, src, n);
    }
    if (n <= 3) {
        @branchHint(.unlikely);
        if (n != 0) compact.bytes(@ptrCast(dst.?), @ptrCast(src.?), n);
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n <= 16) {
        if (n >= 8) {
            pair(u64, d, s, n);
        } else {
            pair(u32, d, s, n);
        }
    } else if (n <= 32) {
        @branchHint(.likely);
        pair(@Vector(16, u8), d, s, n);
    } else {
        ops.highMove(32, 2, d, s, n);
    }
    return dst;
}

// These experiments retain the measured large policy and all inline classes.
inline fn reordered(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (comptime t.medium_first or tuning.medium_entry) {
        if (n >= 64) {
            @branchHint(.likely);
            return mediumReordered(dst, src, n);
        }
    }
    const short_limit = if (tuning.compact_short) 15 else 16;
    if (n <= short_limit) {
        if (tuning.compact_short) {
            if (n >= 4) {
                compact.quad(u32, @ptrCast(dst.?), @ptrCast(src.?), n);
            } else if (n != 0) {
                compact.bytes(@ptrCast(dst.?), @ptrCast(src.?), n);
            }
        } else {
            if (n >= 8) {
                pair(u64, @ptrCast(dst.?), @ptrCast(src.?), n);
            } else if (n >= 4) {
                pair(u32, @ptrCast(dst.?), @ptrCast(src.?), n);
            } else if (comptime tuning.short_scalar) {
                if (n == 1) {
                    const d: [*]u8 = @ptrCast(dst.?);
                    const s: [*]const u8 = @ptrCast(src.?);
                    d[0] = s[0];
                } else if (n != 0) {
                    pair(u16, @ptrCast(dst.?), @ptrCast(src.?), n);
                }
            } else if (n != 0) {
                compact.bytes(@ptrCast(dst.?), @ptrCast(src.?), n);
            }
        }
        return dst;
    }
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n < 64) {
        @branchHint(if (tuning.medium_layout) .unlikely else .none);
        if (tuning.compact_short or tuning.short_scalar) {
            compact.quad(@Vector(16, u8), d, s, n);
        } else if (n <= 32) {
            pair(@Vector(16, u8), d, s, n);
        } else {
            ops.highMove(32, 2, d, s, n);
        }
    } else {
        return mediumReordered(dst, src, n);
    }
    return dst;
}

inline fn mediumReordered(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (comptime tuning.medium_chunks) return mediumChunks(dst, src, n);
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n <= 128) {
        ops.highMove(t.medium_vec, 128 / t.medium_vec, d, s, n);
    } else if (n <= 256) {
        ops.highMove(t.medium_vec, 256 / t.medium_vec, d, s, n);
    } else if (n <= 512) {
        ops.highMove(64, 8, d, s, n);
    } else if (t.abi_move_max == 1024 and n <= 1024) {
        ops.highMove(64, 16, d, s, n);
    } else {
        return @call(.always_tail, largeKernel, .{ dst, src, n });
    }
    return dst;
}

inline fn mediumChunks(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (n <= 128) {
        ops.highMove(t.medium_vec, 128 / t.medium_vec, d, s, n);
    } else if (n <= 256) {
        ops.highMove(t.medium_vec, 256 / t.medium_vec, d, s, n);
    } else if (n <= 512) {
        if (tuning.medium_chunks and n <= 384) {
            ops.highMove(64, 6, d, s, n);
        } else {
            ops.highMove(64, 8, d, s, n);
        }
    } else if (t.abi_move_max == 1024 and n <= 1024) {
        if (tuning.medium_chunks and n <= 768) {
            ops.highMove(64, 12, d, s, n);
        } else {
            ops.highMove(64, 16, d, s, n);
        }
    } else {
        return @call(.always_tail, largeKernel, .{ dst, src, n });
    }
    return dst;
}

noinline fn mediumKernel(
    dst: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    if (!small(8 * w, d, s, n))
        return @call(tail_call, largeKernel, .{ dst, src, n });
    return dst;
}

// The matching return convention permits a tail transfer from the leaf entry.
noinline fn largeKernel(
    dst: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (comptime source_loop) return largeBody(.may_overlap, @ptrCast(dst.?), @ptrCast(src.?), n);
    large(.may_overlap, @ptrCast(dst.?), @ptrCast(src.?), n);
    return dst;
}

noinline fn copyLarge(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    if (!small(8 * w, dst, src, n)) {
        if (comptime source_loop) {
            _ = largeBody(.disjoint, dst, src, n);
        } else {
            large(.disjoint, dst, src, n);
        }
    }
}

// Keep the original void call graph on models without a source-aligned loop.
fn large(comptime overlap: Overlap, dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    largeBody(overlap, dst, src, n);
}

inline fn largeBody(
    comptime overlap: Overlap,
    dst: [*]u8,
    src: [*]const u8,
    n: usize,
) if (source_loop) ?*anyopaque else void {
    const distance = @intFromPtr(dst) -% @intFromPtr(src);
    if (overlap == .may_overlap) {
        if (distance == 0) return if (source_loop) dst else {};
        if (distance < n) {
            @call(temporal_call, backward, .{ dst, src, n });
            return if (source_loop) dst else {};
        }
    }
    const source_inside = overlap == .may_overlap and @intFromPtr(src) -% @intFromPtr(dst) < n;
    if (t.rep_movsb_min) |threshold| {
        // The gap override permits H8 without the short-distance REP penalty.
        const rep_overlap = if (t.rep_fwd_gap_min) |gap|
            @intFromPtr(src) -% @intFromPtr(dst) >= gap
        else
            false;
        const rep_size = n > threshold and (t.nt_min == null or n < t.nt_min.?);
        if ((!source_inside or rep_overlap) and rep_size) {
            const head = ops.load(V, src);
            const address = if (distance & t.rep_src_align_mask == 0)
                @intFromPtr(src)
            else
                @intFromPtr(dst);
            const skip = w - (address & (w - 1));
            ops.repMove(dst + skip, src + skip, n - skip);
            ops.store(V, dst, head);
            return if (source_loop) dst else {};
        }
    }
    if (t.nt_min) |threshold| {
        if (!source_inside and n >= threshold) {
            stream(dst, src, n);
            return if (source_loop) dst else {};
        }
    }
    if (t.copy_source_min) |threshold| {
        // This model uses forward traversal for cache-sized disjoint copies.
        // The NT check above still owns disjoint sizes above its threshold.
        if (!source_inside and n >= threshold) return @call(
            if (overlap == .may_overlap) tail_call else .auto,
            forwardSource,
            .{ @as(?*anyopaque, @ptrCast(dst)), @as(?*const anyopaque, @ptrCast(src)), n },
        );
    }
    if (t.fwd_source_min) |threshold| {
        // NT and reverse traversal cannot serve an overlap. Keep its loads aligned.
        if (source_inside and n >= threshold) return @call(
            if (overlap == .may_overlap) tail_call else .auto,
            forwardSource,
            .{ @as(?*anyopaque, @ptrCast(dst)), @as(?*const anyopaque, @ptrCast(src)), n },
        );
    }
    // A source inside the destination requires forward traversal, even with a 4K alias.
    if (!source_inside and distance & t.alias_mask == 0) {
        @call(temporal_call, backward, .{ dst, src, n });
        return if (source_loop) dst else {};
    }
    @call(temporal_call, forward, .{ dst, src, n });
    return if (source_loop) dst else {};
}

fn forward(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const head = ops.load(V, src);
    const a = ops.load(V, src + n - 4 * w);
    const b = ops.load(V, src + n - 3 * w);
    const c = ops.load(V, src + n - 2 * w);
    const d = ops.load(V, src + n - w);
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset < n - 4 * w) : (offset += 4 * w) {
        const e = ops.load(V, src + offset);
        const f = ops.load(V, src + offset + w);
        const g = ops.load(V, src + offset + 2 * w);
        const h = ops.load(V, src + offset + 3 * w);
        ops.storeAligned(dst + offset, e);
        ops.storeAligned(dst + offset + w, f);
        ops.storeAligned(dst + offset + 2 * w, g);
        ops.storeAligned(dst + offset + 3 * w, h);
    }
    ops.store(V, dst + n - 4 * w, a);
    ops.store(V, dst + n - 3 * w, b);
    ops.store(V, dst + n - 2 * w, c);
    ops.store(V, dst + n - w, d);
    ops.store(V, dst, head);
}

// One vector per source iteration avoids the 2 KiB unroll of forward().
// The saved endpoints permit strict source alignment without out-of-range access.
noinline fn forwardSource(
    dest: ?*anyopaque,
    source: ?*const anyopaque,
    n: usize,
) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    const dst: [*]u8 = @ptrCast(dest.?);
    const src: [*]const u8 = @ptrCast(source.?);
    const head = ops.load(V, src);
    const tail_v = ops.load(V, src + n - w);
    var offset = w - (@intFromPtr(src) & (w - 1));
    while (offset < n - w) : (offset += w) {
        const value: V = @as(*align(w) const V, @ptrCast(@alignCast(src + offset))).*;
        ops.store(V, dst + offset, value);
    }
    ops.store(V, dst + n - w, tail_v);
    ops.store(V, dst, head);
    return dst;
}

fn backward(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const a = ops.load(V, src);
    const b = ops.load(V, src + w);
    const c = ops.load(V, src + 2 * w);
    const d = ops.load(V, src + 3 * w);
    const tail = ops.load(V, src + n - w);
    var end = n - ((@intFromPtr(dst) + n) & (w - 1));
    while (end > 4 * w) {
        end -= 4 * w;
        const e = ops.load(V, src + end);
        const f = ops.load(V, src + end + w);
        const g = ops.load(V, src + end + 2 * w);
        const h = ops.load(V, src + end + 3 * w);
        ops.storeAligned(dst + end, e);
        ops.storeAligned(dst + end + w, f);
        ops.storeAligned(dst + end + 2 * w, g);
        ops.storeAligned(dst + end + 3 * w, h);
    }
    ops.store(V, dst, a);
    ops.store(V, dst + w, b);
    ops.store(V, dst + 2 * w, c);
    ops.store(V, dst + 3 * w, d);
    ops.store(V, dst + n - w, tail);
}

fn stream(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    if (comptime tuning.nt_copy_pages and ops.high_available) return streamPages(dst, src, n);
    ops.store(V, dst, ops.load(V, src));
    var offset = w - (@intFromPtr(dst) & (w - 1));
    while (offset <= n - 4 * w) : (offset += 4 * w) {
        if (offset + 8 * w < n) @prefetch(src + offset + 8 * w, .{ .rw = .read, .locality = 3 });
        const a = ops.load(V, src + offset);
        const b = ops.load(V, src + offset + w);
        const c = ops.load(V, src + offset + 2 * w);
        const d = ops.load(V, src + offset + 3 * w);
        ops.streamStore(dst + offset, a);
        ops.streamStore(dst + offset + w, b);
        ops.streamStore(dst + offset + 2 * w, c);
        ops.streamStore(dst + offset + 3 * w, d);
    }
    ops.fence();
    _ = small(8 * w, dst + n - 4 * w, src + n - 4 * w, 4 * w);
}

// Independent 8 KiB tiles use four cache lines from each page per step.
// The extra 512-byte bound keeps every prefetch inside the source interval.
noinline fn streamPages(dst: [*]u8, src: [*]const u8, n: usize) void {
    @disableIntrinsics();
    const page = 4096;
    ops.store(V, dst, ops.load(V, src));
    var offset: u64 = w - (@intFromPtr(dst) & (w - 1));
    while (n - offset >= 2 * page + 512) : (offset += 2 * page) {
        ops.streamCopyPages(dst + offset, src + offset);
    }
    // The temporal remainder can overlap the last streamed cache line.
    ops.fence();
    while (offset < n - w) : (offset += w) {
        ops.storeAligned(dst + offset, ops.load(V, src + offset));
    }
    ops.store(V, dst + n - w, ops.load(V, src + n - w));
}

/// The dispatch layer handles every size through its small limit before this entry.
pub noinline fn kernelAboveSmall(
    dst: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) align(t.abi_alignment) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n <= tuning.dispatch_small_max) unreachable;
    if (comptime ops.high_available) return mediumReordered(dst, src, n);
    if (!small(8 * w, @ptrCast(dst.?), @ptrCast(src.?), n))
        return @call(tail_call, largeKernel, .{ dst, src, n });
    return dst;
}
