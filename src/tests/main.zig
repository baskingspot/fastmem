//! Exhaustive Linux guard-page checks through the public API.
const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const Guarded = @import("Guarded.zig");
const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const json = std.json;
const Io = std.Io;
const process = std.process;

const paths = @import("paths.zig");
const Op = paths.Op;
const Path = paths.Path;
const Case = struct {
    op: Op = .copy,
    path: Path = .runtime,
    source_order: enum { below, above, shared } = .below,
    len: u32 = 0,
    src: u32 = 0,
    dst: u32 = 0,
    gap: u32 = 0,
    side: Guarded.Side = .start,
    value: u8 = 0,
};
var current: Case = .{};
var count: u64 = 0;
var path_counts: [3]u64 = @splat(0);
var started_ns: i96 = 0;
var fault_address: ?u64 = null;
var fault_region: ?[]const u8 = null;
var fault_access: ?[]const u8 = null;
const Region = struct { first: u64 = 0, last: u64 = 0 };
var regions: [3]Region = @splat(.{});

fn clockNanos() i96 {
    var now: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &now) != 0) return started_ns;
    return @as(i96, now.sec) * 1_000_000_000 + now.nsec;
}

const mib = 1024 * 1024;
const default_max_size: u32 = ceiling: {
    if (builtin.cpu.arch == .x86_64) {
        const model = builtin.cpu.model;
        if (model == &std.Target.x86.cpu.znver4) break :ceiling 16 * mib;
        // Zen 5 memset NTs above 48 MiB; cover both sides.
        if (model == &std.Target.x86.cpu.znver5) break :ceiling 65 * mib;
        if (model == &std.Target.x86.cpu.sapphirerapids) break :ceiling 67 * mib;
        if (model == &std.Target.x86.cpu.graniterapids) break :ceiling 302 * mib;
    }
    break :ceiling mib;
};
var max_size: u32 = default_max_size;

comptime {
    // Calls below also pin argument types and the void return type.
    for (.{ "copy", "move", "set" }) |name| {
        if (@TypeOf(@field(fastmem.impl, name)) != []const u8)
            @compileError("fastmem.impl fields must be comptime strings");
    }
}

fn summary(status: []const u8, detail: []const u8, elapsed_ns: i96) void {
    var buffer: [2048]u8 = undefined;
    const c = @as(*volatile Case, &current).*;
    var writer: Io.Writer = .fixed(&buffer);
    json.Stringify.value(.{
        .schema = 2,
        .matrix = "g1-v2",
        .status = status,
        .cases = count,
        .path_cases = .{
            .runtime = path_counts[@intFromEnum(Path.runtime)],
            .abi = path_counts[@intFromEnum(Path.abi)],
            .constant = path_counts[@intFromEnum(Path.constant)],
        },
        .elapsed_ns = elapsed_ns,
        .cpu = builtin.cpu.model.name,
        .max_size = max_size,
        .optimize = @tagName(builtin.mode),
        .set_available = @hasDecl(fastmem, "set"),
        .link_libc = builtin.link_libc,
        .impl = fastmem.impl,
        .dispatch = dispatchSummary(),
        .detail = detail,
        .fault_address = fault_address,
        .fault_region = fault_region,
        .fault_access = fault_access,
        .case = c,
    }, .{}, &writer) catch return;
    writer.writeByte('\n') catch return;
    const line = writer.buffered();
    _ = linux.write(1, line.ptr, line.len);
}

/// The runtime-dispatch level and kernel (docs/slop/runtime-dispatch.md), or
/// null in a comptime-selected build.
fn dispatchSummary() ?struct { level: []const u8, kernel: []const u8 } {
    const level = fastmem.dispatch.level() orelse return null;
    return .{ .level = @tagName(level), .kernel = fastmem.dispatch.kernelName().? };
}

fn fault(_: posix.SIG, info: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const address = @intFromPtr(info.fields.sigfault.addr);
    fault_address = address;
    fault_region = "unknown";
    fault_access = "unknown";
    const page = std.heap.pageSize();
    for (&regions, 0..) |*entry, i| {
        const region = @as(*volatile Region, entry).*;
        if (region.first == 0) continue;
        if (address >= region.first - page and address < region.first) {
            fault_region = if (i == 1) "destination_before" else "source_before";
        } else if (address >= region.last and address < region.last + page) {
            fault_region = if (i == 1) "destination_after" else "source_after";
        } else if (address >= region.first and address < region.last) {
            fault_region = if (i == 1) "destination" else "source_readonly";
            if (i != 1) fault_access = "write";
        }
    }
    summary("fail", "guard-page fault", clockNanos() - started_ns);
    linux.exit_group(1);
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
    runArgs(init) catch |err| {
        const elapsed = clockNanos() - started_ns;
        summary("fail", @errorName(err), elapsed);
        process.exit(1);
    };
    summary("pass", "", clockNanos() - started_ns);
}

// A byte-loop oracle stays independent of the kernel and compiler-rt exports.
fn pattern(bytes: []u8) void {
    @disableIntrinsics();
    for (bytes, 0..) |*byte, i| {
        var x: u64 = @as(u64, i) +% 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        byte.* = @truncate(x ^ (x >> 31));
    }
}

fn reference(dest: []u8, source: []const u8) void {
    @disableIntrinsics();
    for (dest, source) |*d, s| d.* = s;
}

fn fill(dest: []u8, value: u8) void {
    @disableIntrinsics();
    for (dest) |*d| d.* = value;
}

fn check(comptime op: Op, src: Guarded, dst: Guarded, expected: []u8, c: Case) !void {
    @as(*volatile Case, &current).* = c;
    // Synthetic test bytes contain no secrets.
    @memset(dst.bytes, 0xa5);
    @memset(expected, 0xa5);
    const source = src.bytes[c.src..][0..c.len];
    const dest = dst.bytes[c.dst..][0..c.len];
    if (op == .set)
        fill(expected[c.dst..][0..c.len], c.value)
    else
        reference(expected[c.dst..][0..c.len], source);
    paths.call(op, c.path, dest, source, c.value);
    if (!mem.eql(u8, expected, dst.bytes)) return error.DestinationOrCanaryMismatch;
    count += 1;
    path_counts[@intFromEnum(c.path)] += 1;
}

fn disjoint(
    src: Guarded,
    above: Guarded,
    dst: Guarded,
    expected: []u8,
    len: u32,
    offsets: []const u32,
    path: Path,
) !void {
    inline for (.{ Guarded.Side.start, Guarded.Side.end }) |side| {
        for (offsets) |s| {
            for (offsets) |d| {
                var c: Case = .{
                    .len = len,
                    .path = path,
                    .src = src.offset(side, len, @intCast(s)),
                    .dst = dst.offset(side, len, @intCast(d)),
                    .side = side,
                };
                try check(.copy, src, dst, expected, c);
                c.op = .move;
                try check(.move, src, dst, expected, c);
                c.source_order = .above;
                try check(.move, above, dst, expected, c);
            }
        }
        if (comptime @hasDecl(fastmem, "set")) {
            for (offsets) |d| {
                for ([_]u8{ 0, 0x5a, 0xff }) |value| {
                    try check(.set, src, dst, expected, .{
                        .op = .set,
                        .len = len,
                        .path = path,
                        .src = 0,
                        .dst = dst.offset(side, len, @intCast(d)),
                        .side = side,
                        .value = value,
                    });
                }
            }
        }
    }
}

fn overlapOne(
    comptime side: Guarded.Side,
    comptime backward: bool,
    buf: Guarded,
    expected: []u8,
    original: []const u8,
    len: u32,
    gap: u32,
    inset: u32,
    path: Path,
) !void {
    const base = buf.offset(side, len + gap, inset);
    const source = base + if (backward) @as(u32, 0) else gap;
    const dest = base + if (backward) gap else @as(u32, 0);
    const c: Case = .{
        .op = .move,
        .path = path,
        .source_order = .shared,
        .len = len,
        .src = source,
        .dst = dest,
        .gap = gap,
        .side = side,
    };
    @as(*volatile Case, &current).* = c;
    reference(buf.bytes, original);
    reference(expected, original);
    reference(expected[dest..][0..len], original[source..][0..len]);
    paths.call(.move, path, buf.bytes[dest..][0..len], buf.bytes[source..][0..len], 0);
    if (!mem.eql(u8, expected, buf.bytes)) return error.OverlapOrCanaryMismatch;
    count += 1;
    path_counts[@intFromEnum(c.path)] += 1;
}

fn overlap(
    buf: Guarded,
    expected: []u8,
    original: []const u8,
    len: u32,
    offsets: []const u32,
    path: Path,
) !void {
    var gaps: [139]u32 = undefined;
    for (gaps[0..129], 0..) |*gap, i| gap.* = @intCast(i);
    const extra = [_]u32{ 3840, 3841, 3968, 4000, 4095, 4096, 4097, 8192, len / 2, len -| 1 };
    @memcpy(gaps[129..], &extra);
    const sparse = [_]u32{ 0, 4095, len / 2, len -| 1 };
    const entry_gaps = [_]u32{ 0, 1, 128, 3841, 4000, 4096, 8192, len / 2, len -| 1 };
    const selected = if (path != .runtime and len <= mib)
        &entry_gaps
    else if (len > mib)
        &sparse
    else
        gaps[0..@as(u32, if (len > 1024) 139 else 129)];
    inline for (.{ Guarded.Side.start, Guarded.Side.end }) |side| {
        for (selected) |gap| {
            for (offsets) |inset| {
                inline for (.{ false, true }) |backward| {
                    try overlapOne(
                        side,
                        backward,
                        buf,
                        expected,
                        original,
                        len,
                        gap,
                        inset,
                        path,
                    );
                }
            }
        }
    }
}

fn sizeClass(
    allocator: mem.Allocator,
    sizes: []const u32,
    offsets: []const u32,
    overlap_offsets: []const u32,
    path: Path,
) !void {
    var maximum: u32 = 0;
    for (sizes) |len| maximum = @max(maximum, len);
    const gap_capacity = if (maximum > 1024 or path != .runtime)
        @max(8192, maximum - 1) + 64
    else
        0;
    const capacity = maximum + @max(256, gap_capacity);
    var windows: [3]Guarded = undefined;
    var initialized: u32 = 0;
    defer for (windows[0..initialized]) |window| window.deinit();
    for (&windows) |*window| {
        window.* = try Guarded.init(capacity);
        initialized += 1;
    }
    // mmap placement is not an API guarantee. Sort addresses before choosing the destination.
    mem.sort(Guarded, &windows, {}, struct {
        fn less(_: void, a: Guarded, b: Guarded) bool {
            return @intFromPtr(a.bytes.ptr) < @intFromPtr(b.bytes.ptr);
        }
    }.less);
    for (windows, &regions) |window, *region| {
        @as(*volatile Region, region).* = .{
            .first = @intFromPtr(window.bytes.ptr),
            .last = @intFromPtr(window.bytes.ptr) + window.bytes.len,
        };
    }
    defer for (&regions) |*region| {
        @as(*volatile Region, region).* = .{};
    };
    const src = windows[0];
    const dst = windows[1];
    const above = windows[2];
    const expected = try allocator.alloc(u8, dst.bytes.len);
    defer allocator.free(expected);
    const original = try allocator.alloc(u8, src.bytes.len);
    defer allocator.free(original);
    pattern(original);
    for ([_]Guarded{ src, above }) |source| {
        reference(source.bytes, original);
        // A read-only source detects writes even when the final bytes look correct.
        const rc = linux.mprotect(source.bytes.ptr, source.bytes.len, .{ .READ = true });
        if (linux.errno(rc) != .SUCCESS) return error.ProtectFailed;
    }
    for (sizes) |len| {
        try disjoint(src, above, dst, expected, len, offsets, path);
        try overlap(dst, expected, original, len, overlap_offsets, path);
    }
}

fn offsetsFor(len: u32) []const u32 {
    return if (len <= 64 * 1024) &.{ 0, 1, 15, 16, 31, 32, 33, 63 } else &.{ 0, 1 };
}

fn runArgs(init: process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const value = args[i + 1];
        if (mem.eql(u8, args[i], "--max-size")) {
            max_size = try std.fmt.parseInt(u32, value, 10);
            if (max_size < 1024 or max_size > 512 * mib) return error.InvalidMaxSize;
        } else if (mem.eql(u8, args[i], "--x86-level")) {
            // Test one dispatch level instead of the detected one.
            const level = std.meta.stringToEnum(fastmem.dispatch.Level, value) orelse
                return error.InvalidLevel;
            try fastmem.dispatch.force(level);
        } else return error.InvalidArguments;
    }
    try run(init.gpa);
}

fn run(allocator: mem.Allocator) !void {
    var small: [1025]u32 = undefined;
    for (&small, 0..) |*len, i| len.* = @intCast(i);
    var offsets: [64]u32 = undefined;
    for (&offsets, 0..) |*offset, i| offset.* = @intCast(i);
    try sizeClass(allocator, &small, &offsets, &.{ 0, 1, 17, 63 }, .runtime);
    try sizeClass(allocator, &small, &.{ 0, 1, 17, 63 }, &.{0}, .abi);
    try sizeClass(allocator, small[1..257], &.{ 0, 1, 17, 63 }, &.{0}, .constant);
    // Each large size gets its own page-rounded window, not a 1 MiB small-case mapping.
    const dense_limit = @min(max_size, mib);
    var power: u32 = 1024;
    while (power <= dense_limit) : (power *= 2) {
        for ([_]u32{ power - 1, power, power + 1 }) |len| {
            if (len > dense_limit) continue;
            try sizeClass(allocator, &.{len}, offsetsFor(len), &.{ 0, 1, 17, 63 }, .runtime);
            try sizeClass(allocator, &.{len}, &.{ 0, 1 }, &.{0}, .abi);
        }
    }
    for ([_]u32{ 4095, 4096, 4097 }) |base| {
        var multiplier: u32 = 1;
        while (base * multiplier <= dense_limit) : (multiplier *= 2) {
            const len = base * multiplier;
            try sizeClass(allocator, &.{len}, offsetsFor(len), &.{ 0, 1, 17, 63 }, .runtime);
            try sizeClass(allocator, &.{base * multiplier}, &.{ 0, 1 }, &.{0}, .abi);
        }
    }
    if (max_size > mib) {
        for ([_]u32{ max_size - 1, max_size }) |len| {
            try sizeClass(allocator, &.{len}, &.{0}, &.{0}, .runtime);
            try sizeClass(allocator, &.{len}, &.{0}, &.{0}, .abi);
        }
    }
}
