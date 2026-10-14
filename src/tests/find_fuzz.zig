//! Bounded Smith fuzzers plus generic/comptime and exact-allocation search checks.
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const math = std.math;
const fastmem = @import("fastmem");
const cases = @import("find_cases.zig");
const max_hlen = 512;
const max_nlen = 320;
const padding = 128;
const Input = enum { raw, absent, implant, structured };
var runtime_fn: *const fn ([]const u8, []const u8) ?usize = &runtime;

noinline fn runtime(haystack: []const u8, needle: []const u8) ?usize {
    return fastmem.find(u8, haystack, needle);
}

fn check(haystack: []const u8, needle: []const u8) !void {
    const actual = @as(*volatile @TypeOf(runtime_fn), &runtime_fn).*(haystack, needle);
    try testing.expectEqual(cases.reference(u8, haystack, needle), actual);
}

noinline fn generic(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    return fastmem.find(T, haystack, needle);
}

test "find comptime bytes and generic elements" {
    try testing.expectEqual(@as(?usize, 1), comptime fastmem.find(u8, "banana", "ana"));
    try testing.expectEqual(@as(?usize, 0), comptime fastmem.find(u8, "", ""));
    try testing.expectEqual(@as(?usize, null), comptime fastmem.find(u8, "", "x"));
    try testing.expectEqual(
        @as(?usize, 2),
        comptime fastmem.find(u16, &.{ 0, 1, 400, 500 }, &.{ 400, 500 }),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        comptime fastmem.find(f64, &.{ 1, -0.0, 2 }, &.{ 0.0, 2 }),
    );
}

test "find generic equality signed zero infinity and NaN alias semantics" {
    var floats = [_]f64{ 9, -0.0, math.inf(f64), math.nan(f64), 7 };
    var distinct = floats;
    try testing.expectEqual(@as(?usize, 1), generic(f64, &floats, &.{ 0.0, math.inf(f64) }));
    try testing.expectEqual(@as(?usize, null), generic(f64, &floats, &.{math.nan(f64)}));
    // std.mem.eql's same-pointer shortcut is intentionally not element-wise NaN equality.
    // Only this compatibility seam uses stdlib as the authoritative oracle.
    try testing.expectEqual(mem.find(f64, &floats, &floats), generic(f64, &floats, &floats));
    try testing.expectEqual(
        mem.find(f64, &floats, floats[3..]),
        generic(f64, &floats, floats[3..]),
    );
    try testing.expectEqual(
        cases.reference(f64, &floats, &distinct),
        generic(f64, &floats, &distinct),
    );
    inline for (.{ u16, u32, u64, i16, i32, i64, bool }) |T| {
        const a: T = if (T == bool) false else 0;
        const b: T = if (T == bool) true else 1;
        var values = [_]T{ a, b, a, b, b, a };
        const needle = [_]T{ b, b };
        try testing.expectEqual(cases.reference(T, &values, &needle), generic(T, &values, &needle));
    }
    try testing.expectEqual(@as(?usize, 0), comptime fastmem.find(u0, &.{ 0, 0 }, &.{ 0, 0 }));
}

test "find multibyte rejects unaligned false hit before aligned match" {
    inline for (.{ u16, u32, u64 }) |T| {
        var haystack: [80]T = @splat(0);
        var needle: [5]T = undefined;
        const needle_bytes = mem.sliceAsBytes(&needle);
        for (needle_bytes, 0..) |*byte, i| byte.* = @intCast(i + 1);
        const haystack_bytes = mem.sliceAsBytes(&haystack);
        @memcpy(haystack_bytes[1..][0..needle_bytes.len], needle_bytes);
        @memcpy(haystack_bytes[40 * @sizeOf(T) ..][0..needle_bytes.len], needle_bytes);
        try testing.expectEqual(@as(?usize, 40), cases.reference(T, &haystack, &needle));
        try testing.expectEqual(@as(?usize, 40), generic(T, &haystack, &needle));
    }
}

test "find every byte and exact small allocations with contrasting redzones" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..256) |i| try check(&all, all[i..][0..1]);
    for (0..258) |len| {
        const haystack = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(haystack);
        const needle = try testing.allocator.alloc(u8, len + 1);
        defer testing.allocator.free(needle);
        cases.fill(haystack, len);
        cases.fill(needle, len + 1);
        try check(haystack, needle);
        try check(haystack, haystack);
        var redzones: [512]u8 = @splat(0xff);
        // A tempting complete match exists immediately outside the logical slice.
        for (redzones[64..][0..len]) |*byte| byte.* = 0;
        try check(redzones[64..][0..len], &.{ 0xff, 0xff });
        try check(redzones[64..][0..len], &.{ 0, 0xff });
        try check(redzones[64..][0..len], &.{ 0xff, 0 });
        try testing.expectEqual(@as(u8, 0xff), redzones[63]);
        try testing.expectEqual(@as(u8, 0xff), redzones[64 + len]);
    }
}

test "fuzz find independent slices arbitrary bytes offsets and canaries" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const hlen = smith.valueRangeAtMost(u32, 0, max_hlen);
            const nlen = smith.valueRangeAtMost(u32, 0, max_nlen);
            const hoff: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const noff: u32 = smith.valueRangeAtMost(u8, 0, 63);
            const input = smith.value(Input);
            var hstorage: [max_hlen + padding]u8 = @splat(0xa5);
            var nstorage: [max_nlen + padding]u8 = @splat(0x5a);
            const haystack = hstorage[hoff..][0..hlen];
            const needle = nstorage[noff..][0..nlen];
            smith.bytes(haystack);
            smith.bytes(needle);
            switch (input) {
                .raw => {},
                .absent => {
                    for (haystack) |*byte| byte.* &= 0x7f;
                    for (needle) |*byte| byte.* |= 0x80;
                },
                .structured => cases.prepareStructured(
                    haystack,
                    needle,
                    smith.value(cases.Structured),
                ),
                .implant => if (nlen <= hlen) {
                    const position = smith.valueRangeAtMost(u32, 0, hlen - nlen);
                    @memcpy(haystack[position..][0..nlen], needle);
                },
            }
            const hbefore = hstorage;
            const nbefore = nstorage;
            try check(haystack, needle);
            try testing.expectEqualSlices(u8, &hbefore, &hstorage);
            try testing.expectEqualSlices(u8, &nbefore, &nstorage);
        }
    }.run, .{ .corpus = &.{
        "", "banana", &.{ 255, 128, 0, 0, 63, 17 }, &.{ 31, 32, 33, 254, 255, 0 },
    } });
}

test "fuzz find shared storage independent overlapping slices" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            const hlen = smith.valueRangeAtMost(u32, 0, max_hlen);
            const nlen = smith.valueRangeAtMost(u32, 0, max_hlen);
            const hoff = smith.valueRangeAtMost(u32, 0, max_hlen);
            const noff = smith.valueRangeAtMost(u32, 0, max_hlen);
            var storage: [2 * max_hlen + padding]u8 = @splat(0xa5);
            smith.bytes(storage[0 .. 2 * max_hlen]);
            const before = storage;
            try check(storage[hoff..][0..hlen], storage[noff..][0..nlen]);
            try testing.expectEqualSlices(u8, &before, &storage);
        }
    }.run, .{ .corpus = &.{ "", "ababababab", &.{ 255, 255, 0, 0, 1, 0, 63, 0 } } });
}

test "find seeded long structured late matches retain first semantics" {
    var haystack: [16384]u8 = undefined;
    var needle: [4096]u8 = undefined;
    inline for (cases.needle_lengths) |nlen| {
        const fixed_needle = comptime cases.fixedNeedle(nlen);
        for (0..8) |kind| {
            cases.prepareStructured(&haystack, needle[0..nlen], @enumFromInt(kind));
            try check(&haystack, needle[0..nlen]);
            @memcpy(haystack[haystack.len - nlen ..], needle[0..nlen]);
            try check(&haystack, needle[0..nlen]);
            cases.fill(&haystack, nlen + kind);
            @memcpy(haystack[haystack.len - nlen ..], &fixed_needle);
            try testing.expectEqual(
                cases.reference(u8, &haystack, &fixed_needle),
                fastmem.find(u8, &haystack, &fixed_needle),
            );
        }
    }
}

const Element = enum { u16, u32, u64, f32, f64 };

test "fuzz find generic multibyte and floating elements" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            return switch (smith.value(Element)) {
                .u16 => fuzzGeneric(u16, smith),
                .u32 => fuzzGeneric(u32, smith),
                .u64 => fuzzGeneric(u64, smith),
                .f32 => fuzzGeneric(f32, smith),
                .f64 => fuzzGeneric(f64, smith),
            };
        }
    }.run, .{ .corpus = &.{ "", "multibyte", &.{ 255, 0, 63, 16, 0, 0, 128, 127 } } });
}

fn fuzzGeneric(comptime T: type, smith: *testing.Smith) !void {
    const hlen: u32 = smith.valueRangeAtMost(u8, 0, 64);
    const nlen: u32 = smith.valueRangeAtMost(u8, 0, 16);
    const hoff: u32 = smith.valueRangeAtMost(u8, 0, 7);
    const noff: u32 = smith.valueRangeAtMost(u8, 0, 7);
    var hstorage: [80]T = undefined;
    var nstorage: [32]T = undefined;
    smith.bytes(mem.sliceAsBytes(&hstorage));
    smith.bytes(mem.sliceAsBytes(&nstorage));
    const haystack = hstorage[hoff..][0..hlen];
    const needle = nstorage[noff..][0..nlen];
    if (smith.value(u1) == 1 and nlen <= hlen) {
        const position = smith.valueRangeAtMost(u32, 0, hlen - nlen);
        @memcpy(haystack[position..][0..nlen], needle);
    }
    const hbefore = hstorage;
    const nbefore = nstorage;
    try testing.expectEqual(cases.reference(T, haystack, needle), generic(T, haystack, needle));
    // Bit comparisons distinguish writes to NaNs and signed zero, unlike float equality.
    try testing.expectEqualSlices(u8, mem.sliceAsBytes(&hbefore), mem.sliceAsBytes(&hstorage));
    try testing.expectEqualSlices(u8, mem.sliceAsBytes(&nbefore), mem.sliceAsBytes(&nstorage));
}

test "find exhaustive ternary strings through public runtime path" {
    var haystack: [4]u8 = undefined;
    var needle: [3]u8 = undefined;
    var count: u32 = 0;
    var hpowers: u32 = 1;
    for (0..5) |hlen| {
        var npowers: u32 = 1;
        for (0..4) |nlen| {
            for (0..hpowers) |hbits| {
                for (0..npowers) |nbits| {
                    decodeTernary(haystack[0..hlen], @intCast(hbits));
                    decodeTernary(needle[0..nlen], @intCast(nbits));
                    try check(haystack[0..hlen], needle[0..nlen]);
                    count += 1;
                }
            }
            npowers *= 3;
        }
        hpowers *= 3;
    }
    try testing.expectEqual(@as(u32, 121 * 40), count);
}

fn decodeTernary(bytes: []u8, value: u32) void {
    var remaining = value;
    for (bytes) |*byte| {
        byte.* = @intCast(remaining % 3);
        remaining /= 3;
    }
}
