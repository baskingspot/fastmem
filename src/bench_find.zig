//! One-shot substring search; no reusable finder or preprocessing outside a call.
const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const options = @import("bench_options");
const c = @import("c");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Impl = enum {
    std_direct,
    fastmem_direct,
    std_indirect,
    fastmem_indirect,
    glibc_indirect,
    std_fixed,
    fastmem_fixed,
};
const Pattern = enum { random, text, low, uniform, periodic, prefix, suffix, near, rare };
const Position = enum { absent, start, middle, end };
const Suite = enum { quick, standard };
const max_iters = 1 << 30;
const missing = std.math.maxInt(usize);
// All indirect destinations use memmem's pointer ABI and common normalization.
const SearchFn = *const fn ([*]const u8, usize, [*]const u8, usize) callconv(.c) ?[*]const u8;
var glibc_function: SearchFn = undefined;

fn encoded(answer: ?usize) usize {
    return answer orelse missing;
}
noinline fn stdWrapper(
    h: [*]const u8,
    hl: usize,
    n: [*]const u8,
    nl: usize,
) callconv(.c) ?[*]const u8 {
    return if (std.mem.find(u8, h[0..hl], n[0..nl])) |i| h + i else null;
}
noinline fn fastmemWrapper(
    h: [*]const u8,
    hl: usize,
    n: [*]const u8,
    nl: usize,
) callconv(.c) ?[*]const u8 {
    return if (fastmem.find(u8, h[0..hl], n[0..nl])) |i| h + i else null;
}
inline fn normalize(result_ptr: ?[*]const u8, h: [*]const u8, hl: usize, nl: usize) usize {
    const result = result_ptr orelse return missing;
    const address = @intFromPtr(result);
    const base = @intFromPtr(h);
    if (address < base or address - base > hl or nl > hl - (address - base))
        return missing - 1; // The independent answer guard rejects an invalid libc pointer.
    return address - base;
}
comptime {
    // Private named inspection roots, not a public libc surface.
    @export(&stdWrapper, .{ .name = "bench_find_std" });
    @export(&fastmemWrapper, .{ .name = "bench_find_fastmem" });
}

const Evidence = struct {
    address: usize,
    dli_fname: []const u8,
    dli_fbase: usize,
    offset: usize,

    fn resolve(ptr: *const anyopaque) !Evidence {
        var info: c.Dl_info = undefined;
        if (c.dladdr(ptr, &info) == 0 or info.dli_fname == null or info.dli_fbase == null)
            return error.DladdrFailed;
        const address = @intFromPtr(ptr);
        const base = @intFromPtr(info.dli_fbase);
        if (address < base) return error.InvalidAddress;
        return .{
            .address = address,
            .dli_fname = std.mem.span(info.dli_fname),
            .dli_fbase = base,
            .offset = address - base,
        };
    }
};
const Resolution = struct {
    libc_path: []const u8,
    libc_base: usize,
    executable_base: usize,
    memmem: Evidence,
};
const Symbols = struct {
    handle: *anyopaque,
    resolution: Resolution,

    fn init() !Symbols {
        const handle = c.dlopen("libc.so.6", c.RTLD_NOW | c.RTLD_LOCAL) orelse
            return error.LibcDlopenFailed;
        errdefer _ = c.dlclose(handle);
        var map: ?*c.struct_link_map = null;
        if (c.dlinfo(handle, c.RTLD_DI_LINKMAP, @ptrCast(&map)) != 0 or map == null)
            return error.LinkMapFailed;
        const library = map.?;
        const path = std.mem.span(library.l_name);
        const ptr = c.dlsym(handle, "memmem") orelse return error.MemmemMissing;
        const evidence = try Evidence.resolve(ptr);
        const own = try Evidence.resolve(@ptrCast(&fastmemWrapper));
        const resolution: Resolution = .{
            .libc_path = path,
            .libc_base = library.l_addr,
            .executable_base = own.dli_fbase,
            .memmem = evidence,
        };
        try validateResolution(resolution);
        glibc_function = @ptrCast(@alignCast(ptr));
        return .{ .handle = handle, .resolution = resolution };
    }
    fn deinit(self: Symbols) void {
        _ = c.dlclose(self.handle);
    }
};
fn validateResolution(r: Resolution) !void {
    if (!std.mem.endsWith(u8, r.libc_path, "/libc.so.6") or r.libc_base == 0 or
        r.libc_base == r.executable_base or r.memmem.dli_fbase != r.libc_base or
        !std.mem.eql(u8, r.memmem.dli_fname, r.libc_path) or
        r.memmem.address != r.libc_base + r.memmem.offset)
        return error.MemmemOutsideIndependentLibcHandle;
}

const Config = struct {
    suite: Suite = .standard,
    samples: u32 = 10,
    sample_ms: u32 = 2,
    warmup_ms: u32 = 1,
    seed: u64 = 1,
    filter: []const u8 = "",
    list: bool = false,
    probe: bool = false,
};
fn parseArgs(args: []const [:0]const u8) !Config {
    var cfg: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--list")) {
            cfg.list = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--probe")) {
            cfg.probe = true;
            continue;
        }
        const flag, const value = if (std.mem.cutScalar(u8, arg, '=')) |pair| pair else blk: {
            index += 1;
            if (index == args.len) return error.MissingValue;
            break :blk .{ arg, args[index] };
        };
        if (std.mem.eql(u8, flag, "--suite")) {
            cfg.suite = std.meta.stringToEnum(Suite, value) orelse return error.InvalidSuite;
        } else if (std.mem.eql(u8, flag, "--filter")) {
            cfg.filter = value;
        } else if (std.mem.eql(u8, flag, "--seed")) {
            cfg.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, flag, "--samples")) {
            cfg.samples = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--sample-ms")) {
            cfg.sample_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--warmup-ms")) {
            cfg.warmup_ms = try std.fmt.parseInt(u32, value, 10);
        } else return error.UnknownFlag;
    }
    if (cfg.samples == 0 or cfg.samples > 1000 or cfg.sample_ms == 0 or
        cfg.sample_ms > 1000 or cfg.warmup_ms > 1000) return error.InvalidBounds;
    return cfg;
}
const Case = struct {
    id: []const u8,
    hlen: usize,
    nlen: usize,
    pattern: Pattern,
    position: Position,
    hay_off: usize,
    needle_off: usize,
    fixed: bool = false,
};
const runtime_impls: []const Impl = &.{
    .std_direct, .fastmem_direct, .std_indirect, .fastmem_indirect, .glibc_indirect,
};
const fixed_impls: []const Impl = &.{ .std_fixed, .fastmem_fixed };
const fixed_lengths = [_]usize{ 1, 2, 3, 15, 16, 17, 31, 32, 33 };
fn fixedNeedle(comptime len: usize) *const [len]u8 {
    const bytes = comptime blk: {
        var value: [len]u8 = undefined;
        for (&value, 0..) |*byte, i| byte.* = 'A' + i % 26;
        break :blk value;
    };
    return &bytes;
}
fn addCase(
    a: Allocator,
    cases: *std.ArrayList(Case),
    cfg: Config,
    hl: usize,
    nl: usize,
    pattern: Pattern,
    position: Position,
    fixed: bool,
) !void {
    const index = cases.items.len;
    const ho = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63 };
    const no = [_]usize{ 3, 0, 33, 1, 31, 17, 63, 16, 32 };
    // Offsets depend on the unfiltered suite, not on the selection.
    const case: Case = .{
        .id = try std.fmt.allocPrint(a, "find/{s}/{s}/{s}/{d}/{d}", .{
            if (fixed) "fixed" else "runtime", @tagName(pattern), @tagName(position), hl, nl,
        }),
        .hlen = hl,
        .nlen = nl,
        .pattern = pattern,
        .position = position,
        .hay_off = ho[index % ho.len],
        .needle_off = no[index % no.len],
        .fixed = fixed,
    };
    try cases.append(a, case);
    _ = cfg;
}
fn buildCases(a: Allocator, cfg: Config) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    const lengths: []const usize = if (cfg.suite == .quick)
        &.{ 0, 1, 2, 3, 16, 17, 32, 33, 256, 257, 1024, 4096 }
    else
        &.{
            0,   1,   2,   3,   4,   7,   8,   15,   16,   17, 31, 32, 33, 63, 64, 65,
            127, 128, 129, 255, 256, 257, 512, 1024, 4096,
        };
    const patterns = [_]Pattern{ .random, .text, .low, .uniform, .periodic, .prefix, .suffix };
    const positions = [_]Position{ .absent, .start, .middle, .end };
    for (lengths, 0..) |nl, i| {
        try addCase(a, &cases, cfg, @max(64, nl * 4), nl, patterns[i % 7], positions[i % 4], false);
        try addCase(
            a,
            &cases,
            cfg,
            @max(4096, nl * 8),
            nl,
            patterns[(i + 2) % 7],
            positions[(i + 1) % 4],
            false,
        );
    }
    if (cfg.suite == .standard) {
        // Dense almost-copies retain most candidate pairs but fail late verification.
        for ([_]usize{ 33, 257, 1024, 4096 }) |nl|
            try addCase(a, &cases, cfg, 65536, nl, .near, .absent, false);
        // Saturated common alphabet; the only rare needle byte is explicitly at 300.
        for ([_]usize{ 512, 1024, 4096 }) |nl| {
            try addCase(a, &cases, cfg, nl, nl, .rare, .start, false);
            try addCase(a, &cases, cfg, nl + 1, nl, .rare, .end, false);
            try addCase(a, &cases, cfg, 262144, nl, .rare, .absent, false);
        }
        for (0..9) |hl| for ([_]usize{ 0, 1, 2, 3, 9 }) |nl|
            try addCase(a, &cases, cfg, hl, nl, .random, .end, false);
        for ([_]usize{
            15,  16,  17,  31,   32,   33,   63,   64,   65,   127, 128, 129, 255, 256, 257,
            511, 512, 513, 1023, 1024, 1025, 4095, 4096, 4097,
        }) |hl|
            try addCase(a, &cases, cfg, hl, 3, .text, .end, false);
        for ([_]usize{ 4096, 16384, 65536 }) |hl| {
            for ([_]usize{ 17, 257, 1024, 4096 }) |nl| {
                for ([_]Pattern{ .prefix, .suffix }) |pattern|
                    try addCase(a, &cases, cfg, hl, nl, pattern, .absent, false);
            }
        }
        for ([_]usize{ 16384, 65536, 262144, 1048576 }) |hl|
            for (positions, 0..) |position, i|
                try addCase(a, &cases, cfg, hl, 31 + i, patterns[i], position, false);
        for (patterns) |pattern| for (positions) |position|
            try addCase(a, &cases, cfg, 8192, 15, pattern, position, false);
    } else {
        try addCase(a, &cases, cfg, 0, 0, .random, .absent, false);
        try addCase(a, &cases, cfg, 2, 3, .random, .end, false);
        try addCase(a, &cases, cfg, 65536, 257, .prefix, .absent, false);
        try addCase(a, &cases, cfg, 65536, 1024, .suffix, .absent, false);
    }
    for (fixed_lengths) |nl| try addCase(a, &cases, cfg, 4096, nl, .text, .end, true);
    // Controlled single-axis variations, with identical bytes across alignments.
    for ([_]Pattern{ .random, .prefix }) |pattern| {
        for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 63, 0 }, .{ 0, 63 } }) |offsets| {
            try addCase(a, &cases, cfg, 8192, 33, pattern, .end, false);
            const case = &cases.items[cases.items.len - 1];
            case.id = try std.fmt.allocPrint(a, "{s}/align/{d}/{d}", .{
                case.id, offsets[0], offsets[1],
            });
            case.hay_off = offsets[0];
            case.needle_off = offsets[1];
        }
    }
    var selected: std.ArrayList(Case) = .empty;
    for (cases.items) |case| if (std.mem.find(u8, case.id, cfg.filter) != null)
        try selected.append(a, case);
    if (selected.items.len == 0) return error.EmptySelection;
    return selected.items;
}
const Inputs = struct { hay: []u8, needle: []u8, oracle: ?usize, requested: ?usize };
fn makeInputs(a: Allocator, cfg: Config, case: Case) !Inputs {
    const hay_buffer = try a.alignedAlloc(u8, .@"64", case.hlen + case.hay_off + 64);
    const hay = hay_buffer[case.hay_off..][0..case.hlen];
    const needle_buffer = try a.alignedAlloc(u8, .@"64", case.nlen + case.needle_off + 64);
    const needle = needle_buffer[case.needle_off..][0..case.nlen];
    const identity = if (std.mem.find(u8, case.id, "/align/")) |i| case.id[0..i] else case.id;
    var prng = std.Random.DefaultPrng.init(cfg.seed ^ std.hash.Wyhash.hash(0, identity));
    const random = prng.random();
    const text = "the quick brown fox searches a reproducible synthetic document. ";
    for (hay, 0..) |*byte, i| byte.* = switch (case.pattern) {
        .random => random.int(u8),
        .rare => @intCast(i % 255),
        .text => text[i % text.len],
        .low => random.int(u8) % 4,
        .uniform, .prefix, .suffix => 'a',
        .periodic => "abababa"[i % 7],
        .near => @as(u8, @intCast(i % 13)) + 'a',
    };
    for (needle, 0..) |*byte, i| byte.* = switch (case.pattern) {
        .random => random.int(u8),
        .rare => @intCast(i % 255),
        .text => text[(i + 13) % text.len],
        .low => random.int(u8) % 4,
        .uniform, .prefix, .suffix => 'a',
        .periodic => "abababa"[i % 7],
        .near => @as(u8, @intCast(i % 13)) + 'a',
    };
    if (case.pattern == .rare) needle[300] = 255;
    if (case.pattern == .near) {
        for (hay, 0..) |*byte, i| {
            byte.* = needle[i % needle.len];
            if (i % needle.len == needle.len / 2) byte.* ^= 128;
        }
    }
    if (needle.len != 0) switch (case.pattern) {
        .prefix, .uniform, .periodic => needle[needle.len - 1] = 'z',
        .suffix => needle[0] = 'z',
        else => {},
    };
    if (case.fixed) inline for (fixed_lengths) |nl| {
        if (case.nlen == nl) @memcpy(needle, fixedNeedle(nl));
    };
    const requested: ?usize = if (case.nlen == 0)
        0
    else if (case.position == .absent or case.nlen > case.hlen)
        null
    else switch (case.position) {
        .start => 0,
        .middle => (case.hlen - case.nlen) / 2,
        .end => case.hlen - case.nlen,
        .absent => unreachable,
    };
    if (requested) |pos| @memcpy(hay[pos..][0..needle.len], needle);
    // Repair accidental full matches right to left. Changing only the start byte
    // cannot affect an already-checked later candidate or the implanted match.
    // Late-mismatch profiles retain their candidate density; no universal sentinel.
    if (needle.len != 0 and needle.len <= hay.len) {
        var i = requested orelse (hay.len - needle.len + 1);
        while (i != 0) {
            i -= 1;
            var j: usize = 0;
            while (j < needle.len and hay[i + j] == needle[j]) : (j += 1) {}
            if (j == needle.len) hay[i] ^= 128;
        }
    }
    const answer = oracle(hay, needle);
    if (answer != requested) return error.MislabeledFirstMatch;
    return .{ .hay = hay, .needle = needle, .oracle = answer, .requested = requested };
}
// Deliberately independent byte loop; not a timed search implementation.
noinline fn oracle(h: []const u8, n: []const u8) ?usize {
    @setRuntimeSafety(true);
    if (n.len == 0) return 0;
    if (n.len > h.len) return null;
    for (0..h.len - n.len + 1) |i| {
        var j: usize = 0;
        while (j < n.len and h[i + j] == n[j]) : (j += 1) {}
        if (j == n.len) return i;
    }
    return null;
}
fn checkAnswer(actual: usize, expected: ?usize) !void {
    if (actual != encoded(expected)) return error.WrongSearchAnswer;
}
const Result = struct { ns: u64, iters: u64, checksum: u64 };
inline fn loopBody(
    comptime impl: Impl,
    comptime fixed_len: ?usize,
    io: Io,
    function_ptr: *const SearchFn,
    inputs: Inputs,
    iters: u64,
) Result {
    const function = @as(*const volatile SearchFn, function_ptr).*;
    const start = Io.Timestamp.now(io, .awake);
    var checksum: u64 = 0;
    for (0..iters) |_| {
        // A clobber BEFORE the call makes every search observe fresh runtime bytes.
        asm volatile ("" ::: .{ .memory = true });
        const answer = switch (impl) {
            .std_direct => encoded(std.mem.find(u8, inputs.hay, inputs.needle)),
            .fastmem_direct => encoded(fastmem.find(u8, inputs.hay, inputs.needle)),
            .std_fixed => encoded(std.mem.find(u8, inputs.hay, fixedNeedle(fixed_len.?))),
            .fastmem_fixed => encoded(fastmem.find(u8, inputs.hay, fixedNeedle(fixed_len.?))),
            else => normalize(function(
                inputs.hay.ptr,
                inputs.hay.len,
                inputs.needle.ptr,
                inputs.needle.len,
            ), inputs.hay.ptr, inputs.hay.len, inputs.needle.len),
        };
        checksum +%= @as(u64, answer) +% 1;
        std.mem.doNotOptimizeAway(answer);
        asm volatile ("" ::: .{ .memory = true });
    }
    std.mem.doNotOptimizeAway(checksum);
    const ns: u64 = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);
    return .{ .ns = ns, .iters = iters, .checksum = checksum };
}
noinline fn runFastmemDirect(io: Io, inputs: Inputs, iters: u64) Result {
    const function: SearchFn = &fastmemWrapper;
    return loopBody(.fastmem_direct, null, io, &function, inputs, iters);
}
noinline fn runFastmemFixed(comptime len: usize, io: Io, inputs: Inputs, iters: u64) Result {
    const function: SearchFn = &fastmemWrapper;
    return loopBody(.fastmem_fixed, len, io, &function, inputs, iters);
}
noinline fn runStdDirect(io: Io, inputs: Inputs, iters: u64) Result {
    const function: SearchFn = &stdWrapper;
    return loopBody(.std_direct, null, io, &function, inputs, iters);
}
noinline fn runStdFixed(comptime len: usize, io: Io, inputs: Inputs, iters: u64) Result {
    const function: SearchFn = &stdWrapper;
    return loopBody(.std_fixed, len, io, &function, inputs, iters);
}
noinline fn runIndirect(io: Io, function: *const SearchFn, inputs: Inputs, iters: u64) Result {
    return loopBody(.std_indirect, null, io, function, inputs, iters);
}
fn runBatch(io: Io, impl: Impl, inputs: Inputs, iters: u64) !Result {
    const result = switch (impl) {
        .fastmem_direct => runFastmemDirect(io, inputs, iters),
        .std_direct => runStdDirect(io, inputs, iters),
        .std_fixed, .fastmem_fixed => blk: {
            inline for (fixed_lengths) |len| if (inputs.needle.len == len) {
                break :blk if (impl == .fastmem_fixed)
                    runFastmemFixed(len, io, inputs, iters)
                else
                    runStdFixed(len, io, inputs, iters);
            };
            return error.InvalidFixedLength;
        },
        else => blk: {
            const function: SearchFn = switch (impl) {
                .std_indirect => &stdWrapper,
                .fastmem_indirect => &fastmemWrapper,
                .glibc_indirect => glibc_function,
                else => unreachable,
            };
            break :blk runIndirect(io, &function, inputs, iters);
        },
    };
    // Guard warmup, calibration and recorded batches, not only startup calls.
    const expected = (@as(u64, encoded(inputs.oracle)) +% 1) *% iters;
    if (result.checksum != expected) return error.WrongBatchChecksum;
    return result;
}
fn scaleIterations(iters: u64, ns: u64, target: u64) u64 {
    return @intCast(@min(max_iters, @max(1, @as(u128, iters) * target / @max(ns, 1))));
}
fn calibrate(io: Io, impl: Impl, inputs: Inputs, target: u64) !u64 {
    var iters: u64 = 64;
    for (0..12) |_| {
        const result = try runBatch(io, impl, inputs, iters);
        if (result.ns >= target * 3 / 4 and result.ns <= target * 5 / 4) return iters;
        const next = scaleIterations(iters, result.ns, target);
        if (next == iters) return iters;
        iters = next;
    }
    return iters;
}
const Sample = struct {
    type: []const u8 = "sample",
    case: []const u8,
    impl: Impl,
    sample: u32,
    iters: u64,
    ns: u64,
    checksum: u64,
    result: ?usize,
};
const CaseRecord = struct {
    type: []const u8 = "case",
    case: []const u8,
    hlen: usize,
    nlen: usize,
    pattern: Pattern,
    position: Position,
    requested: ?usize,
    oracle: ?usize,
    hay_off: usize,
    needle_off: usize,
    fixed: bool,
    impls: []const Impl,
};
fn jsonLine(w: *Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
}
const Dispatch = struct { level: []const u8 };
// This is the shared selected large-search dispatch level, not a per-call kernel.
// Tiny/local searches do not use the selected large-search entry.
fn dispatchSummary() ?Dispatch {
    const level = fastmem.dispatch.level() orelse return null;
    return .{ .level = @tagName(level) };
}
fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const cfg = try parseArgs(try init.minimal.args.toSlice(a));
    const symbols = try Symbols.init();
    defer symbols.deinit();
    var buffer: [8192]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &writer.interface;
    if (cfg.probe) {
        try jsonLine(w, symbols.resolution);
        try w.flush();
        return;
    }
    const cases = try buildCases(a, cfg);
    var records: std.ArrayList(CaseRecord) = .empty;
    var samples: std.ArrayList(Sample) = .empty;
    const start = Io.Timestamp.now(init.io, .awake);
    for (cases) |case| {
        // Reclaim the buffers between cases, keeping the record strings in the process arena.
        var inputs_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer inputs_arena.deinit();
        const inputs = try makeInputs(inputs_arena.allocator(), cfg, case);
        const impls = if (case.fixed) fixed_impls else runtime_impls;
        try records.append(a, .{
            .case = case.id,
            .hlen = case.hlen,
            .nlen = case.nlen,
            .pattern = case.pattern,
            .position = case.position,
            .requested = inputs.requested,
            .oracle = inputs.oracle,
            .hay_off = case.hay_off,
            .needle_off = case.needle_off,
            .fixed = case.fixed,
            .impls = impls,
        });
        if (cfg.list) continue;
        // All references and wrappers are checked even for fixed-only timing cases.
        try checkAnswer(normalize(stdWrapper(
            inputs.hay.ptr,
            inputs.hay.len,
            inputs.needle.ptr,
            inputs.needle.len,
        ), inputs.hay.ptr, inputs.hay.len, inputs.needle.len), inputs.oracle);
        try checkAnswer(normalize(fastmemWrapper(
            inputs.hay.ptr,
            inputs.hay.len,
            inputs.needle.ptr,
            inputs.needle.len,
        ), inputs.hay.ptr, inputs.hay.len, inputs.needle.len), inputs.oracle);
        try checkAnswer(normalize(glibc_function(
            inputs.hay.ptr,
            inputs.hay.len,
            inputs.needle.ptr,
            inputs.needle.len,
        ), inputs.hay.ptr, inputs.hay.len, inputs.needle.len), inputs.oracle);
        var iterations: [5]u64 = undefined;
        const target = @as(u64, cfg.sample_ms) * std.time.ns_per_ms;
        for (impls, 0..) |impl, i| {
            _ = try runBatch(init.io, impl, inputs, 1);
            const warm = Io.Timestamp.now(init.io, .awake);
            const warmup_ns = @as(u64, cfg.warmup_ms) * std.time.ns_per_ms;
            while (warm.durationTo(.now(init.io, .awake)).nanoseconds < warmup_ns)
                _ = try runBatch(init.io, impl, inputs, 1);
            iterations[i] = try calibrate(init.io, impl, inputs, target);
        }
        for (0..cfg.samples) |s| for (0..impls.len) |p| {
            const i = (s + p) % impls.len;
            const result = try runBatch(init.io, impls[i], inputs, iterations[i]);
            if (result.ns == 0) return error.ZeroDuration;
            try samples.append(a, .{
                .case = case.id,
                .impl = impls[i],
                .sample = @intCast(s),
                .iters = result.iters,
                .ns = result.ns,
                .checksum = result.checksum,
                .result = inputs.oracle,
            });
            iterations[i] = scaleIterations(result.iters, result.ns, target);
        };
    }
    const elapsed: u64 = @intCast(start.durationTo(.now(init.io, .awake)).nanoseconds);
    const executable = try Io.Dir.cwd().readFileAlloc(
        init.io,
        "/proc/self/exe",
        a,
        .limited(128 << 20),
    );
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable, &digest, .{});
    const binary_sha256 = std.fmt.bytesToHex(digest, .lower);
    // Nothing is emitted on a failed or interrupted measurement.
    try jsonLine(w, .{
        .type = "meta",
        .dialect = "fastmem-find",
        .schema = @as(u32, 1),
        .rev = std.mem.sliceTo(&options.rev_padded, 0),
        .zig = builtin.zig_version_string,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++
            @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi),
        .cpu = builtin.cpu.model.name,
        .dispatch = dispatchSummary(),
        .optimize = @tagName(builtin.mode),
        .link_libc = true,
        .suite = cfg.suite,
        .seed = cfg.seed,
        .samples = cfg.samples,
        .sample_ms = cfg.sample_ms,
        .warmup_ms = cfg.warmup_ms,
        .filter = cfg.filter,
        .list = cfg.list,
        .binary_sha256 = &binary_sha256,
        .resolution = symbols.resolution,
        .one_shot = true,
    });
    for (records.items) |record| try jsonLine(w, record);
    for (samples.items) |sample| try jsonLine(w, sample);
    try jsonLine(w, .{
        .type = "end",
        .cases = records.items.len,
        .samples = samples.items.len,
        .elapsed_ns = elapsed,
    });
    try w.flush();
}
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("bench-find: {s}; no complete measurement produced.\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

test "calibration both grows and shrinks with nonzero bounds" {
    try std.testing.expectEqual(@as(u64, 100), scaleIterations(1000, 200, 20));
    try std.testing.expectEqual(@as(u64, max_iters / 2), scaleIterations(max_iters, 40, 20));
    try std.testing.expectEqual(@as(u64, 1), scaleIterations(64, 100000, 1));
    try std.testing.expectEqual(@as(u64, max_iters), scaleIterations(64, 0, max_iters));
}
test "independent oracle and answer guard" {
    try std.testing.expectEqual(@as(?usize, 0), oracle("", ""));
    try std.testing.expectEqual(@as(?usize, null), oracle("a", "aa"));
    try std.testing.expectEqual(@as(?usize, 1), oracle("ababa", "bab"));
    try std.testing.expectError(error.WrongSearchAnswer, checkAnswer(2, 1));
    try checkAnswer(missing, null);
}
test "CLI bounds reject zero and excess" {
    try std.testing.expectError(error.InvalidBounds, parseArgs(&.{
        "bench-find", "--samples", "0",
    }));
    try std.testing.expectError(error.InvalidBounds, parseArgs(&.{
        "bench-find", "--sample-ms=1001",
    }));
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "bench-find", "--other=1" }));
}

test "every batch guards its result checksum before calibration or sampling" {
    var hay = [_]u8{ 'a', 'b', 'c' };
    var needle = [_]u8{'b'};
    const wrong: Inputs = .{ .hay = &hay, .needle = &needle, .oracle = 2, .requested = 1 };
    try std.testing.expectError(
        error.WrongBatchChecksum,
        runBatch(std.testing.io, .std_direct, wrong, 1),
    );
    try std.testing.expectError(
        error.WrongBatchChecksum,
        runBatch(std.testing.io, .fastmem_direct, wrong, 64),
    );
}
test "resolution cannot be the executable masquerading as libc" {
    const bad: Resolution = .{
        .libc_path = "/lib/libc.so.6",
        .libc_base = 1000,
        .executable_base = 1000,
        .memmem = .{
            .address = 1100,
            .dli_fname = "/lib/libc.so.6",
            .dli_fbase = 1000,
            .offset = 100,
        },
    };
    try std.testing.expectError(error.MemmemOutsideIndependentLibcHandle, validateResolution(bad));
}

test "constructed first matches and rare-byte/dense invariants across seeds" {
    for ([_]u64{ 0, 1, 2, 42, 0x123456789abcdef0, std.math.maxInt(u64) }) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const cfg: Config = .{ .suite = .standard, .seed = seed };
        const cases = try buildCases(a, cfg);
        for (cases) |case| {
            var inputs_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer inputs_arena.deinit();
            const inputs = try makeInputs(inputs_arena.allocator(), cfg, case);
            try std.testing.expectEqual(inputs.requested, inputs.oracle);
            if (case.pattern == .rare) {
                try std.testing.expectEqual(@as(u8, 255), inputs.needle[300]);
                for (inputs.needle, 0..) |byte, i|
                    try std.testing.expectEqual(i == 300, byte == 255);
                for (0..255) |byte|
                    try std.testing.expect(std.mem.findScalar(
                        u8,
                        inputs.needle[0..255],
                        @intCast(byte),
                    ) != null);
                for (inputs.hay, 0..) |byte, i|
                    try std.testing.expectEqual(
                        if (inputs.requested) |pos| i == pos + 300 else false,
                        byte == 255,
                    );
            }
            if (case.pattern == .prefix and case.position == .absent) {
                for (inputs.hay) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
                for (inputs.needle[0 .. inputs.needle.len - 1]) |byte|
                    try std.testing.expectEqual(@as(u8, 'a'), byte);
            }
            if (case.pattern == .near) {
                try std.testing.expectEqual(inputs.needle[0], inputs.hay[0]);
                const last = inputs.needle.len - 1;
                const midpoint = inputs.needle.len / 2;
                try std.testing.expectEqual(inputs.needle[last], inputs.hay[last]);
                try std.testing.expect(inputs.needle[midpoint] != inputs.hay[midpoint]);
            }
        }
    }
}

test "pointer-return paths share null, empty and invalid-pointer normalization" {
    const h: [*]const u8 = "abc";
    try std.testing.expectEqual(@as(usize, 1), normalize(stdWrapper(h, 3, "b", 1), h, 3, 1));
    try std.testing.expectEqual(@as(usize, 1), normalize(fastmemWrapper(h, 3, "b", 1), h, 3, 1));
    try std.testing.expectEqual(@as(usize, 0), normalize(stdWrapper(h, 3, "", 0), h, 3, 0));
    try std.testing.expectEqual(missing, normalize(null, h, 3, 1));
    try std.testing.expectEqual(missing - 1, normalize(h + 3, h, 3, 1));
}
