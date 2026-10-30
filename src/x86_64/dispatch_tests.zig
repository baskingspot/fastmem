//! Run-time dispatch checks. Each test runs every level that this CPU
//! supports (under qemu-x86_64: generic and x86_64_v3).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const print = std.debug.print;
const fastmem = @import("../root.zig");
const dispatch = fastmem.dispatch;
const Level = dispatch.Level;

fn pattern(bytes: []u8, seed: u64) void {
    @disableIntrinsics();
    for (bytes, 0..) |*byte, i| {
        var x: u64 = i +% seed *% 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        byte.* = @truncate(x ^ (x >> 31));
    }
}

const lengths = [_]u32{
    0,    1,    3,    4,    7,    8,    15,    16,    31,    32,    33,  63,
    64,   65,   127,  128,  129,  255,  256,   257,   511,   512,   513, 1023,
    1024, 1025, 2048, 4095, 4096, 4097, 16383, 16384, 16385, 65536,
};
const gaps = [_]u32{ 0, 1, 31, 64, 129, 4095, 4096 };
const capacity = 65536 + 4096 + 128;

/// Force each supported level and return the number of levels run.
fn eachLevel(comptime check: fn () anyerror!void) !usize {
    const detected = dispatch.level().?;
    defer dispatch.force(detected) catch unreachable;
    var count: usize = 0;
    for (std.enums.values(Level)) |l| {
        dispatch.force(l) catch continue;
        try testing.expectEqual(l, dispatch.level().?);
        check() catch |err| {
            print("dispatch level {s} failed\n", .{@tagName(l)});
            return err;
        };
        count += 1;
    }
    return count;
}

var original: [capacity]u8 = undefined;
var got: [capacity]u8 = undefined;
var expected: [capacity]u8 = undefined;

fn checkCopyAndSet() !void {
    pattern(&original, 1);
    for (lengths) |n| {
        for ([_]u32{ 0, 1, 33, 63 }) |offset| {
            @memset(&got, 0xa5);
            @memset(&expected, 0xa5);
            @memcpy(expected[offset..][0..n], original[0..n]);
            const r = fastmem.abi.memcpy(got[offset..].ptr, &original, n);
            try testing.expectEqual(@as(?*anyopaque, got[offset..].ptr), r);
            try testing.expectEqualSlices(u8, &expected, &got);

            @memset(&got, 0xa5);
            fastmem.copy(u8, got[offset..][0..n], original[0..n]);
            try testing.expectEqualSlices(u8, &expected, &got);

            @memset(expected[offset..][0..n], 0x3c);
            const r2 = fastmem.abi.memset(got[offset..].ptr, 0x13c, n);
            try testing.expectEqual(@as(?*anyopaque, got[offset..].ptr), r2);
            try testing.expectEqualSlices(u8, &expected, &got);

            @memset(expected[offset..][0..n], 0x7e);
            fastmem.set(u8, got[offset..][0..n], 0x7e);
            try testing.expectEqualSlices(u8, &expected, &got);
        }
    }
}

fn checkMove() !void {
    pattern(&original, 2);
    for (lengths) |n| {
        for (gaps) |gap| {
            if (n + gap > capacity) continue;
            for ([_]bool{ false, true }) |backward| {
                const source: usize = if (backward) 0 else gap;
                const dest: usize = if (backward) gap else 0;
                expected = original;
                @memcpy(expected[dest..][0..n], original[source..][0..n]);
                got = original;
                const r = fastmem.abi.memmove(got[dest..].ptr, got[source..].ptr, n);
                try testing.expectEqual(@as(?*anyopaque, got[dest..].ptr), r);
                try testing.expectEqualSlices(u8, &expected, &got);
                got = original;
                fastmem.move(u8, got[dest..][0..n], got[source..][0..n]);
                try testing.expectEqualSlices(u8, &expected, &got);
            }
        }
    }
}

test "dispatch: every supported level copies and fills" {
    try testing.expect(try eachLevel(checkCopyAndSet) >= 1);
}

test "dispatch: every supported level moves in both directions" {
    try testing.expect(try eachLevel(checkMove) >= 1);
}

test "dispatch: the ABI entries are the dispatch stubs" {
    const x86_dispatch = @import("dispatch.zig");
    try testing.expect(fastmem.abi.memcpy == &x86_dispatch.memcpy);
    try testing.expect(fastmem.abi.memmove == &x86_dispatch.memmove);
    try testing.expect(fastmem.abi.memset == &x86_dispatch.memset);
    try testing.expect(std.mem.startsWith(u8, fastmem.impl.copy, "x86-dispatch"));
}

test "dispatch: the detected level is supported and names its kernel" {
    const info = dispatch.detect().?;
    const detected = info.select();
    try testing.expect(info.supports(detected));
    if (!info.supports(.x86_64_v4))
        try testing.expectError(error.Unsupported, dispatch.force(.x86_64_v4));
    try testing.expect(dispatch.kernelName().?.len > 0);
    try dispatch.force(.generic);
    try testing.expectEqualStrings(
        if (dispatch.small_max == 64) "zig-simd+above64" else "zig-simd",
        dispatch.kernelName().?,
    );
    try dispatch.force(detected);
}

test "dispatch: large forward and backward overlaps at every supported level" {
    // Above the AMD NT threshold (0xc00001) and the Intel REP threshold, below
    // the Intel NT thresholds: every large branch of every level applies.
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const n: usize = 0xc00001 + 4097;
    const gap: usize = 4096 + 17;
    const buffer = try testing.allocator.alloc(u8, n + gap);
    defer testing.allocator.free(buffer);
    const want = try testing.allocator.alloc(u8, n + gap);
    defer testing.allocator.free(want);
    const Case = struct {
        var buf: []u8 = undefined;
        var ref: []u8 = undefined;
        fn run() !void {
            for ([_]bool{ false, true }) |backward| {
                const source: usize = if (backward) 0 else gap;
                const dest: usize = if (backward) gap else 0;
                pattern(buf, 3);
                @memcpy(ref, buf);
                @memmove(ref[dest..][0..n], ref[source..][0..n]);
                _ = fastmem.abi.memmove(buf[dest..].ptr, buf[source..].ptr, n);
                try testing.expect(std.mem.eql(u8, ref, buf));
            }
        }
    };
    Case.buf = buffer;
    Case.ref = want;
    try testing.expect(try eachLevel(Case.run) >= 1);
}
