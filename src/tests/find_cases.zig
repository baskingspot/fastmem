//! Independent search oracle and synthetic fixtures shared by guard and fuzz tests.
const std = @import("std");
const math = std.math;
const testing = std.testing;

pub const needle_lengths = [_]u32{
    0,    1,   2,   3,   15,  16,  17,  31,  32,  33,  63,   64,   65,
    127,  128, 129, 254, 255, 256, 257, 511, 512, 513, 1023, 1024, 4095,
    4096,
};
pub const Pattern = enum {
    absent,
    first,
    middle,
    last,
    multiple,
    uniform,
    periodic,
    late_mismatch,
};

pub fn reference(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    @disableIntrinsics();
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |start| {
        // Keep Debug's long near-miss fixtures bounded without borrowing a search algorithm.
        if (haystack[start] != needle[0] or
            haystack[start + needle.len - 1] != needle[needle.len - 1]) continue;
        for (needle, 0..) |element, i| {
            if (haystack[start + i] != element) break;
        } else return start;
    }
    return null;
}

pub fn byteAt(seed: u64, index: u64) u8 {
    var x = seed +% index +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return @truncate(x ^ (x >> 31));
}

pub fn fill(bytes: []u8, seed: u64) void {
    for (bytes, 0..) |*byte, i| byte.* = byteAt(seed, i);
}

pub fn prepare(haystack: []u8, needle: []u8, pattern: Pattern, seed: u64) void {
    // These synthetic bytes are never secrets.
    fill(haystack, seed);
    fill(needle, seed ^ 0xd1b54a32d192ed03);
    switch (pattern) {
        .absent => {
            for (haystack) |*byte| byte.* &= 0x7f;
            for (needle) |*byte| byte.* |= 0x80;
        },
        .uniform => {
            @memset(haystack, 0xff);
            @memset(needle, 0xff);
        },
        .periodic, .late_mismatch => {
            for (haystack, 0..) |*byte, i| byte.* = if (i % 3 == 0) 0 else 0xfe;
            for (needle, 0..) |*byte, i| byte.* = if (i % 3 == 0) 0 else 0xfe;
            if (pattern == .late_mismatch and needle.len > 0) needle[needle.len - 1] = 0xfd;
        },
        else => {
            if (needle.len > haystack.len) return;
            const last = haystack.len - needle.len;
            const position = switch (pattern) {
                .first => 0,
                .middle => last / 2,
                .last, .multiple => last,
                else => unreachable,
            };
            @memcpy(haystack[position..][0..needle.len], needle);
            if (pattern == .multiple) {
                @memcpy(haystack[0..needle.len], needle);
                // Implanting a second, overlapping match may destroy the first.
                // The independent oracle, never the requested position, decides.
                if (needle.len < haystack.len)
                    @memcpy(haystack[1..][0..needle.len], needle);
            }
        },
    }
}

pub fn fixedNeedle(comptime len: u32) [len]u8 {
    @setEvalBranchQuota(100000);
    var result: [len]u8 = undefined;
    for (&result, 0..) |*byte, i| byte.* = @truncate(i *% 131);
    return result;
}

pub const Structured = enum {
    period1,
    period2,
    period3,
    near_period,
    prefix,
    suffix,
    collisions,
    rare_late,
};

pub fn prepareStructured(haystack: []u8, needle: []u8, kind: Structured) void {
    // Public, synthetic fixtures: no secret material.
    const period: u32 = switch (kind) {
        .period2 => 2,
        .period3, .near_period => 3,
        else => 1,
    };
    for (haystack, 0..) |*byte, i| byte.* = @intCast(i % period);
    for (needle, 0..) |*byte, i| byte.* = @intCast(i % period);
    if (needle.len == 0) return;
    switch (kind) {
        .near_period, .prefix, .rare_late => needle[needle.len - 1] = 0xff,
        .suffix => needle[0] = 0xff,
        .collisions => {
            @memset(haystack, 0x40);
            @memset(needle, 0xc0);
        },
        else => {},
    }
}

pub fn decodeBinary(bytes: []u8, bits: u32) void {
    for (bytes, 0..) |*byte, i| byte.* = @intCast((bits >> @intCast(i)) & 1);
}

test "oracle handles first matches and floating equality" {
    try testing.expectEqual(@as(?usize, 1), reference(u8, "banana", "ana"));
    try testing.expectEqual(@as(?usize, 0), reference(f32, &.{ -0.0, 1.0 }, &.{0.0}));
    try testing.expectEqual(@as(?usize, null), reference(f32, &.{math.nan(f32)}, &.{0}));
}
