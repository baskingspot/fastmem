//! Linux search guards. Run with `ulimit -c 0`; stdout is one JSON object.
//! Offsets use a balanced permutation, not a 64-by-64 Cartesian product.
const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const Guarded = @import("Guarded.zig");
const cases = @import("find_cases.zig");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const heap = std.heap;
const json = std.json;
const fmt = std.fmt;
const Io = std.Io;
const process = std.process;
const meta = std.meta;

const mib = 1024 * 1024;
const Path = enum { runtime, fixed };
const Category = enum {
    dense,
    boundary,
    adversarial,
    alphabet,
    shared,
    random,
    fixed,
    seams,
    structured,
};
const Mode = enum { quick, full };
const Case = struct {
    category: Category = .dense,
    path: Path = .runtime,
    hlen: u32 = 0,
    nlen: u32 = 0,
    hoff: u32 = 0,
    noff: u32 = 0,
    hside: Guarded.Side = .start,
    nside: Guarded.Side = .start,
    pattern: cases.Pattern = .absent,
    serial: u64 = 0,
};
const Counts = struct { expected: [2]u64 = @splat(0), actual: [2]u64 = @splat(0) };
var counts: [9]Counts = @splat(.{});
var current: Case = .{};
var expected_result: ?usize = null;
var actual_result: ?usize = null;
var mode: Mode = .quick;
var seed: u64 = 0x66696e642d673031;
var fault_address: ?u64 = null;
var started_ns: i96 = 0;
var regions: [2]struct { first: u64 = 0, last: u64 = 0 } = @splat(.{});
var fault_region: ?[]const u8 = null;
const Dispatch = struct { level: []const u8, kernel: []const u8 };
var dispatch_info: ?Dispatch = null;
const large_lengths = lengths: {
    var result: [30]u32 = undefined;
    var power: u32 = 1024;
    for (0..10) |i| {
        result[i * 3] = power - 1;
        result[i * 3 + 1] = power;
        result[i * 3 + 2] = power + 1;
        power *= 2;
    }
    break :lengths result ++ [_]u32{ mib - 1, mib };
};
const adversarial_lengths = [_]u32{ 65, 129, 513, 1025, 4097, 8192, 16384 };
const FixedFn = *const fn ([]const u8) ?usize;
var runtime_fn: *const fn ([]const u8, []const u8) ?usize = &runtime;

noinline fn runtime(haystack: []const u8, needle: []const u8) ?usize {
    return fastmem.find(u8, haystack, needle);
}

fn fixed(comptime len: u32) FixedFn {
    return &struct {
        noinline fn call(haystack: []const u8) ?usize {
            const needle = comptime cases.fixedNeedle(len);
            return fastmem.find(u8, haystack, &needle);
        }
    }.call;
}

const fixed_functions = table: {
    @setEvalBranchQuota(100000);
    var result: [cases.needle_lengths.len]FixedFn = undefined;
    for (&result, cases.needle_lengths) |*function, len| function.* = fixed(len);
    break :table result;
};

fn clockNanos() i96 {
    var now: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &now) != 0) return started_ns;
    return @as(i96, now.sec) * 1_000_000_000 + now.nsec;
}

fn summary(status: []const u8, detail: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    json.Stringify.value(.{
        .schema = 1,
        .matrix = "find-g1-balanced-v1",
        .mode = @tagName(mode),
        .cpu = builtin.cpu.model.name,
        .optimize = @tagName(builtin.mode),
        .link_libc = builtin.link_libc,
        .dispatch = dispatch_info,
        .seed = seed,
        .limits = .{ .haystack = mib, .needle = 4096, .offset = 63 },
        .paths = [_][]const u8{ "runtime", "fixed" },
        .categories = [_][]const u8{
            "dense", "boundary",   "adversarial", "alphabet", "shared", "random", "fixed",
            "seams", "structured",
        },
        .counts = counts,
        .status = status,
        .detail = detail,
        .elapsed_ns = clockNanos() - started_ns,
        .case = @as(*volatile Case, &current).*,
        .expected_result = expected_result,
        .actual_result = actual_result,
        .fault_address = fault_address,
        .fault_region = fault_region,
    }, .{}, &writer) catch return;
    writer.writeByte('\n') catch return;
    const line = writer.buffered();
    _ = linux.write(1, line.ptr, line.len);
}

fn fault(_: posix.SIG, info: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const address = @intFromPtr(info.fields.sigfault.addr);
    fault_address = address;
    fault_region = "unknown";
    for (&regions, 0..) |*entry, i| {
        const region = @as(*volatile @TypeOf(entry.*), entry).*;
        const name = if (i == 0) "haystack" else "needle";
        if (address >= region.first - heap.pageSize() and address < region.last + heap.pageSize())
            fault_region = name;
    }
    // Like the memory guards, serialize into a fixed stack buffer and use a raw syscall.
    summary("fail", "guard or readonly fault");
    linux.exit_group(1);
}

fn dispatchSummary() ?Dispatch {
    const level = fastmem.dispatch.level() orelse return null;
    return .{ .level = @tagName(level), .kernel = fastmem.dispatch.kernelName().? };
}

pub fn main(init: process.Init) void {
    const action: posix.Sigaction = .{
        .handler = .{ .sigaction = fault },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO,
    };
    posix.sigaction(.SEGV, &action, null);
    posix.sigaction(.BUS, &action, null);
    started_ns = clockNanos();
    // Resolve metadata outside the signal handler so a fault never initializes dispatch.
    dispatch_info = dispatchSummary();
    runArgs(init) catch |err| {
        summary("fail", @errorName(err));
        process.exit(1);
    };
    summary("pass", "");
}

fn runArgs(init: process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: u32 = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (mem.eql(u8, args[i], "--mode")) {
            mode = meta.stringToEnum(Mode, args[i + 1]) orelse return error.InvalidMode;
        } else if (mem.eql(u8, args[i], "--seed")) {
            seed = try fmt.parseInt(u64, args[i + 1], 0);
        } else return error.InvalidArguments;
    }
    expectedCounts();
    {
        const haystack = try Guarded.init(1089);
        defer haystack.deinit();
        const needle = try Guarded.init(1089);
        defer needle.deinit();
        setRegions(haystack, needle);
        try dense(haystack, needle);
        try alphabet(haystack, needle);
        try shared(haystack);
    }
    {
        const haystack = try Guarded.init(mib + 64);
        defer haystack.deinit();
        const needle = try Guarded.init(4096 + 64);
        defer needle.deinit();
        setRegions(haystack, needle);
        try boundaries(haystack, needle);
    }
    {
        const haystack = try Guarded.init(16384 + 64);
        defer haystack.deinit();
        const needle = try Guarded.init(4096 + 64);
        defer needle.deinit();
        setRegions(haystack, needle);
        try random(haystack, needle);
        try constants(haystack, needle);
        try seams(haystack, needle);
        try structured(haystack, needle);
    }
    for (counts) |count| {
        if (!mem.eql(u64, &count.expected, &count.actual)) return error.CountMismatch;
    }
}

fn setRegions(haystack: Guarded, needle: Guarded) void {
    for ([_]Guarded{ haystack, needle }, &regions) |window, *region| {
        @as(*volatile @TypeOf(region.*), region).* = .{
            .first = @intFromPtr(window.bytes.ptr),
            .last = @intFromPtr(window.bytes.ptr) + window.bytes.len,
        };
    }
}

fn expectedCounts() void {
    const n: u64 = cases.needle_lengths.len;
    counts[@intFromEnum(Category.dense)].expected[0] = 1025 * 7 * 64 * 4;
    counts[@intFromEnum(Category.boundary)].expected[0] = large_lengths.len * n * 4 * 4 * 5;
    counts[@intFromEnum(Category.adversarial)].expected[0] = adversarial_lengths.len * n * 4 * 3;
    const htotal: u64 = if (mode == .quick) 127 else 511;
    const ntotal: u64 = if (mode == .quick) 31 else 63;
    counts[@intFromEnum(Category.alphabet)].expected[0] = htotal * ntotal * 4;
    counts[@intFromEnum(Category.shared)].expected[0] = 1025 * 7 * 4;
    counts[@intFromEnum(Category.random)].expected[0] = if (mode == .quick) 2000 else 20000;
    counts[@intFromEnum(Category.fixed)].expected = .{ n * 6 * 64 * 2, n * 6 * 64 * 2 };
    counts[@intFromEnum(Category.seams)].expected[0] = n * 3 * 4 * 9 * 4 * 2;
    counts[@intFromEnum(Category.structured)].expected[0] = n * 8 * 4 * 4;
}

fn protect(window: Guarded, access: enum { readonly, writable }) !void {
    const rc = linux.mprotect(window.bytes.ptr, window.bytes.len, .{
        .READ = true,
        .WRITE = access == .writable,
    });
    if (linux.errno(rc) != .SUCCESS) return error.ProtectFailed;
}

fn slice(window: Guarded, side: Guarded.Side, len: u32, inset: u32) []u8 {
    // Empty slices deliberately point into PROT_NONE, on both sides of the mapping.
    if (len == 0) {
        const pointer: [*]u8 = window.bytes.ptr + if (side == .start)
            @as(u32, @intCast(window.bytes.len))
        else
            @as(u32, 0);
        return (if (side == .start) pointer else pointer - 1)[0..0];
    }
    return window.bytes[window.offset(side, len, inset)..][0..len];
}

fn check(haystack: []const u8, needle: []const u8, c: Case) !void {
    @as(*volatile Case, &current).* = c;
    expected_result = cases.reference(u8, haystack, needle);
    actual_result = @as(*volatile @TypeOf(runtime_fn), &runtime_fn).*(haystack, needle);
    if (actual_result != expected_result) return error.ResultMismatch;
    counts[@intFromEnum(c.category)].actual[0] += 1;
}

fn prepared(hwindow: Guarded, nwindow: Guarded, c: Case) !void {
    @as(*volatile Case, &current).* = c;
    expected_result = null;
    actual_result = null;
    try protect(hwindow, .writable);
    try protect(nwindow, .writable);
    const haystack = slice(hwindow, c.hside, c.hlen, c.hoff);
    const needle = slice(nwindow, c.nside, c.nlen, c.noff);
    cases.prepare(haystack, needle, c.pattern, seed +% c.serial);
    try protect(hwindow, .readonly);
    try protect(nwindow, .readonly);
    try check(haystack, needle, c);
}

fn dense(hwindow: Guarded, nwindow: Guarded) !void {
    for (0..1025) |h| {
        const hlen: u32 = @intCast(h);
        const lengths = [_]u32{ 0, 1, 2, 3, hlen / 2, hlen, hlen + 1 };
        for (lengths, 0..) |nlen, slot| {
            for (0..64) |offset| {
                for (0..4) |sides| {
                    try prepared(hwindow, nwindow, .{
                        .hlen = hlen,
                        .nlen = nlen,
                        .hoff = @intCast(offset),
                        .noff = @intCast((offset * 17 + h * 7 + slot * 11) % 64),
                        .hside = if (sides & 1 == 0) .start else .end,
                        .nside = if (sides & 2 == 0) .start else .end,
                        .pattern = @enumFromInt((h + slot + offset + sides) % 7),
                        .serial = (h * 7 + slot) * 256 + offset * 4 + sides,
                    });
                }
            }
        }
    }
}

fn boundaries(hwindow: Guarded, nwindow: Guarded) !void {
    for (large_lengths) |hlen| {
        for (cases.needle_lengths) |nlen| {
            for ([_]u32{ 0, 1, 31, 63 }) |offset| {
                for (0..4) |sides| {
                    for (0..5) |pattern| {
                        try prepared(hwindow, nwindow, .{
                            .category = .boundary,
                            .hlen = hlen,
                            .nlen = nlen,
                            .hoff = offset,
                            .noff = (offset * 17) % 64,
                            .hside = if (sides & 1 == 0) .start else .end,
                            .nside = if (sides & 2 == 0) .start else .end,
                            .pattern = @enumFromInt(pattern),
                            .serial = hlen + nlen + offset + pattern,
                        });
                    }
                }
            }
        }
    }
    for (adversarial_lengths) |hlen| {
        for (cases.needle_lengths) |nlen| {
            for (0..4) |sides| {
                for (0..3) |pattern| {
                    try prepared(hwindow, nwindow, .{
                        .category = .adversarial,
                        .hlen = hlen,
                        .nlen = nlen,
                        .hside = if (sides & 1 == 0) .start else .end,
                        .nside = if (sides & 2 == 0) .start else .end,
                        .pattern = @enumFromInt(pattern + 5),
                    });
                }
            }
        }
    }
}

fn alphabet(hwindow: Guarded, nwindow: Guarded) !void {
    const hmax: u32 = if (mode == .quick) 6 else 8;
    const nmax: u32 = if (mode == .quick) 4 else 5;
    for (0..hmax + 1) |h| {
        for (0..nmax + 1) |n| {
            for (0..@as(u32, 1) << @intCast(h)) |hbits| {
                for (0..@as(u32, 1) << @intCast(n)) |nbits| {
                    try alphabetOne(
                        hwindow,
                        nwindow,
                        @intCast(h),
                        @intCast(n),
                        @intCast(hbits),
                        @intCast(nbits),
                    );
                }
            }
        }
    }
}

fn alphabetOne(
    hwindow: Guarded,
    nwindow: Guarded,
    hlen: u32,
    nlen: u32,
    hbits: u32,
    nbits: u32,
) !void {
    for (0..4) |sides| {
        try protect(hwindow, .writable);
        try protect(nwindow, .writable);
        const hside: Guarded.Side = if (sides & 1 == 0) .start else .end;
        const nside: Guarded.Side = if (sides & 2 == 0) .start else .end;
        const haystack = slice(hwindow, hside, hlen, 0);
        const needle = slice(nwindow, nside, nlen, 0);
        cases.decodeBinary(haystack, hbits);
        cases.decodeBinary(needle, nbits);
        try protect(hwindow, .readonly);
        try protect(nwindow, .readonly);
        try check(haystack, needle, .{
            .category = .alphabet,
            .hlen = hlen,
            .nlen = nlen,
            .hside = hside,
            .nside = nside,
            .serial = (@as(u64, hbits) << 32) | nbits,
        });
    }
}

fn shared(window: Guarded) !void {
    try protect(window, .writable);
    cases.fill(window.bytes, seed);
    try protect(window, .readonly);
    for (0..1025) |h| {
        const hlen: u32 = @intCast(h);
        for (0..7) |kind| {
            for ([_]Guarded.Side{ .start, .end }) |side| {
                const haystack = slice(window, side, hlen, 0);
                for (0..2) |direction| {
                    const nlen = switch (kind) {
                        0 => 0,
                        1 => hlen,
                        else => hlen / @as(u32, @intCast(kind)),
                    };
                    const needle = if (nlen == 0)
                        slice(window, side, 0, 0)
                    else if (direction == 0)
                        haystack[0..nlen]
                    else
                        haystack[hlen - nlen ..];
                    const hinput = if (direction == 0) haystack else needle;
                    const ninput = if (direction == 0) needle else haystack;
                    try check(hinput, ninput, .{
                        .category = .shared,
                        .hlen = @intCast(hinput.len),
                        .nlen = @intCast(ninput.len),
                        .hside = side,
                        .nside = side,
                        .serial = kind * 2 + direction,
                    });
                }
            }
        }
    }
}

fn random(hwindow: Guarded, nwindow: Guarded) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    const limit: u32 = if (mode == .quick) 2000 else 20000;
    for (0..limit) |i| {
        try prepared(hwindow, nwindow, .{
            .category = .random,
            .hlen = rng.intRangeAtMost(u32, 0, 16384),
            .nlen = rng.intRangeAtMost(u32, 0, 4096),
            .hoff = rng.intRangeAtMost(u32, 0, 63),
            .noff = rng.intRangeAtMost(u32, 0, 63),
            .hside = if (rng.boolean()) .start else .end,
            .nside = if (rng.boolean()) .start else .end,
            .pattern = @enumFromInt(rng.intRangeAtMost(u8, 0, 4)),
            .serial = i,
        });
    }
}

fn constants(hwindow: Guarded, nwindow: Guarded) !void {
    for (cases.needle_lengths, fixed_functions) |nlen, function| {
        const lengths = [_]u32{ 0, nlen -| 1, nlen, nlen + 1, nlen + 65, 8192 };
        for (lengths) |hlen| {
            for (0..64) |offset| {
                for ([_]Guarded.Side{ .start, .end }) |side| {
                    try constantOne(hwindow, nwindow, function, .{
                        .category = .fixed,
                        .hlen = hlen,
                        .nlen = nlen,
                        .hoff = @intCast(offset),
                        .noff = @intCast((offset * 17) % 64),
                        .hside = side,
                        .nside = side,
                        .serial = offset,
                    });
                }
            }
        }
    }
}

fn constantOne(hwindow: Guarded, nwindow: Guarded, function: FixedFn, c: Case) !void {
    try protect(hwindow, .writable);
    try protect(nwindow, .writable);
    const haystack = slice(hwindow, c.hside, c.hlen, c.hoff);
    const needle = slice(nwindow, c.nside, c.nlen, c.noff);
    cases.fill(haystack, seed +% c.serial);
    for (needle, 0..) |*byte, i| byte.* = @truncate(i *% 131);
    if (needle.len <= haystack.len) {
        const position = if (c.serial % 2 == 0) 0 else haystack.len - needle.len;
        @memcpy(haystack[position..][0..needle.len], needle);
    }
    try protect(hwindow, .readonly);
    try protect(nwindow, .readonly);
    try check(haystack, needle, c);
    var fixed_case = c;
    fixed_case.path = .fixed;
    @as(*volatile Case, &current).* = fixed_case;
    actual_result = function(haystack);
    if (actual_result != expected_result) return error.FixedResultMismatch;
    counts[@intFromEnum(Category.fixed)].actual[1] += 1;
}

fn seams(hwindow: Guarded, nwindow: Guarded) !void {
    for (cases.needle_lengths) |nlen| {
        for ([_]u32{ 16, 32, 64 }) |width| {
            const last = nlen -| 1;
            for ([_]u32{ 0, last / 2, @min(last, 254), @min(last, 255) }) |rare| {
                const offsets = cases.seamOffsets(nlen, rare);
                const minload = @max(nlen, @as(u32, @max(offsets.first, offsets.second)) + width);
                const lengths = [_]u32{
                    minload - 1,          minload,              minload + 1,
                    nlen + width - 2,     nlen + width - 1,     nlen + width,
                    nlen + 2 * width - 2, nlen + 2 * width - 1, nlen + 2 * width,
                };
                for (lengths) |hlen| {
                    for (0..4) |sides| {
                        for (0..2) |implant| {
                            try seamOne(hwindow, nwindow, rare, @intCast(implant), .{
                                .category = .seams,
                                .hlen = hlen,
                                .nlen = nlen,
                                .hside = if (sides & 1 == 0) .start else .end,
                                .nside = if (sides & 2 == 0) .start else .end,
                                .serial = rare + width * 512 + implant,
                            });
                        }
                    }
                }
            }
        }
    }
}

fn seamOne(hwindow: Guarded, nwindow: Guarded, rare: u32, implant: u32, c: Case) !void {
    try protect(hwindow, .writable);
    try protect(nwindow, .writable);
    const haystack = slice(hwindow, c.hside, c.hlen, 0);
    const needle = slice(nwindow, c.nside, c.nlen, 0);
    // Low ranks select the intended offsets within the automatic prefix.
    // Early near-candidates and the final hit exercise ascending lane order.
    @memset(haystack, ' ');
    cases.prepareSeam(needle, rare);
    if (needle.len <= haystack.len and implant == 1) {
        @memcpy(haystack[0..needle.len], needle);
        if (needle.len > 2) haystack[needle.len - 1] ^= 1;
        @memcpy(haystack[haystack.len - needle.len ..], needle);
    }
    try protect(hwindow, .readonly);
    try protect(nwindow, .readonly);
    try check(haystack, needle, c);
}

fn structured(hwindow: Guarded, nwindow: Guarded) !void {
    for (cases.needle_lengths) |nlen| {
        for (0..8) |kind| {
            for (0..4) |sides| {
                for (0..4) |implant| {
                    try structuredOne(hwindow, nwindow, @enumFromInt(kind), @intCast(implant), .{
                        .category = .structured,
                        .hlen = 16384,
                        .nlen = nlen,
                        .hside = if (sides & 1 == 0) .start else .end,
                        .nside = if (sides & 2 == 0) .start else .end,
                        .serial = kind * 4 + implant,
                    });
                }
            }
        }
    }
}

fn structuredOne(
    hwindow: Guarded,
    nwindow: Guarded,
    kind: cases.Structured,
    implant: u32,
    c: Case,
) !void {
    try protect(hwindow, .writable);
    try protect(nwindow, .writable);
    const haystack = slice(hwindow, c.hside, c.hlen, 0);
    const needle = slice(nwindow, c.nside, c.nlen, 0);
    cases.prepareStructured(haystack, needle, kind);
    if (implant != 0) {
        const position = switch (implant) {
            1 => 0,
            2 => (haystack.len - needle.len) / 2,
            3 => haystack.len - needle.len,
            else => unreachable,
        };
        @memcpy(haystack[position..][0..needle.len], needle);
    }
    try protect(hwindow, .readonly);
    try protect(nwindow, .readonly);
    try check(haystack, needle, c);
}
