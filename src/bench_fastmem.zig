//! Measurement binary, schema v3. See docs/slop/bench-design.md.
//! All timings use independent code. No external memory implementation is copied here.

const std = @import("std");
const builtin = @import("builtin");
const fastmem = @import("fastmem");
const options = @import("bench_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;
const testing = std.testing;
const linux = std.os.linux;
const ArrayList = std.ArrayList;
const posix = std.posix;
const time = std.time;
const process = std.process;
const meta = std.meta;
const json = std.json;
const print = std.debug.print;
const page_size_min = std.heap.page_size_min;
const DefaultPrng = std.Random.DefaultPrng;
const ArenaAllocator = std.heap.ArenaAllocator;
const c = @import("c");

const chunk_bytes = @min(std.simd.suggestVectorLength(u8) orelse 16, 32);
const standard_sizes = [_]u32{
    0,       1,    2,    3,    4,    7,     8,     15,
    16,      24,   31,   32,   48,   63,    64,    96,
    127,     128,  192,  255,  256,  384,   511,   512,
    768,     1024, 2048, 4096, 8192, 16384, 65536, 262144,
    1048576,
};
const quick_sizes = [_]u32{ 8, 32, 64, 256, 1024, 4096, 16384, 262144 };
const large_sizes = [_]u32{ 1 << 20, 4 << 20, 16 << 20, 64 << 20 };
// Bracket the Zen 5 fill candidate's 32 MiB NT threshold without extra move cases.
const large_set_sizes = [_]u32{ 24 << 20, 32 << 20, 48 << 20 };
const const_sizes = [_]u32{ 1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256 };
const max_size = 1 << 30;
const seq_len = 4096;
const max_iters = 1 << 30;
const set_value = 0xa5;
const schema = 3;
// Memory regions are whole PMD huge pages, so that THP can back every byte.
const huge_page_bytes = 2 << 20;
// Virtual address bits below this alignment are the same in every process. Structures
// indexed or hashed by virtual address (L1D way predictors, TLB sets) then see one layout
// instead of a new ASLR draw per round.
const arena_align = 1 << 30;
// The destination starts one page past its region boundary. Equal profile offsets keep
// their page offset (4K aliasing is the profile's subject), but the addresses stop being
// congruent modulo 2 MiB: caches and predictors that index above bit 11 see two lines.
const dst_stagger = 4096;
// Linux 5.14. std.os.linux.MADV does not define it.
const madv_populate_write = 23;
const madv_collapse = 25;
const thp_dir = "/sys/kernel/mm/transparent_hugepage/";
const has_fastmem_set = @hasDecl(fastmem, "set");
const Op = enum { copy, move, set };
const Impl = enum { builtin, glibc, fastmem_abi, fastmem_inline, builtin_const };
const Suite = enum { quick, standard, large, @"const", dist };
const Mode = enum { indirect, fastmem_inline, builtin_const };
const CopyFn = *const fn ([*]u8, [*]const u8, usize) callconv(.c) [*]u8;
const SetFn = *const fn ([*]u8, c_int, usize) callconv(.c) [*]u8;

noinline fn builtinCopy(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) [*]u8 {
    @memcpy(dst[0..len], src[0..len]);
    return dst;
}
noinline fn builtinMove(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) [*]u8 {
    @memmove(dst[0..len], src[0..len]);
    return dst;
}
noinline fn builtinSet(dst: [*]u8, value: c_int, len: usize) callconv(.c) [*]u8 {
    @memset(dst[0..len], @truncate(@as(c_uint, @bitCast(value))));
    return dst;
}
noinline fn fastmemCopy(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) [*]u8 {
    fastmem.copy(u8, dst[0..len], src[0..len]);
    return dst;
}
noinline fn fastmemMove(dst: [*]u8, src: [*]const u8, len: usize) callconv(.c) [*]u8 {
    fastmem.move(u8, dst[0..len], src[0..len]);
    return dst;
}
noinline fn fastmemSet(dst: [*]u8, value: c_int, len: usize) callconv(.c) [*]u8 {
    if (has_fastmem_set) fastmem.set(u8, dst[0..len], @truncate(@as(c_uint, @bitCast(value))));
    return dst;
}
comptime {
    @export(&builtinCopy, .{ .name = "builtin_memcpy" });
    @export(&builtinMove, .{ .name = "builtin_memmove" });
    @export(&builtinSet, .{ .name = "builtin_memset" });
    @export(&fastmemCopy, .{ .name = "fastmem_copy" });
    @export(&fastmemMove, .{ .name = "fastmem_move" });
    if (has_fastmem_set) @export(&fastmemSet, .{ .name = "fastmem_set" });
}

const Evidence = struct {
    address: u64,
    dli_fname: []const u8,
    dli_fbase: u64,
    offset: u64,

    fn resolve(ptr: *const anyopaque) !Evidence {
        var info: c.Dl_info = mem.zeroes(c.Dl_info);
        if (c.dladdr(ptr, &info) == 0 or info.dli_fname == null or info.dli_fbase == null)
            return error.DladdrFailed;
        const address = @intFromPtr(ptr);
        const base = @intFromPtr(info.dli_fbase);
        if (address < base) return error.InvalidLibraryBase;
        return .{
            .address = address,
            .dli_fname = mem.span(info.dli_fname),
            .dli_fbase = base,
            .offset = address - base,
        };
    }
};
const Resolution = struct {
    glibc: Evidence,
    builtin: Evidence,
};
const Symbols = struct {
    handle: *anyopaque,
    libc_path: []const u8,
    libc_base: u64,
    resolution: [3]Resolution,
    copy: CopyFn,
    move: CopyFn,
    set: SetFn,

    fn init() !Symbols {
        const handle = c.dlopen("libc.so.6", c.RTLD_NOW | c.RTLD_LOCAL) orelse
            return error.LibcDlopenFailed;
        errdefer _ = c.dlclose(handle);
        var map: ?*c.struct_link_map = null;
        if (c.dlinfo(handle, c.RTLD_DI_LINKMAP, @ptrCast(&map)) != 0 or map == null)
            return error.LibcLinkMapFailed;
        const library = map.?;
        const path = mem.span(library.l_name);
        const own = try Evidence.resolve(@ptrCast(&builtinCopy));
        var result: Symbols = undefined;
        result.handle = handle;
        result.libc_path = path;
        result.libc_base = library.l_addr;
        inline for (.{ "memcpy", "memmove", "memset" }, 0..) |name, index| {
            const ptr = c.dlsym(handle, name) orelse return error.LibcDlsymFailed;
            const reference = try Evidence.resolve(ptr);
            const local = try Evidence.resolve(@ptrCast(@extern(
                if (index == 2) SetFn else CopyFn,
                .{ .name = name },
            )));
            try validateResolution(reference, local, own, path, library.l_addr);
            result.resolution[index] = .{ .glibc = reference, .builtin = local };
            switch (index) {
                0 => result.copy = @ptrCast(@alignCast(ptr)),
                1 => result.move = @ptrCast(@alignCast(ptr)),
                2 => result.set = @ptrCast(@alignCast(ptr)),
                else => unreachable,
            }
        }
        return result;
    }
    fn deinit(self: *Symbols) void {
        _ = c.dlclose(self.handle);
        self.* = undefined;
    }
};

fn validateResolution(
    reference: Evidence,
    local: Evidence,
    own: Evidence,
    path: []const u8,
    base: u64,
) !void {
    if (!mem.eql(u8, reference.dli_fname, path) or reference.dli_fbase != base or
        reference.dli_fbase == own.dli_fbase or !mem.endsWith(u8, path, "/libc.so.6"))
        return error.GlibcResolvedOutsideLibc;
    if (local.dli_fbase == base or local.dli_fbase != own.dli_fbase)
        return error.BuiltinDidNotResolveToExecutable;
}

test "resolution rejects executable glibc and libc builtins" {
    var symbols = try Symbols.init();
    defer symbols.deinit();
    const pair = symbols.resolution[0];
    const own = try Evidence.resolve(@ptrCast(&builtinCopy));
    try testing.expectError(
        error.GlibcResolvedOutsideLibc,
        validateResolution(pair.builtin, pair.builtin, own, symbols.libc_path, symbols.libc_base),
    );
    try testing.expectError(
        error.BuiltinDidNotResolveToExecutable,
        validateResolution(pair.glibc, pair.glibc, own, symbols.libc_path, symbols.libc_base),
    );
}

const Counts = struct {
    cycles: u64,
    instructions: u64,
    ref_cycles: ?u64,
    time_enabled: u64,
    time_running: u64,
};
const PerfError = struct {
    event: []const u8,
    action: []const u8,
    detail: []const u8,
};
const PerfSystem = struct {
    fn open(config: linux.PERF.COUNT.HW, group: i32) usize {
        var attr: linux.perf_event_attr = .{};
        attr.type = .HARDWARE;
        attr.config = @intFromEnum(config);
        attr.read_format = 8 | 1 | 2; // GROUP | TOTAL_TIME_ENABLED | TOTAL_TIME_RUNNING.
        attr.flags.disabled = group == -1;
        attr.flags.exclude_kernel = true;
        attr.flags.exclude_hv = true;
        return linux.perf_event_open(&attr, 0, -1, group, 0);
    }
    fn close(fd: i32) void {
        _ = linux.close(fd);
    }
};
const Perf = struct {
    fds: [3]i32 = .{ -1, -1, -1 },
    failure: ?PerfError = null,
    warning: ?PerfError = null,
    event_count: u8 = 2,
    previous_enabled: u64 = 0,
    previous_running: u64 = 0,
    const names = [_][]const u8{ "cycles", "instructions", "ref-cycles" };
    const group_flag = 1;

    fn init() Perf {
        var self = openEvents(PerfSystem, builtin.cpu.arch == .x86_64);
        self.begin();
        _ = self.end();
        return self;
    }
    fn openEvents(comptime system: type, want_ref: bool) Perf {
        var self: Perf = .{ .event_count = if (want_ref) 3 else 2 };
        const configs = [_]linux.PERF.COUNT.HW{ .CPU_CYCLES, .INSTRUCTIONS, .REF_CPU_CYCLES };
        for (0..2) |_| {
            for (configs[0..self.event_count], 0..) |config, index| {
                const rc = system.open(config, self.fds[0]);
                if (linux.errno(rc) != .SUCCESS) {
                    self.failure = .{
                        .event = names[index],
                        .action = "perf_event_open",
                        .detail = @tagName(linux.errno(rc)),
                    };
                    self.closeWith(system);
                    if (index != 2) return self;
                    // Unsupported ref-cycles must not hide cycles and instructions.
                    self.warning = self.failure;
                    self.failure = null;
                    self.event_count = 2;
                    break;
                }
                self.fds[index] = @intCast(rc);
            }
            if (self.fds[0] >= 0) return self;
        }
        unreachable;
    }
    fn closeWith(self: *Perf, comptime system: type) void {
        for (&self.fds) |*fd| {
            if (fd.* >= 0) system.close(fd.*);
            fd.* = -1;
        }
    }
    fn close(self: *Perf) void {
        self.closeWith(PerfSystem);
    }
    fn eventNames(self: Perf) []const []const u8 {
        return names[0..self.event_count];
    }
    fn errorMessage(self: Perf, buffer: []u8) ?[]const u8 {
        const first = self.warning orelse self.failure orelse return null;
        const message = fmt.bufPrint(buffer, "{s}({s}): {s}", .{
            first.action, first.event, first.detail,
        }) catch unreachable;
        if (self.warning != null) {
            if (self.failure) |failure| {
                const rest = fmt.bufPrint(buffer[message.len..], ". {s}({s}): {s}", .{
                    failure.action, failure.event, failure.detail,
                }) catch unreachable;
                return buffer[0 .. message.len + rest.len];
            }
        }
        return message;
    }
    fn ioctl(self: *Perf, request: u32) bool {
        const err = linux.errno(linux.ioctl(self.fds[0], request, group_flag));
        if (err == .SUCCESS) return true;
        self.failure = .{
            .event = "cycles group",
            .action = switch (request) {
                0x2403 => "reset",
                0x2400 => "enable",
                else => "disable",
            },
            .detail = @tagName(err),
        };
        self.close();
        return false;
    }
    fn begin(self: *Perf) void {
        if (self.failure != null) return;
        if (!self.ioctl(0x2403)) return; // RESET the entire group, not only the leader.
        _ = self.ioctl(0x2400);
    }
    fn end(self: *Perf) ?Counts {
        if (self.failure != null or !self.ioctl(0x2401)) return null;
        var data: [6]u64 = undefined;
        const bytes = mem.sliceAsBytes(data[0 .. 3 + self.event_count]);
        const n = posix.read(self.fds[0], bytes) catch |err| {
            self.failure = .{
                .event = "cycles group",
                .action = "read",
                .detail = @errorName(err),
            };
            self.close();
            return null;
        };
        if (n != bytes.len or data[0] != self.event_count or
            data[1] < self.previous_enabled or data[2] < self.previous_running)
        {
            self.failure = .{ .event = "cycles group", .action = "read", .detail = "invalid data" };
            self.close();
            return null;
        }
        // PERF_EVENT_IOC_RESET does not reset the time fields. Report sample deltas.
        const enabled = data[1] - self.previous_enabled;
        const running = data[2] - self.previous_running;
        self.previous_enabled = data[1];
        self.previous_running = data[2];
        return .{
            .cycles = data[3],
            .instructions = data[4],
            .ref_cycles = if (self.event_count == 3) data[5] else null,
            .time_enabled = enabled,
            .time_running = running,
        };
    }
};

test "perf retries without ref-cycles and identifies the failed event" {
    const Fake = struct {
        var opens: u8 = 0;
        var closes: u8 = 0;
        fn open(config: linux.PERF.COUNT.HW, group: i32) usize {
            opens += 1;
            if (config == .CPU_CYCLES) std.debug.assert(group == -1);
            if (config == .REF_CPU_CYCLES)
                return @bitCast(-@as(isize, @intFromEnum(linux.E.NOENT)));
            return 100 + @as(usize, opens);
        }
        fn close(_: i32) void {
            closes += 1;
        }
    };
    var perf = Perf.openEvents(Fake, true);
    defer perf.closeWith(Fake);
    try testing.expectEqual(@as(u8, 5), Fake.opens);
    try testing.expectEqual(@as(u8, 2), Fake.closes);
    try testing.expectEqual(@as(u8, 2), perf.event_count);
    try testing.expect(perf.failure == null);
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "perf_event_open(ref-cycles): NOENT",
        perf.errorMessage(&buffer).?,
    );
    try testing.expectEqualStrings("instructions", perf.eventNames()[1]);
}

test "perf consecutive samples reset instructions for the whole group" {
    var perf: Perf = .init();
    defer perf.close();
    if (perf.failure != null) {
        var buffer: [512]u8 = undefined;
        print("perf test skipped: {s}\n", .{perf.errorMessage(&buffer).?});
        return error.SkipZigTest;
    }
    var counts: [2]Counts = undefined;
    for (&counts, 0..) |*count, index| {
        perf.begin();
        var value: u64 = 1;
        const iterations: u64 = if (index == 0) 2_000_000 else 100_000;
        for (0..iterations) |_| {
            value = value *% 6364136223846793005 +% 1;
            mem.doNotOptimizeAway(value);
        }
        count.* = perf.end() orelse return error.SkipZigTest;
    }
    if (counts[0].time_running == 0 or counts[1].time_running == 0) return error.SkipZigTest;
    try testing.expect(counts[0].instructions > 0 and counts[1].instructions > 0);
    try testing.expect(counts[1].instructions < counts[0].instructions / 2);
}

const Config = struct {
    suite: Suite = .standard,
    impls: []const Impl = &.{ .builtin, .glibc, .fastmem_abi, .fastmem_inline, .builtin_const },
    filters: ArrayList([]const u8) = .empty,
    samples: u32 = 0,
    sample_ms: u32 = 20,
    warmup_ms: u32 = 10,
    seed: u64 = 1,
    dist_file: ?[]const u8 = null,
    codegen_file: ?[]const u8 = null,
    list: bool = false,

    fn matches(self: Config, id: []const u8) bool {
        if (self.filters.items.len == 0) return true;
        for (self.filters.items) |filter| if (mem.find(u8, id, filter) != null) return true;
        return false;
    }
};
fn parseArgs(arena: Allocator, args: []const [:0]const u8) !Config {
    var cfg: Config = .{};
    var index: u32 = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (mem.eql(u8, arg, "--list")) {
            cfg.list = true;
            continue;
        }
        var parts = mem.splitScalar(u8, arg, '=');
        const flag = parts.next().?;
        const value = parts.next() orelse blk: {
            index += 1;
            if (index == args.len) return error.MissingFlagValue;
            break :blk args[index];
        };
        if (mem.eql(u8, flag, "--suite")) {
            cfg.suite = meta.stringToEnum(Suite, value) orelse return error.InvalidSuite;
        } else if (mem.eql(u8, flag, "--impl")) {
            var list: ArrayList(Impl) = .empty;
            var names = mem.splitScalar(u8, value, ',');
            while (names.next()) |name| {
                const impl = meta.stringToEnum(Impl, name) orelse
                    return error.InvalidImplementation;
                if (mem.findScalar(Impl, list.items, impl) != null)
                    return error.DuplicateImplementation;
                try list.append(arena, impl);
            }
            cfg.impls = list.items;
        } else if (mem.eql(u8, flag, "--filter")) {
            try cfg.filters.append(arena, value);
        } else if (mem.eql(u8, flag, "--dist-file")) {
            cfg.dist_file = value;
        } else if (mem.eql(u8, flag, "--codegen-file")) {
            cfg.codegen_file = value;
        } else if (mem.eql(u8, flag, "--seed")) {
            cfg.seed = try fmt.parseInt(u64, value, 10);
        } else if (mem.eql(u8, flag, "--samples")) {
            cfg.samples = try fmt.parseInt(u32, value, 10);
            if (cfg.samples == 0) return error.InvalidSampleCount;
        } else if (mem.eql(u8, flag, "--sample-ms")) {
            cfg.sample_ms = try fmt.parseInt(u32, value, 10);
        } else if (mem.eql(u8, flag, "--warmup-ms")) {
            cfg.warmup_ms = try fmt.parseInt(u32, value, 10);
        } else return error.UnknownFlag;
    }
    if (cfg.samples > 10000 or cfg.sample_ms == 0 or
        cfg.sample_ms > 60000 or cfg.warmup_ms > 60000) return error.InvalidDurationOrSamples;
    if (cfg.dist_file != null and cfg.suite != .dist) return error.DistFileRequiresDistSuite;
    return cfg;
}

const Entry = struct { size: u32, src_off: u32, dst_off: u32 };
const Case = struct {
    id: []const u8,
    op: Op,
    profile: []const u8,
    size: f64,
    max_len: u32,
    src_off: u32 = 0,
    dst_off: u32 = 0,
    gap: ?u32 = null,
    shared: bool = false,
    seq: ?[]const Entry = null,

    fn accepts(self: Case, impl: Impl) bool {
        const fastmem_impl = impl == .fastmem_abi or impl == .fastmem_inline;
        if (self.op == .set and !has_fastmem_set and fastmem_impl) return false;
        return if (self.constant())
            impl == .builtin_const or impl == .fastmem_inline
        else
            impl != .builtin_const;
    }
    fn constant(self: Case) bool {
        return mem.eql(u8, self.profile, "const");
    }
    // Bytes of each arena region that the case can touch.
    fn footprint(self: Case) u64 {
        const padding: u64 = if (self.seq != null)
            512
        else
            @as(u64, @max(self.src_off, self.dst_off)) + 1;
        return @as(u64, self.max_len) + padding;
    }
};
fn addConstCases(arena: Allocator, cases: *ArrayList(Case), cfg: Config) !void {
    for ([_]Op{ .copy, .move, .set }) |op| {
        for (const_sizes) |size|
            try addCase(arena, cases, cfg, try fixedCase(arena, op, "const", size));
    }
}
fn addCase(arena: Allocator, cases: *ArrayList(Case), cfg: Config, case: Case) !void {
    if (!cfg.matches(case.id)) return;
    for (cfg.impls) |impl| {
        if (case.accepts(impl)) {
            try cases.append(arena, case);
            return;
        }
    }
}
fn fixedCase(arena: Allocator, op: Op, profile: []const u8, size: u32) !Case {
    return .{
        .id = try fmt.allocPrint(arena, "{s}/{s}/{d}", .{ @tagName(op), profile, size }),
        .op = op,
        .profile = profile,
        .size = @floatFromInt(size),
        .max_len = size,
    };
}
const Weight = struct { size: u32, cumulative: f64 };
fn readHistogram(arena: Allocator, io: Io, path: []const u8) ![]const Weight {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const parsed = try json.parseFromSlice(json.Value, arena, bytes, .{});
    if (parsed.value != .object) return error.HistogramMustBeObject;
    var weights: ArrayList(Weight) = .empty;
    var iterator = parsed.value.object.iterator();
    var total: f64 = 0;
    while (iterator.next()) |entry| {
        const size = try fmt.parseInt(u32, entry.key_ptr.*, 10);
        if (size > max_size) return error.HistogramSizeTooLarge;
        const weight: f64 = switch (entry.value_ptr.*) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => return error.InvalidHistogramWeight,
        };
        if (!math.isFinite(weight) or weight < 0) return error.InvalidHistogramWeight;
        if (weight == 0) continue;
        total += weight;
        if (!math.isFinite(total)) return error.InvalidHistogramWeight;
        try weights.append(arena, .{ .size = size, .cumulative = total });
    }
    if (total == 0) return error.EmptyHistogram;
    return weights.items;
}
fn distribution(
    arena: Allocator,
    cfg: Config,
    op: Op,
    name: []const u8,
    weights: ?[]const Weight,
) !Case {
    var prng = DefaultPrng.init(cfg.seed +% @as(u64, @intFromEnum(op)));
    const random = prng.random();
    const seq = try arena.create([seq_len]Entry);
    var sum: u64 = 0;
    var maximum: u32 = 0;
    const off_max: u32 = if (mem.eql(u8, name, "small")) 127 else 511;
    for (seq) |*entry| {
        const size: u32 = if (weights) |hist| blk: {
            const draw = random.float(f64) * hist[hist.len - 1].cumulative;
            for (hist) |weight| if (draw < weight.cumulative) break :blk weight.size;
            break :blk hist[hist.len - 1].size;
        } else if (mem.eql(u8, name, "small")) @min(
            random.intRangeAtMost(u32, 0, 256),
            random.intRangeAtMost(u32, 0, 256),
        ) else @trunc(@exp(@log(@as(f64, 16385)) * random.float(f64)) - 1);
        entry.* = .{
            .size = size,
            .src_off = random.intRangeAtMost(u32, 0, off_max),
            .dst_off = random.intRangeAtMost(u32, 0, off_max),
        };
        sum += size;
        maximum = @max(maximum, size);
    }
    return .{
        .id = try fmt.allocPrint(arena, "{s}/dist/{s}", .{ @tagName(op), name }),
        .op = op,
        .profile = "dist",
        .size = @as(f64, @floatFromInt(sum)) / seq_len,
        .max_len = maximum,
        .shared = op == .move,
        .seq = seq,
    };
}
fn buildCases(arena: Allocator, io: Io, cfg: Config) ![]Case {
    var cases: ArrayList(Case) = .empty;
    if (cfg.suite == .dist) {
        const weights = if (cfg.dist_file) |path| try readHistogram(arena, io, path) else null;
        for ([_]Op{ .copy, .move, .set }) |op| {
            const names: []const []const u8 = if (weights != null)
                &.{"file"}
            else
                &.{ "small", "mixed" };
            for (names) |name|
                try addCase(arena, &cases, cfg, try distribution(arena, cfg, op, name, weights));
        }
    } else if (cfg.suite == .@"const") {
        try addConstCases(arena, &cases, cfg);
    } else {
        const sizes: []const u32 = switch (cfg.suite) {
            .quick => &quick_sizes,
            .large => &large_sizes,
            else => &standard_sizes,
        };
        for (sizes) |size| {
            for ([_]Op{ .copy, .set }) |op| {
                const profiles: []const []const u8 = if (op == .copy)
                    &.{ "aligned", "misaligned", "cross-lane", "page-offset" }
                else
                    &.{ "aligned", "misaligned" };
                for (profiles, 0..) |profile, index| {
                    var case = try fixedCase(arena, op, profile, size);
                    case.src_off = switch (index) {
                        1 => 1,
                        2 => chunk_bytes - 1,
                        else => 0,
                    };
                    case.dst_off = switch (index) {
                        1 => 3,
                        2 => chunk_bytes / 2,
                        3 => 2048,
                        else => 0,
                    };
                    try addCase(arena, &cases, cfg, case);
                }
            }
            try addCase(arena, &cases, cfg, try fixedCase(arena, .move, "disjoint", size));
            const forward_profiles = [_][]const u8{ "fwd-gap4096", "fwd-half" };
            for (forward_profiles, [_]u32{ 4096, size / 2 }) |profile, gap| {
                var case = try fixedCase(arena, .move, profile, size);
                case.gap = gap;
                case.shared = true;
                case.src_off = gap;
                try addCase(arena, &cases, cfg, case);
            }
            for ([_]bool{ false, true }) |backward| {
                for ([_]u32{ 1, chunk_bytes - 1, chunk_bytes + 1 }) |gap| {
                    const profile = try fmt.allocPrint(arena, "{s}-gap{d}", .{
                        if (backward) "bwd" else "fwd", gap,
                    });
                    var case = try fixedCase(arena, .move, profile, size);
                    case.gap = gap;
                    case.shared = true;
                    case.src_off = if (backward) 0 else gap;
                    case.dst_off = if (backward) gap else 0;
                    try addCase(arena, &cases, cfg, case);
                }
            }
        }
    }
    if (cfg.suite == .large) {
        for (large_set_sizes) |size| {
            for ([_][]const u8{ "aligned", "misaligned" }, [_]u32{ 0, 3 }) |profile, offset| {
                var case = try fixedCase(arena, .set, profile, size);
                case.src_off = if (offset == 0) 0 else 1;
                case.dst_off = offset;
                try addCase(arena, &cases, cfg, case);
            }
        }
    }
    if (cfg.suite == .standard) {
        try addConstCases(arena, &cases, cfg);
        for ([_]Op{ .copy, .move, .set }) |op| {
            for ([_][]const u8{ "small", "mixed" }) |name|
                try addCase(arena, &cases, cfg, try distribution(arena, cfg, op, name, null));
        }
    }
    if (cases.items.len == 0) return error.NoMatchingCases;
    return cases.items;
}

test "large fills bracket the NT threshold without extra copy or move cases" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = try buildCases(arena.allocator(), testing.io, .{ .suite = .large });
    try testing.expectEqual(66, cases.len);
    var extra: u32 = 0;
    for (cases) |case| {
        if (mem.findScalar(u32, &large_set_sizes, case.max_len) != null) {
            try testing.expectEqual(Op.set, case.op);
            const misaligned = mem.eql(u8, case.profile, "misaligned");
            try testing.expectEqual(@as(u32, if (misaligned) 1 else 0), case.src_off);
            try testing.expectEqual(@as(u32, if (misaligned) 3 else 0), case.dst_off);
            extra += 1;
        }
    }
    try testing.expectEqual(6, extra);
}

const Buffers = struct {
    src: []align(page_size_min) u8,
    dst: []align(page_size_min) u8,
};

/// Transparent huge page policy of the host, from sysfs.
const Thp = struct {
    enabled: ?[]const u8,
    defrag: ?[]const u8,
    pmd_bytes: ?u64,

    /// The allocator must be an arena: the strings live until the process ends.
    fn read(arena: Allocator, io: Io) Thp {
        const size = sysfs("hpage_pmd_size", arena, io);
        return .{
            .enabled = selected(sysfs("enabled", arena, io)),
            .defrag = selected(sysfs("defrag", arena, io)),
            .pmd_bytes = if (size) |text|
                fmt.parseInt(u64, mem.trim(u8, text, " \n"), 10) catch null
            else
                null,
        };
    }
    fn sysfs(comptime name: []const u8, arena: Allocator, io: Io) ?[]const u8 {
        return readKernelFile(arena, io, thp_dir ++ name, 4096);
    }
    /// The active choice of a sysfs policy list, for example `madvise` in
    /// `always [madvise] never`.
    fn selected(text: ?[]const u8) ?[]const u8 {
        const after = (mem.cutScalar(u8, text orelse return null, '[') orelse return null)[1];
        return (mem.cutScalar(u8, after, ']') orelse return null)[0];
    }
};

test "thp policy parsing selects the bracketed value" {
    try testing.expectEqualStrings("madvise", Thp.selected("always [madvise] never\n").?);
    try testing.expectEqualStrings("always", Thp.selected("[always] defer never").?);
    try testing.expect(Thp.selected("always madvise never") == null);
    try testing.expect(Thp.selected(null) == null);
}

/// The benchmark memory: one mapping for every case of the run. It is allocated and
/// pre-faulted once, before any timing. Each case uses the same fixed offsets in it, so
/// physical placement does not change between cases, and virtual placement does not
/// change between processes. With THP, the physical address bits below 21 equal the
/// virtual bits: cache indexes that use only those bits are then the same in every
/// round. Indexes that use higher physical bits can still differ between processes.
///
/// Layout: [src region][dst region][seq region]. Every region is a multiple of 2 MiB.
/// The destination view starts `dst_stagger` bytes into its region.
const Memory = struct {
    bytes: []align(page_size_min) u8,
    region_bytes: u64,
    advice: linux.E,
    populate: linux.E,
    collapse: linux.E,
    thp: Thp,
    huge_start: ?u64,
    huge_end: ?u64 = null,

    const seq_bytes = mem.alignForward(u64, seq_len * @sizeOf(Entry), huge_page_bytes);

    fn init(arena: Allocator, io: Io, cases: []const Case) !Memory {
        var need: u64 = 1;
        for (cases) |case| need = @max(need, case.footprint());
        const region_bytes = mem.alignForward(u64, need + dst_stagger, huge_page_bytes);
        const bytes = try reserveAligned(2 * region_bytes + seq_bytes);
        errdefer posix.munmap(bytes);
        // The advice must precede the first touch: a fault in an advised range allocates
        // a huge page directly. khugepaged would collapse pages later, during timing.
        const advice = advise(bytes, linux.MADV.HUGEPAGE);
        const populate = advise(bytes, madv_populate_write);
        // Without MADV_POPULATE_WRITE, these stores fault in every page before timing.
        // Each case restores its own footprint later. The bytes are synthetic, never secrets.
        @memset(bytes, 0x5a);
        // A fault falls back to small pages when no free huge page exists. The collapse
        // retries with synchronous compaction (Linux 6.1). It is a no-op for huge pages.
        const collapse = advise(bytes, madv_collapse);
        var self: Memory = .{
            .bytes = bytes,
            .region_bytes = region_bytes,
            .advice = advice,
            .populate = populate,
            .collapse = collapse,
            .thp = .read(arena, io),
            .huge_start = null,
        };
        self.huge_start = self.hugeBytes(arena, io);
        return self;
    }
    fn deinit(self: *Memory) void {
        posix.munmap(self.bytes);
        self.* = undefined;
    }
    /// Restores the initial bytes of the case footprint and returns views at the fixed
    /// region starts. A shared case uses only the source region.
    fn buffers(self: Memory, case: Case) Buffers {
        const len = case.footprint();
        fill(self.bytes, self.region_bytes, len);
        return .{
            .src = self.bytes[0..len],
            .dst = @alignCast(self.bytes[self.region_bytes + dst_stagger ..][0..len]),
        };
    }
    /// Copies a distribution sequence to the fixed sequence region.
    fn placeSeq(self: Memory, seq: []const Entry) []const Entry {
        const slot: [*]Entry = @ptrCast(@alignCast(self.bytes[2 * self.region_bytes ..].ptr));
        @memcpy(slot[0..seq.len], seq);
        return slot[0..seq.len];
    }
    // The regions contain synthetic bytes, never secrets.
    fn fill(bytes: []u8, region_bytes: u64, len: u64) void {
        for (bytes[0..len], 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);
        @memset(bytes[region_bytes + dst_stagger ..][0..len], 0x5a);
    }
    fn advise(bytes: []align(page_size_min) u8, advice: u32) linux.E {
        return linux.errno(linux.madvise(bytes.ptr, bytes.len, advice));
    }
    fn hugeBytes(self: Memory, arena: Allocator, io: Io) ?u64 {
        const smaps = readKernelFile(arena, io, "/proc/self/smaps", 64 << 20) orelse return null;
        defer arena.free(smaps);
        return anonHugeBytes(smaps, @intFromPtr(self.bytes.ptr), self.bytes.len);
    }
    fn meta(self: Memory) MemoryMeta {
        return .{
            .arena_bytes = self.bytes.len,
            .region_bytes = self.region_bytes,
            .dst_offset = self.region_bytes + dst_stagger,
            .seq_offset = 2 * self.region_bytes,
            .hugepage_advice = @tagName(self.advice),
            .populate = @tagName(self.populate),
            .collapse = @tagName(self.collapse),
            .thp_enabled = self.thp.enabled,
            .thp_defrag = self.thp.defrag,
            .thp_pmd_bytes = self.thp.pmd_bytes,
            .anon_huge_bytes_start = self.huge_start,
            .anon_huge_bytes_end = self.huge_end,
        };
    }
};
const MemoryMeta = struct {
    layout: []const u8 = "arena",
    arena_bytes: u64,
    region_bytes: u64,
    base_align: u64 = arena_align,
    src_offset: u64 = 0,
    dst_offset: u64,
    seq_offset: u64,
    hugepage_advice: []const u8,
    populate: []const u8,
    collapse: []const u8,
    thp_enabled: ?[]const u8,
    thp_defrag: ?[]const u8,
    thp_pmd_bytes: ?u64,
    anon_huge_bytes_start: ?u64,
    anon_huge_bytes_end: ?u64,
};

/// procfs reports size 0, so a positional read stops at once. Read the stream.
fn readKernelFile(arena: Allocator, io: Io, path: []const u8, limit: usize) ?[]u8 {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(arena, .limited(limit)) catch null;
}

/// Maps `len` bytes at an `arena_align` boundary. It reserves the slack as PROT_NONE,
/// maps the aligned part over it, and releases the rest.
fn reserveAligned(len: u64) ![]align(page_size_min) u8 {
    const private: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true };
    const reserve = try posix.mmap(null, len + arena_align, .{}, private, -1, 0);
    const start = @intFromPtr(reserve.ptr);
    const base = mem.alignForward(u64, start, arena_align);
    var fixed = private;
    fixed.FIXED = true;
    fixed.NORESERVE = false;
    const bytes = posix.mmap(
        @ptrFromInt(base),
        len,
        .{ .READ = true, .WRITE = true },
        fixed,
        -1,
        0,
    ) catch |err| {
        posix.munmap(reserve);
        return err;
    };
    if (base > start) posix.munmap(reserve[0 .. base - start]);
    const tail = base - start + len;
    if (tail < reserve.len) posix.munmap(@alignCast(reserve[tail..]));
    return bytes;
}

/// Sums AnonHugePages over the mappings of /proc/self/smaps that overlap [start, start+len).
fn anonHugeBytes(smaps: []const u8, start: u64, len: u64) ?u64 {
    var total: u64 = 0;
    var found = false;
    var inside = false;
    var lines = mem.splitScalar(u8, smaps, '\n');
    while (lines.next()) |line| {
        if (vmaRange(line)) |range| {
            inside = range[0] < start + len and start < range[1];
            found = found or inside;
        } else if (inside) {
            const rest = mem.cutPrefix(u8, line, "AnonHugePages:") orelse continue;
            const kib = fmt.parseInt(u64, mem.trim(u8, rest, " kB"), 10) catch return null;
            total += kib * 1024;
        }
    }
    return if (found) total else null;
}
fn vmaRange(line: []const u8) ?[2]u64 {
    const token = (mem.cutScalar(u8, line, ' ') orelse return null)[0];
    const low, const high = mem.cutScalar(u8, token, '-') orelse return null;
    return .{
        fmt.parseInt(u64, low, 16) catch return null,
        fmt.parseInt(u64, high, 16) catch return null,
    };
}

test "smaps parsing sums huge pages of the overlapping mappings only" {
    const smaps =
        \\40000000-40400000 rw-p 00000000 00:00 0 
        \\Size:               4096 kB
        \\AnonHugePages:      2048 kB
        \\VmFlags: rd wr mr mw me ac hg
        \\40400000-40600000 rw-p 00000000 00:00 0 
        \\AnonHugePages:      2048 kB
        \\7f0000000000-7f0000001000 r-xp 00000000 00:00 0    [vdso]
        \\AnonHugePages:      4096 kB
    ;
    try testing.expectEqual(@as(?u64, 4 << 20), anonHugeBytes(smaps, 0x40000000, 6 << 20));
    try testing.expectEqual(@as(?u64, 2 << 20), anonHugeBytes(smaps, 0x40000000, 4 << 20));
    try testing.expectEqual(@as(?u64, null), anonHugeBytes(smaps, 0x50000000, 4096));
}

test "memory regions sit at fixed offsets from an aligned base" {
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const cases = [_]Case{
        .{ .id = "copy/aligned/8", .op = .copy, .profile = "aligned", .size = 8, .max_len = 8 },
        .{
            .id = "move/fwd-half/65536",
            .op = .move,
            .profile = "fwd-half",
            .size = 65536,
            .max_len = 65536,
            .src_off = 32768,
        },
    };
    var memory: Memory = try .init(arena_state.allocator(), testing.io, &cases);
    defer memory.deinit();
    try testing.expectEqual(@as(u64, 0), @intFromPtr(memory.bytes.ptr) % arena_align);
    try testing.expectEqual(@as(u64, huge_page_bytes), memory.region_bytes);
    try testing.expectEqual(@as(u64, 3 * huge_page_bytes), memory.bytes.len);
    try testing.expect(memory.huge_start != null);
    const views = memory.buffers(cases[1]);
    try testing.expectEqual(memory.bytes.ptr, views.src.ptr);
    try testing.expectEqual(memory.bytes[huge_page_bytes + dst_stagger ..].ptr, views.dst.ptr);
    try testing.expectEqual(@as(usize, 65536 + 32769), views.dst.len);
    try testing.expectEqual(@as(u8, 17 +% 131), views.src[1]);
    try testing.expectEqual(@as(u8, 0x5a), views.dst[views.dst.len - 1]);
}
const Functions = struct { copy: CopyFn, set: SetFn };
const Result = struct { ns: u64, iters: u64, counters: ?Counts };

// The volatile load stops LLVM from specializing the shared indirect loop for a known wrapper.
// Every indirect implementation enters the same instantiation, with one pointer load per batch.
inline fn loopBody(
    comptime op: Op,
    comptime mode: Mode,
    comptime const_len: ?u32,
    io: Io,
    perf: ?*Perf,
    functions: *const Functions,
    case: Case,
    buffers: Buffers,
    iters: u64,
) Result {
    const function = if (op == .set)
        @as(*const volatile SetFn, &functions.set).*
    else
        @as(*const volatile CopyFn, &functions.copy).*;
    const dest_buffer = if (case.shared) buffers.src else buffers.dst;
    if (perf) |p| p.begin();
    const start = Io.Timestamp.now(io, .awake);
    for (0..iters) |iteration| {
        const entry = if (case.seq) |seq| seq[iteration & (seq_len - 1)] else Entry{
            .size = case.max_len,
            .src_off = case.src_off,
            .dst_off = case.dst_off,
        };
        const len = const_len orelse entry.size;
        const src = buffers.src[entry.src_off..].ptr;
        const dst = dest_buffer[entry.dst_off..].ptr;
        switch (mode) {
            .indirect => {
                _ = if (op == .set) function(dst, set_value, len) else function(dst, src, len);
            },
            .fastmem_inline => switch (op) {
                .copy => fastmem.copy(u8, dst[0..len], src[0..len]),
                .move => fastmem.move(u8, dst[0..len], src[0..len]),
                .set => if (has_fastmem_set) fastmem.set(u8, dst[0..len], set_value),
            },
            .builtin_const => switch (op) {
                .copy => @memcpy(dst[0..len], src[0..len]),
                .move => @memmove(dst[0..len], src[0..len]),
                .set => @memset(dst[0..len], set_value),
            },
        }
        // A memory clobber preserves the full inline operation, not just the observed byte.
        asm volatile ("" ::: .{ .memory = true });
        if (len != 0) _ = @as(*volatile u8, &dst[0]).*;
    }
    const ns: u64 = @intCast(start.durationTo(.now(io, .awake)).nanoseconds);
    const counters = if (perf) |p| p.end() else null;
    return .{ .ns = ns, .iters = iters, .counters = counters };
}
// Dedicated entry names let the harness inspect inline fastmem separately from builtin_const.
noinline fn runFastmemInline(
    comptime op: Op,
    comptime const_len: ?u32,
    io: Io,
    perf: ?*Perf,
    functions: *const Functions,
    case: Case,
    buffers: Buffers,
    iters: u64,
) Result {
    return loopBody(op, .fastmem_inline, const_len, io, perf, functions, case, buffers, iters);
}
noinline fn runLoop(
    comptime op: Op,
    comptime mode: Mode,
    comptime const_len: ?u32,
    io: Io,
    perf: ?*Perf,
    functions: *const Functions,
    case: Case,
    buffers: Buffers,
    iters: u64,
) Result {
    return loopBody(op, mode, const_len, io, perf, functions, case, buffers, iters);
}
fn runBatch(
    io: Io,
    perf: ?*Perf,
    symbols: *const Symbols,
    case: Case,
    buffers: Buffers,
    impl: Impl,
    iters: u64,
) Result {
    const functions: Functions = .{
        .copy = switch (impl) {
            .glibc => if (case.op == .move) symbols.move else symbols.copy,
            .fastmem_abi => if (case.op == .move)
                @as(CopyFn, @ptrCast(fastmem.abi.memmove))
            else
                @as(CopyFn, @ptrCast(fastmem.abi.memcpy)),
            else => if (case.op == .move)
                @extern(CopyFn, .{ .name = "memmove" })
            else
                @extern(CopyFn, .{ .name = "memcpy" }),
        },
        .set = switch (impl) {
            .glibc => symbols.set,
            .fastmem_abi => @as(SetFn, @ptrCast(fastmem.abi.memset)),
            else => @extern(SetFn, .{ .name = "memset" }),
        },
    };
    if (case.constant()) {
        inline for (const_sizes) |len| {
            if (case.max_len == len) return switch (case.op) {
                inline else => |op| switch (impl) {
                    .builtin_const => runLoop(
                        op,
                        .builtin_const,
                        len,
                        io,
                        perf,
                        &functions,
                        case,
                        buffers,
                        iters,
                    ),
                    .fastmem_inline => runFastmemInline(
                        op,
                        len,
                        io,
                        perf,
                        &functions,
                        case,
                        buffers,
                        iters,
                    ),
                    else => unreachable,
                },
            };
        }
        unreachable;
    }
    return switch (case.op) {
        inline else => |op| if (impl == .fastmem_inline)
            runFastmemInline(op, null, io, perf, &functions, case, buffers, iters)
        else
            runLoop(op, .indirect, null, io, perf, &functions, case, buffers, iters),
    };
}
fn scaleIterations(iters: u64, ns: u64, target: u64) u64 {
    const scaled = @as(u128, iters) * target / @max(ns, 1);
    return @intCast(@min(max_iters, @max(1, scaled)));
}
test "calibration shrinks oversized pilots, including the cap" {
    try testing.expectEqual(@as(u64, 100), scaleIterations(1000, 200, 20));
    try testing.expectEqual(@as(u64, max_iters / 2), scaleIterations(max_iters, 40, 20));
    try testing.expectEqual(@as(u64, 10000), scaleIterations(1000, 2, 20));
}
fn calibrate(
    io: Io,
    symbols: *const Symbols,
    case: Case,
    buffers: Buffers,
    impl: Impl,
    target: u64,
) u64 {
    var iters: u64 = 64;
    for (0..12) |_| {
        const result = runBatch(io, null, symbols, case, buffers, impl, iters);
        if (result.ns >= target * 3 / 4 and result.ns <= target * 5 / 4) return iters;
        const next = scaleIterations(iters, result.ns, target);
        if (next == iters) return iters;
        iters = next;
    }
    return iters;
}
const Sample = struct { case: Case, impl: Impl, sample: u32, result: Result };
fn measureCase(
    arena: Allocator,
    io: Io,
    cfg: Config,
    symbols: *const Symbols,
    perf: *Perf,
    memory: Memory,
    listed: Case,
    output: *ArrayList(Sample),
) !void {
    var case = listed;
    if (listed.seq) |seq| case.seq = memory.placeSeq(seq);
    const buffers = memory.buffers(case);
    var impls: ArrayList(Impl) = .empty;
    for (cfg.impls) |impl| if (case.accepts(impl)) try impls.append(arena, impl);
    var iterations = [_]u64{0} ** 5;
    const target = @as(u64, cfg.sample_ms) * time.ns_per_ms;
    for (impls.items, 0..) |impl, index| {
        if (cfg.warmup_ms != 0) {
            const start = Io.Timestamp.now(io, .awake);
            const warmup_ns = @as(u64, cfg.warmup_ms) * time.ns_per_ms;
            while (start.durationTo(.now(io, .awake)).nanoseconds < warmup_ns)
                _ = runBatch(io, null, symbols, case, buffers, impl, 64);
        }
        iterations[index] = calibrate(io, symbols, case, buffers, impl, target);
    }
    for (0..cfg.samples) |sample| {
        for (0..impls.items.len) |position| {
            const index = (position + sample) % impls.items.len;
            const impl = impls.items[index];
            const result = runBatch(io, perf, symbols, case, buffers, impl, iterations[index]);
            try output.append(arena, .{
                .case = case,
                .impl = impl,
                .sample = @intCast(sample),
                .result = result,
            });
            iterations[index] = scaleIterations(result.iters, result.ns, target);
        }
    }
}
fn balancedSamples(cfg: Config, cases: []const Case) u32 {
    var samples: u32 = 1;
    for (cases) |case| {
        var count: u32 = 0;
        for (cfg.impls) |impl| if (case.accepts(impl)) {
            count += 1;
        };
        if (count != 0) samples = samples / math.gcd(samples, count) * count;
    }
    return samples;
}
test "default samples balance every applicable implementation count" {
    const cases = [_]Case{
        .{ .id = "copy/aligned/8", .op = .copy, .profile = "aligned", .size = 8, .max_len = 8 },
        .{ .id = "set/aligned/8", .op = .set, .profile = "aligned", .size = 8, .max_len = 8 },
    };
    try testing.expectEqual(@as(u32, 4), balancedSamples(.{}, &cases));
    const cfg: Config = .{ .impls = &.{ .builtin, .glibc, .fastmem_abi } };
    try testing.expectEqual(@as(u32, if (has_fastmem_set) 3 else 6), balancedSamples(cfg, &cases));
}

fn jsonLine(w: *Io.Writer, value: anytype) !void {
    try json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
}
const Codegen = struct {
    binary_sha256: []const u8,
    checked_roots: []const []const u8,
    delegations: []const struct { caller: []const u8, symbol: []const u8, address: []const u8 },

    fn read(arena: Allocator, io: Io, path: []const u8) !Codegen {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const parsed = try json.parseFromSlice(Codegen, arena, bytes, .{});
        const executable = try Io.Dir.cwd().readFileAlloc(
            io,
            "/proc/self/exe",
            arena,
            .limited(128 << 20),
        );
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(executable, &digest, .{});
        const hex = fmt.bytesToHex(digest, .lower);
        if (!mem.eql(u8, &hex, parsed.value.binary_sha256))
            return error.CodegenEvidenceDoesNotMatchExecutable;
        return parsed.value;
    }
};

const DispatchMeta = struct {
    level: []const u8,
    kernel: []const u8,
    vendor: []const u8,
    family: u32,
    model: u32,
};

/// The runtime-dispatch level of a baseline x86_64 build
/// (docs/slop/runtime-dispatch.md). The timed calls resolved it before the meta
/// record.
fn dispatchMeta() DispatchMeta {
    const info = fastmem.dispatch.detect().?;
    return .{
        .level = @tagName(fastmem.dispatch.level().?),
        .kernel = fastmem.dispatch.kernelName().?,
        .vendor = @tagName(info.vendor),
        .family = info.family,
        .model = info.model,
    };
}

/// A meta record with the dispatch object after its last field. Only a
/// dispatch build emits it. A comptime-selected build emits the record
/// without the field, with the same code as before P7, so that the code
/// layout of its kernels does not move.
fn WithDispatch(comptime Base: type) type {
    return struct {
        base: Base,
        dispatch: DispatchMeta,

        const Self = @This();

        pub fn jsonStringify(self: Self, jw: *json.Stringify) json.Stringify.Error!void {
            try jw.beginObject();
            inline for (@typeInfo(Base).@"struct".fields) |field| {
                try jw.objectField(field.name);
                try jw.write(@field(self.base, field.name));
            }
            try jw.objectField("dispatch");
            try jw.write(self.dispatch);
            try jw.endObject();
        }
    };
}

test "the dispatch meta object follows the last field of the record" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const record = .{ .type = "meta", .schema = @as(u32, 3), .codegen = @as(?u8, null) };
    try jsonLine(&w, WithDispatch(@TypeOf(record)){ .base = record, .dispatch = .{
        .level = "znver5",
        .kernel = "x86-avx512-compact-v3",
        .vendor = "amd",
        .family = 26,
        .model = 2,
    } });
    const want = "{\"type\":\"meta\",\"schema\":3,\"codegen\":null,\"dispatch\":" ++
        "{\"level\":\"znver5\",\"kernel\":\"x86-avx512-compact-v3\"," ++
        "\"vendor\":\"amd\",\"family\":26,\"model\":2}}\n";
    try testing.expectEqualStrings(want, w.buffered());
}

fn emitMeta(
    w: *Io.Writer,
    cfg: Config,
    symbols: Symbols,
    perf: Perf,
    codegen: ?Codegen,
    memory: ?MemoryMeta,
) !void {
    var perf_error: [512]u8 = undefined;
    const record = .{
        .type = "meta",
        .schema = schema,
        .rev = std.mem.sliceTo(&options.rev_padded, 0),
        .zig = builtin.zig_version_string,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++
            @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi),
        .cpu = builtin.cpu.model.name,
        .optimize = @tagName(builtin.mode),
        .link_libc = true,
        .chunk_bytes = chunk_bytes,
        .suite = cfg.suite,
        .seed = cfg.seed,
        .samples = cfg.samples,
        .sample_ms = cfg.sample_ms,
        .warmup_ms = cfg.warmup_ms,
        .impls = cfg.impls,
        .dist_file = cfg.dist_file,
        .set_value = set_value,
        .fastmem_set = has_fastmem_set,
        .codegen = codegen,
        .memory = memory,
        .libc_path = symbols.libc_path,
        .libc_base = symbols.libc_base,
        .resolution = .{
            .memcpy = symbols.resolution[0],
            .memmove = symbols.resolution[1],
            .memset = symbols.resolution[2],
        },
        .perf = .{
            .available = perf.failure == null,
            .events = perf.eventNames(),
            .@"error" = perf.errorMessage(&perf_error),
        },
    };
    if (comptime fastmem.dispatch.enabled) {
        const Record = WithDispatch(@TypeOf(record));
        try jsonLine(w, Record{ .base = record, .dispatch = dispatchMeta() });
    } else try jsonLine(w, record);
}
fn emitSample(w: *Io.Writer, sample: Sample) !void {
    const case = sample.case;
    const result = sample.result;
    const counters = result.counters;
    try jsonLine(w, .{
        .type = "sample",
        .case = case.id,
        .op = case.op,
        .profile = case.profile,
        .size = case.size,
        .src_off = if (case.seq == null) @as(?u32, case.src_off) else null,
        .dst_off = if (case.seq == null) @as(?u32, case.dst_off) else null,
        .gap = case.gap,
        .impl = sample.impl,
        .sample = sample.sample,
        .iters = result.iters,
        .ns = result.ns,
        .cycles = if (counters) |v| @as(?u64, v.cycles) else null,
        .instructions = if (counters) |v| @as(?u64, v.instructions) else null,
        .ref_cycles = if (counters) |v| v.ref_cycles else null,
        .time_enabled = if (counters) |v| @as(?u64, v.time_enabled) else null,
        .time_running = if (counters) |v| @as(?u64, v.time_running) else null,
    });
}
fn run(init: process.Init) !void {
    const arena = init.arena.allocator();
    var cfg = try parseArgs(arena, try init.minimal.args.toSlice(arena));
    var symbols = try Symbols.init();
    defer symbols.deinit();
    const codegen = if (cfg.codegen_file) |path| try Codegen.read(arena, init.io, path) else null;
    var perf: Perf = .init();
    defer perf.close();
    const cases = try buildCases(arena, init.io, cfg);
    var active: ArrayList(Impl) = .empty;
    for (cfg.impls) |impl| {
        for (cases) |case| {
            if (case.accepts(impl)) {
                try active.append(arena, impl);
                break;
            }
        }
    }
    cfg.impls = active.items;
    if (cfg.samples == 0) cfg.samples = balancedSamples(cfg, cases);
    var output: ArrayList(Sample) = .empty;
    var memory: ?Memory = if (cfg.list) null else try .init(arena, init.io, cases);
    defer if (memory) |*value| value.deinit();
    const start = Io.Timestamp.now(init.io, .awake);
    if (memory) |*value| {
        for (cases) |case| {
            print("bench-fastmem: {s}\n", .{case.id});
            try measureCase(arena, init.io, cfg, &symbols, &perf, value.*, case, &output);
        }
        // A later collapse by khugepaged changes placement during the run. The meta
        // record shows it as a difference between the start and end counts.
        value.huge_end = value.hugeBytes(arena, init.io);
    }
    const elapsed: u64 = @intCast(start.durationTo(.now(init.io, .awake)).nanoseconds);
    // Delay stdout so the meta record includes errors from any perf ioctl or read.
    var buffer: [8192]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &writer.interface;
    try emitMeta(w, cfg, symbols, perf, codegen, if (memory) |value| value.meta() else null);
    if (cfg.list) {
        for (cases) |case| try jsonLine(w, .{
            .type = "case",
            .case = case.id,
            .op = case.op,
            .profile = case.profile,
            .size = case.size,
        });
    } else for (output.items) |sample| try emitSample(w, sample);
    try jsonLine(w, .{ .type = "end", .cases = cases.len, .elapsed_ns = elapsed });
    try w.flush();
    var perf_error: [512]u8 = undefined;
    if (perf.errorMessage(&perf_error)) |message|
        print("bench-fastmem: perf: {s}\n", .{message});
}
pub fn main(init: process.Init) void {
    run(init) catch |err| {
        print("bench-fastmem: {s}. No complete measurement was produced.\n", .{
            @errorName(err),
        });
        process.exit(1);
    };
}
