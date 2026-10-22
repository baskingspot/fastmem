//! The generic C-ABI kernels and byte fill. They run where no dedicated
//! kernel applies, and at the `generic` level of the x86_64 runtime
//! dispatch. They call the generic implementations directly, never the
//! public API: under dispatch the public API calls back through the
//! dispatch pointers.
const std = @import("std");
const mem = std.mem;

const memcpy_impl = @import("memcpy.zig");
const memmove_impl = @import("memmove.zig");

pub fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n == 0) return dest;
    const d: [*]u8 = @ptrCast(dest.?);
    const s: [*]const u8 = @ptrCast(src.?);
    memcpy_impl.copy(u8, d[0..n], s[0..n]);
    return dest;
}

pub fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n == 0) return dest;
    const d: [*]u8 = @ptrCast(dest.?);
    const s: [*]const u8 = @ptrCast(src.?);
    memmove_impl.move(u8, d[0..n], s[0..n]);
    return dest;
}

pub fn memset(dest: ?*anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    @disableIntrinsics();
    if (n == 0) return dest;
    setBytes(@ptrCast(dest.?), @truncate(@as(c_uint, @bitCast(c))), n);
    return dest;
}

// Portable fallback for targets without a dedicated kernel and for
// non-uniform fill values. Local intrinsic suppression prevents LLVM
// from replacing these loops with recursive memset calls.
pub fn setFallback(comptime T: type, dest: []T, value: T) void {
    @disableIntrinsics();
    if (comptime (T == u8)) return setBytes(dest.ptr, value, dest.len);
    for (dest) |*d| d.* = value;
}

/// The generic byte fill. Every size class stores an overlapping head and
/// tail, so no length reaches a byte-store loop (issue #1). The stores are
/// plain: the module builds with no_builtin and this function disables
/// intrinsics, so LLVM cannot turn them back into a memset call.
pub fn setBytes(d: [*]u8, value: u8, len: usize) void {
    @disableIntrinsics();
    const V16 = @Vector(16, u8);
    const V32 = @Vector(32, u8);
    // Targets without SIMD registers or fast unaligned stores (for example
    // riscv64 baseline) still lower these stores to bytes. They are not
    // fastmem targets; x86_64 baseline and aarch64 get real vector stores.
    if (len >= 64) {
        const v: V32 = @splat(value);
        var i: usize = 0;
        while (i + 64 <= len) : (i += 64) {
            @as(*align(1) V32, @ptrCast(d + i)).* = v;
            @as(*align(1) V32, @ptrCast(d + i + 32)).* = v;
        }
        // The last 64 bytes, overlapping the loop's final block.
        @as(*align(1) V32, @ptrCast(d + len - 64)).* = v;
        @as(*align(1) V32, @ptrCast(d + len - 32)).* = v;
    } else if (len >= 32) {
        const v: V32 = @splat(value);
        @as(*align(1) V32, @ptrCast(d)).* = v;
        @as(*align(1) V32, @ptrCast(d + len - 32)).* = v;
    } else if (len >= 16) {
        const v: V16 = @splat(value);
        @as(*align(1) V16, @ptrCast(d)).* = v;
        @as(*align(1) V16, @ptrCast(d + len - 16)).* = v;
    } else if (len >= 8) {
        const w: u64 = @as(u64, value) * 0x0101010101010101;
        mem.writeInt(u64, d[0..8], w, .little);
        mem.writeInt(u64, d[len - 8 ..][0..8], w, .little);
    } else if (len >= 4) {
        const w: u32 = @as(u32, value) * 0x01010101;
        mem.writeInt(u32, d[0..4], w, .little);
        mem.writeInt(u32, d[len - 4 ..][0..4], w, .little);
    } else if (len > 0) {
        d[0] = value;
        d[len >> 1] = value;
        d[len - 1] = value;
    }
}
