//! Fast memory operations using native SIMD vectors.
//!
//! `memcpy` and `memmove` now live in separate modules so their policy
//! decisions can diverge cleanly, while still sharing the low-level
//! load/store primitives and the overlap-safe forward kernel.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const builtin = @import("builtin");

const options = @import("fastmem_options");

const aarch64_memcpy_advsimd = @import("aarch64/memcpy_advsimd.zig");
const aarch64_memcpy_sve = @import("aarch64/memcpy_sve.zig");
const aarch64_memset_advsimd = @import("aarch64/memset_advsimd.zig");
const aarch64_memset_sve = @import("aarch64/memset_sve.zig");
const aarch64_small = @import("aarch64/small.zig");
const arm_tuning = @import("aarch64/tuning.zig");
const common = @import("common.zig");
const chunk_bytes = common.chunk_bytes;
const stride = common.stride;
const generic = @import("generic.zig");
const memcpy_impl = @import("memcpy.zig");
const memmove_impl = @import("memmove.zig");
const x86_dispatch = @import("x86_64/dispatch.zig");
const on_dispatch = x86_dispatch.enabled;
const x86_move = @import("x86_64/move.zig");
const x86_set = @import("x86_64/set.zig");
const x86_tuning = @import("x86_64/tuning.zig");
const on_x86 = x86_tuning.available;

// The generic Zig fallback for targets without a dedicated kernel.
// aarch64 kernels: ports of Arm Optimized Routines (see THIRD_PARTY.md).
// The SVE pair is the G2 C-ABI baseline; the advsimd pair is the G6
// generic-aarch64 path. The gates are complementary, so exactly one pair
// emits its kernel definitions per build.
// Loop-free small-size classes inlined at the call site (no call at
// all at <= 64 bytes; the C-ABI kernels handle the rest).
// The kernel ports retain the ELF-only support boundary.
// Non-ELF aarch64 targets, such as macOS, keep the generic Zig kernels.
const on_aarch64 = builtin.cpu.arch == .aarch64 and builtin.target.ofmt == .elf;
// x86_64 Linux builds without AVX2 select the x86 kernels at run time
// (docs/slop/runtime-dispatch.md). AVX2 builds keep the comptime selection.
const on_aarch64_sve = on_aarch64 and builtin.cpu.has(.aarch64, .sve);

// "+midpair-v2" marks the copy/move mid-block rework: armg's pair
// shape at 33..64 and V3 fall-through head
// (docs/slop/results/armg-mid-paths.md), plus the armh 65..128 tail split at
// 96 and the V3 copy head's mid96 dispatch
// (docs/slop/results/armh-graviton-gaps.md). V1 emits no neon mid block, so
// its bytes are unchanged by v2. The set bytes are unchanged on SVE
// builds, so set keeps the plain name. The V1 hybrid move head checks
// 128 itself ("+mid128-v1"). The generic set tail follows memset-sve.S
// and its small tree is inverted ("+set-tail-sve-v1").
fn armName(comptime small: []const u8) []const u8 {
    return "aor-sve-5e20a93+small-" ++ small;
}

const copy_impl_name: []const u8 = if (on_aarch64_sve)
    armName(@tagName(arm_tuning.copy_small)) ++ "+midpair-v2"
else if (on_aarch64)
    "aor-advsimd-5e20a93"
else if (on_x86)
    x86_tuning.name
else if (on_dispatch)
    "x86-dispatch" ++ x86_tuning.experiment_suffix
else
    "zig-simd";

const move_impl_name: []const u8 = if (on_aarch64_sve)
    if (arm_tuning.move_small == .neon)
        // The move mid block is the chunk shape on V3, pair elsewhere.
        "aor-sve-5e20a93+small-neon-exact16-v1" ++
            (if (arm_tuning.move_mid == .chunk) "+midchunk-v2" else "+midpair-v2")
    else if (arm_tuning.move_small == .hybrid)
        "aor-sve-5e20a93+small-hybrid+mid128-v1"
    else if (arm_tuning.move_small == .hybrid_n32)
        "aor-sve-5e20a93+small-hybrid-n32+mid128-v1"
    else if (arm_tuning.move_small == .hybrid_ft)
        "aor-sve-5e20a93+small-hybrid-ft+mid128-v1"
    else
        armName(@tagName(arm_tuning.move_small)) ++ "+midpair-v2"
else if (on_x86)
    x86_tuning.move_name
else if (on_dispatch)
    "x86-dispatch+move-pairs-v1" ++ x86_tuning.experiment_suffix
else
    copy_impl_name;

const set_impl_name: []const u8 = if (on_aarch64_sve)
    armName(@tagName(arm_tuning.set_small))
else if (on_x86)
    x86_tuning.set_name
else if (on_aarch64)
    "aor-advsimd-5e20a93+set-tail-sve-v1"
else if (on_dispatch)
    copy_impl_name
else
    "zig-vector";

/// Names of the kernel implementations in this build, one per operation.
/// Dispatch names identify the stub family and any selected experiment.
/// `dispatch.kernelName` identifies the selected level and its move policy.
pub const impl = .{
    .copy = copy_impl_name,
    .move = move_impl_name,
    .set = set_impl_name,
};

/// Runtime CPU dispatch. It is active in x86_64
/// Linux builds whose target CPU lacks AVX2, when build.zig links the level
/// objects. `enabled` is false in every other build, and the functions then
/// return null or error.Unsupported.
pub const dispatch = struct {
    pub const enabled = on_dispatch;
    /// Sizes up to this bound never consult the dispatcher, on any path.
    pub const small_max = x86_dispatch.small_max;
    pub const Level = x86_dispatch.Level;
    pub const Info = x86_dispatch.Info;

    /// The level of the kernels. The first use selects it from CPUID.
    pub fn level() ?Level {
        return if (comptime enabled) x86_dispatch.level() else null;
    }

    /// The kernel implementation name of the level, as `impl` names it in
    /// a comptime build for that CPU.
    pub fn kernelName() ?[:0]const u8 {
        return if (comptime enabled) x86_dispatch.kernelName() else null;
    }

    /// The CPUID and XCR0 facts that the selection reads.
    pub fn detect() ?Info {
        return if (comptime enabled) x86_dispatch.detect() else null;
    }

    /// Use `l` instead of the detected level: a test hook. The CPU must
    /// support the level. It compiles only in fastmem's own test modules:
    /// the public module never sets the `x86_test_hooks` option.
    pub fn force(l: Level) error{Unsupported}!void {
        if (comptime !test_hooks) @compileError(
            "fastmem.dispatch.force is a test hook; the public fastmem module does not provide it",
        );
        if (comptime !enabled) return error.Unsupported;
        return x86_dispatch.force(l);
    }

    const test_hooks = @hasDecl(options, "x86_test_hooks") and options.x86_test_hooks;
};

/// Sizes up to this bound stay inline in a dispatch build. The classes are
/// the x86 inline ladder (x86_64/move.zig and set.zig `small`), compiled for
/// the target CPU: SSE2 on baseline. 128 is the inline limit of the
/// x86_64_v3 comptime build. Larger sizes call the dispatched kernel.
// The ABI threshold experiment does not change fixed-size inlining.
const dispatch_inline_max = 128;
comptime {
    if (on_dispatch and dispatch_inline_max < x86_dispatch.small_max)
        @compileError("the inline dispatch limit must cover the ABI small limit");
}

test {
    _ = @import("tests/fuzz.zig");
    _ = @import("x86_64/cpuid.zig");
    if (on_x86) _ = @import("x86_64/tests.zig");
    if (on_dispatch) _ = @import("x86_64/dispatch_tests.zig");
}

pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    if (comptime on_aarch64) {
        assert(dest.len >= source.len);
        const bytes = source.len * @sizeOf(T);
        const d: [*]u8 = @ptrCast(dest.ptr);
        const s: [*]const u8 = @ptrCast(source.ptr);
        // Same non-overlap contract as memcpy_impl.copy.
        const d_addr = @intFromPtr(d);
        const s_addr = @intFromPtr(s);
        assert(s_addr <= math.maxInt(usize) - bytes);
        assert(d_addr <= s_addr or d_addr >= s_addr + bytes);
        if (bytes > aarch64_small.max_inline) {
            @branchHint(.unlikely);
            if (comptime on_aarch64_sve) {
                if (comptime arm_tuning.mid_entry and aarch64_memcpy_sve.has_gt64_entry) {
                    aarch64_memcpy_sve.fastmem_sve_copy_gt64(d, s, bytes);
                } else {
                    aarch64_memcpy_sve.fastmem_sve_copy(d, s, bytes);
                }
            } else {
                aarch64_memcpy_advsimd.fastmem_advsimd_copy(d, s, bytes);
            }
            return;
        }
        aarch64_small.copyMove(d, s, bytes);
        return;
    }
    if (comptime on_x86) {
        assert(dest.len >= source.len);
        const bytes = source.len * @sizeOf(T);
        const d_addr = @intFromPtr(dest.ptr);
        const s_addr = @intFromPtr(source.ptr);
        assert(s_addr <= math.maxInt(usize) - bytes);
        assert(d_addr <= s_addr or d_addr >= s_addr + bytes);
        x86_move.move(.disjoint, @ptrCast(dest.ptr), @ptrCast(source.ptr), bytes);
        return;
    }
    if (comptime on_dispatch) {
        assert(dest.len >= source.len);
        const bytes = source.len * @sizeOf(T);
        const d_addr = @intFromPtr(dest.ptr);
        const s_addr = @intFromPtr(source.ptr);
        assert(s_addr <= math.maxInt(usize) - bytes);
        assert(d_addr <= s_addr or d_addr >= s_addr + bytes);
        const d: [*]u8 = @ptrCast(dest.ptr);
        const s: [*]const u8 = @ptrCast(source.ptr);
        if (x86_move.small(dispatch_inline_max, d, s, bytes)) return;
        _ = x86_dispatch.copyPointer()(d, s, bytes);
        return;
    }
    memcpy_impl.copy(T, dest, source);
}

pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (comptime on_aarch64) {
        assert(dest.len >= source.len);
        const bytes = source.len * @sizeOf(T);
        const d: [*]u8 = @ptrCast(dest.ptr);
        const s: [*]const u8 = @ptrCast(source.ptr);
        if (bytes > aarch64_small.max_inline) {
            @branchHint(.unlikely);
            if (comptime on_aarch64_sve) {
                if (comptime arm_tuning.mid_entry and aarch64_memcpy_sve.has_gt64_entry) {
                    aarch64_memcpy_sve.fastmem_sve_copy_gt64(d, s, bytes);
                } else {
                    aarch64_memcpy_sve.fastmem_sve_move(d, s, bytes);
                }
            } else {
                aarch64_memcpy_advsimd.fastmem_advsimd_move(d, s, bytes);
            }
            return;
        }
        // The small classes are overlap-safe (all loads precede all
        // stores), so copy and move share them.
        aarch64_small.copyMove(d, s, bytes);
        return;
    }
    if (comptime on_x86) {
        assert(dest.len >= source.len);
        x86_move.move(
            .may_overlap,
            @ptrCast(dest.ptr),
            @ptrCast(source.ptr),
            source.len * @sizeOf(T),
        );
        return;
    }
    if (comptime on_dispatch) {
        assert(dest.len >= source.len);
        const bytes = source.len * @sizeOf(T);
        const d: [*]u8 = @ptrCast(dest.ptr);
        const s: [*]const u8 = @ptrCast(source.ptr);
        // The small classes load everything before they store.
        if (x86_move.moveSmall(dispatch_inline_max, d, s, bytes)) return;
        _ = x86_dispatch.movePointer()(d, s, bytes);
        return;
    }
    memmove_impl.move(T, dest, source);
}

/// Fill `dest` with `value`. Prefer over @memset for runtime-sized fills.
///
/// The byte kernels are bit-pattern fills: they apply to T == u8, or to
/// any T with a unique in-memory representation whose value bytes are
/// all equal (checked at runtime; comptime-known for u8). Every other
/// type takes the element-wise fallback loop.
pub inline fn set(comptime T: type, dest: []T, value: T) void {
    if (comptime @sizeOf(T) == 0) return;
    if (comptime on_aarch64 and (T == u8 or std.meta.hasUniqueRepresentation(T))) {
        const bytes = mem.asBytes(&value);
        if (T == u8 or allBytesEqual(bytes)) {
            const len = dest.len * @sizeOf(T);
            const d: [*]u8 = @ptrCast(dest.ptr);
            if (len > aarch64_small.max_inline) {
                @branchHint(.unlikely);
                if (comptime on_aarch64_sve) {
                    aarch64_memset_sve.fastmem_sve_set(d, bytes[0], len);
                } else {
                    aarch64_memset_advsimd.fastmem_advsimd_set(d, bytes[0], len);
                }
                return;
            }
            aarch64_small.set(d, bytes[0], len);
            return;
        }
    }
    if (comptime on_x86 and (T == u8 or std.meta.hasUniqueRepresentation(T))) {
        const bytes = mem.asBytes(&value);
        if (T == u8 or allBytesEqual(bytes)) {
            x86_set.set(@ptrCast(dest.ptr), bytes[0], dest.len * @sizeOf(T));
            return;
        }
    }
    if (comptime on_dispatch and (T == u8 or std.meta.hasUniqueRepresentation(T))) {
        const bytes = mem.asBytes(&value);
        if (T == u8 or allBytesEqual(bytes)) {
            const len = dest.len * @sizeOf(T);
            const d: [*]u8 = @ptrCast(dest.ptr);
            if (x86_set.small(dispatch_inline_max, false, d, bytes[0], len)) return;
            _ = x86_dispatch.setPointer()(d, bytes[0], len);
            return;
        }
    }
    generic.setFallback(T, dest, value);
}

fn allBytesEqual(bytes: []const u8) bool {
    for (bytes[1..]) |b| if (b != bytes[0]) return false;
    return true;
}

const LibcCopyFn = *const fn (
    dest: ?*anyopaque,
    src: ?*const anyopaque,
    n: usize,
) callconv(.c) ?*anyopaque;
const LibcSetFn = *const fn (dest: ?*anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque;

// The AOR kernel symbols already carry the libc signatures and, like
// the libc originals, return dest in x0 (the kernels never write x0).
// The abi entries below are therefore the kernel symbol addresses
// themselves: a call through them lands directly in the kernel, exactly
// like the harness's dlsym pointer into glibc. A Zig wrapper compiles
// to a `b` trampoline, and that extra taken branch is measurable at
// small sizes (fleet run 20260924T064442Z-aor-g2: set 0-16 was
// 1.28-1.33x glibc on c7g/c8g with an instruction-identical body).
const libc_copy_fn: LibcCopyFn = if (on_aarch64_sve)
    @ptrCast(&aarch64_memcpy_sve.copyEntry)
else if (on_aarch64)
    @ptrCast(&aarch64_memcpy_advsimd.copyEntry)
else
    undefined;

const libc_move_fn: LibcCopyFn = if (on_aarch64_sve)
    @ptrCast(&aarch64_memcpy_sve.move_entry)
else if (on_aarch64)
    @ptrCast(&aarch64_memcpy_advsimd.copyEntry)
else
    undefined;

const libc_set_fn: LibcSetFn = if (on_aarch64_sve)
    @ptrCast(&aarch64_memset_sve.setEntry)
else if (on_aarch64)
    @ptrCast(&aarch64_memset_advsimd.setEntry)
else
    undefined;

/// Export strong, hidden `memcpy`, `memmove`, and `memset` for this link unit.
/// Call it from the program that owns the final link, never from a library
/// that another program imports: the definitions would join every consumer's
/// link and collide with the consumer's own symbols.
pub fn exportSymbols() void {
    if (builtin.target.ofmt != .elf or
        (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64))
        @compileError("fastmem.exportSymbols requires aarch64 or x86_64 ELF");
    if (builtin.zig_backend != .stage2_llvm)
        @compileError("fastmem.exportSymbols requires the LLVM backend (use -fllvm in Debug)");

    @export(abi.memcpy, .{ .name = "memcpy", .linkage = .strong, .visibility = .hidden });
    @export(abi.memmove, .{ .name = "memmove", .linkage = .strong, .visibility = .hidden });
    @export(abi.memset, .{ .name = "memset", .linkage = .strong, .visibility = .hidden });
}

/// C-ABI entry points with the libc signatures, each returning dest.
/// The entries receive libc names only after exportSymbols. The benchmark
/// measures these as fastmem_abi. Dedicated kernels handle aarch64 and AVX2.
/// x86_64 Linux builds without AVX2 get the runtime-dispatch entries: 0 to
/// 128 bytes inline, larger sizes through the dispatcher. Other targets use
/// generic Zig wrappers.
pub const abi = struct {
    comptime {
        // A consumer can use only ABI pointers, without copy/move/set.
        // Analyze the kernel containers even in that case.
        if (on_aarch64_sve) {
            _ = aarch64_memcpy_sve;
            _ = aarch64_memset_sve;
        } else if (on_aarch64) {
            _ = aarch64_memcpy_advsimd;
            _ = aarch64_memset_advsimd;
        }
    }

    pub const memcpy: LibcCopyFn = if (on_x86)
        &x86_move.kernel
    else if (on_dispatch)
        &x86_dispatch.memcpy
    else if (on_aarch64)
        libc_copy_fn
    else
        &generic.memcpy;
    pub const memmove: LibcCopyFn = if (on_x86)
        &x86_move.moveKernel
    else if (on_dispatch)
        &x86_dispatch.memmove
    else if (on_aarch64)
        libc_move_fn
    else
        &generic.memmove;
    pub const memset: LibcSetFn = if (on_x86)
        &x86_set.kernel
    else if (on_dispatch)
        &x86_dispatch.memset
    else if (on_aarch64)
        libc_set_fn
    else
        &generic.memset;
};

test "implementation names distinguish the move-only small classes" {
    if (on_x86 and x86_tuning.entry_pairs and x86_tuning.high_regs and
        builtin.zig_backend == .stage2_llvm)
    {
        try testing.expectEqualStrings(impl.copy, impl.move);
    } else if (on_x86 or on_dispatch or (on_aarch64_sve and arm_tuning.move_small == .neon)) {
        try testing.expect(!mem.eql(u8, impl.copy, impl.move));
    }
    if (on_x86) try testing.expectEqualStrings(x86_tuning.move_name, impl.move);
    if (on_aarch64_sve and arm_tuning.move_small == .neon) {
        const want = "aor-sve-5e20a93+small-neon-exact16-v1" ++
            (if (arm_tuning.move_mid == .chunk) "+midchunk-v2" else "+midpair-v2");
        try testing.expectEqualStrings(want, impl.move);
    }
    if (on_aarch64_sve and arm_tuning.move_small == .hybrid) {
        try testing.expectEqualStrings("aor-sve-5e20a93+small-hybrid+mid128-v1", impl.move);
    }
}

test "copy: all size classes" {
    const sizes = [_]usize{
        0,  1,  2,   3,   4,   5,   7,   8,
        12, 15, 16,  24,  31,  32,  48,  63,
        64, 96, 127, 128, 200, 256, 512, 1024,
    };
    for (sizes) |len| {
        var src: [1024]u8 = undefined;
        for (&src, 0..) |*b, i| b.* = @truncate(i);

        var dest: [1024]u8 = .{0} ** 1024;
        copy(u8, dest[0..len], src[0..len]);

        try testing.expectEqualSlices(u8, src[0..len], dest[0..len]);
    }
}

test "copy: typed elements" {
    const sizes = [_]usize{ 0, 1, 2, 3, 5, 8, 13, 21, 34, 55 };
    for (sizes) |len| {
        var src: [64]u32 = undefined;
        for (&src, 0..) |*value, i| value.* = @intCast(i * 17 + 3);

        var dest: [64]u32 = .{0} ** 64;
        copy(u32, dest[0..len], src[0..len]);

        try testing.expectEqualSlices(u32, src[0..len], dest[0..len]);
    }
}

test "copy: alignment and length matrix" {
    const max_len = 320;
    const max_offset = chunk_bytes;
    var source_buf: [max_len + chunk_bytes]u8 align(chunk_bytes) = undefined;
    for (&source_buf, 0..) |*b, i| b.* = @truncate(i * 13 + 5);

    var dest_buf: [max_len + chunk_bytes]u8 align(chunk_bytes) = undefined;
    for (0..max_len + 1) |len| {
        for (0..max_offset) |source_offset| {
            const source = source_buf[source_offset..][0..len];

            for (0..max_offset) |dest_offset| {
                @memset(&dest_buf, 0xA5);
                const dest = dest_buf[dest_offset..][0..len];

                copy(u8, dest, source);
                try testing.expectEqualSlices(u8, source, dest);
            }
        }
    }
}

test "move: forward overlapping (dest < src)" {
    // Simulate buffer compaction: shift data left by various gaps.
    const gaps = [_]usize{ 1, 2, 7, 15, 16, 31, 32, 63, 64, 100 };
    for (gaps) |gap| {
        var buf: [512]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);

        const len: usize = 400;
        var expected: [512]u8 = undefined;
        @memcpy(expected[0..len], buf[gap..][0..len]);

        move(u8, buf[0..len], buf[gap..][0..len]);
        try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
    }
}

test "move: typed elements in both overlap directions" {
    const gaps = [_]usize{ 1, 2, 5, 9, 17 };
    const len: usize = 120;

    for (gaps) |gap| {
        var forward_buf: [256]u16 = undefined;
        for (&forward_buf, 0..) |*value, i| value.* = @intCast(i * 31 + gap);
        var forward_expected = forward_buf;

        @memmove(forward_expected[0..len], forward_expected[gap..][0..len]);
        move(u16, forward_buf[0..len], forward_buf[gap..][0..len]);
        try testing.expectEqualSlices(u16, forward_expected[0..len], forward_buf[0..len]);

        var backward_buf: [256]u16 = undefined;
        for (&backward_buf, 0..) |*value, i| value.* = @intCast(i * 31 + gap);
        var backward_expected = backward_buf;

        @memmove(backward_expected[gap..][0..len], backward_expected[0..len]);
        move(u16, backward_buf[gap..][0..len], backward_buf[0..len]);
        try testing.expectEqualSlices(
            u16,
            backward_expected[gap..][0..len],
            backward_buf[gap..][0..len],
        );
    }
}

test "move: overlap matrix around stride" {
    const max_len = stride + chunk_bytes;
    const max_gap = chunk_bytes * 2;
    const buf_len = max_len + max_gap;

    var base: [buf_len]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @truncate(i * 29 + 11);

    for (0..max_len + 1) |len| {
        for (0..max_gap + 1) |gap| {
            if (len + gap > buf_len) continue;

            var forward_buf = base;
            var forward_expected = base;
            @memmove(forward_expected[0..len], forward_expected[gap..][0..len]);
            move(u8, forward_buf[0..len], forward_buf[gap..][0..len]);
            try testing.expectEqualSlices(u8, forward_expected[0..len], forward_buf[0..len]);

            var backward_buf = base;
            var backward_expected = base;
            @memmove(backward_expected[gap..][0..len], backward_expected[0..len]);
            move(u8, backward_buf[gap..][0..len], backward_buf[0..len]);
            try testing.expectEqualSlices(
                u8,
                backward_expected[gap..][0..len],
                backward_buf[gap..][0..len],
            );
        }
    }
}

test "move: backward overlapping (dest > src)" {
    const gaps = [_]usize{ 1, 2, 7, 15, 16, 31, 32, 63, 64, 100 };
    for (gaps) |gap| {
        var buf: [512]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);

        const len: usize = 300;
        var expected: [512]u8 = undefined;
        @memcpy(expected[gap..][0..len], buf[0..len]);

        move(u8, buf[gap..][0..len], buf[0..len]);
        try testing.expectEqualSlices(
            u8,
            expected[gap..][0..len],
            buf[gap..][0..len],
        );
    }
}

// Covers every type shape set() must accept: scalars with uniform and
// non-uniform byte patterns, aggregates, optionals, and zero-size types.
// want[] is built with a plain element loop; both buffers start from
// zeroes so writes outside the requested range show up in the compare.
test "abi: libc-signature entry points return dest and do the work" {
    var src: [600]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    for ([_]usize{ 0, 1, 7, 32, 65, 128, 200, 511 }) |len| {
        var dest: [600]u8 = .{0} ** 600;
        const r = abi.memcpy(@ptrCast(&dest), @ptrCast(&src), len);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&dest)), r);
        try testing.expectEqualSlices(u8, src[0..len], dest[0..len]);

        @memset(&dest, 0);
        const r3 = abi.memset(@ptrCast(&dest), 0xAB, len);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&dest)), r3);
        var want: [600]u8 = @splat(0xAB);
        try testing.expectEqualSlices(u8, want[0..len], dest[0..len]);
        if (len < 600) try testing.expectEqual(@as(u8, 0), dest[len]);
    }

    // memmove both overlap directions, and the dest return value.
    for ([_]usize{ 1, 31, 100 }) |gap| {
        var fwd = src;
        const r1 = abi.memmove(@ptrCast(&fwd), @ptrCast(&fwd[gap]), 400);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&fwd)), r1);
        try testing.expectEqualSlices(u8, src[gap..][0..400], fwd[0..400]);

        var bwd = src;
        const r2 = abi.memmove(@ptrCast(&bwd[gap]), @ptrCast(&bwd), 400);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&bwd[gap])), r2);
        try testing.expectEqualSlices(u8, src[0..400], bwd[gap..][0..400]);
    }
}

const SetTestEnum = enum(u8) { a, b, c };
const SetTestStruct = struct { a: u8, b: u32 }; // padding, no unique repr

test "set: typed elements, uniform and non-uniform byte patterns" {
    try expectSet(u8, 0x00);
    try expectSet(u8, 0x5A);
    try expectSet(u16, 0xAAAA);
    try expectSet(u16, 0x1234);
    try expectSet(u32, 0xABABABAB);
    try expectSet(u32, 0x01020304);
    try expectSet(u64, 0);
    try expectSet(u64, 0x0102030405060708);
    try expectSet(f32, 0.0);
    try expectSet(f32, 1.5);
    try expectSet(i8, -1);
    try expectSet(i8, 42);
    try expectSet([4]u8, .{ 9, 9, 9, 9 });
    try expectSet([4]u8, .{ 1, 2, 3, 4 });
    try expectSet(@Vector(4, u8), @as(@Vector(4, u8), @splat(0x55)));
    try expectSet(@Vector(4, u8), .{ 5, 6, 7, 8 });
    try expectSet(bool, true);
    try expectSet(bool, false);
    try expectSet(SetTestEnum, .b);
    try expectSet(?u8, 7);
    try expectSet(?u8, null);
    try expectSet(SetTestStruct, .{ .a = 3, .b = 0x11223344 });
    try expectSet(u0, 0);
}

fn expectSet(comptime T: type, value: T) !void {
    const lens = [_]usize{ 0, 1, 2, 3, 7, 15, 16, 31, 64, 65, 255, 300 };
    for (lens) |len| {
        var got: [320]T = mem.zeroes([320]T);
        var want: [320]T = mem.zeroes([320]T);
        for (want[2 .. 2 + len]) |*p| p.* = value;
        set(T, got[2 .. 2 + len], value);
        try testing.expectEqual(want, got);
    }
}
// ---------------------------------------------------------------------------
// Extended deterministic tests
// ---------------------------------------------------------------------------

test "copy: large sizes across alignment peel threshold" {
    // Exercises copyLargeForward with multiple loop iterations and the
    // alignment peel path (copy_align_peel_min = stride * 2).
    const large_sizes = [_]usize{
        stride * 2,
        stride * 2 + 1,
        stride * 3,
        stride * 3 - 1,
        1024,
        2048,
        4096,
        8192,
        16384,
    };
    const offsets = [_]usize{ 0, 1, 3, chunk_bytes / 2, chunk_bytes - 1 };

    for (large_sizes) |len| {
        for (offsets) |src_off| {
            for (offsets) |dst_off| {
                var src_buf: [16384 + chunk_bytes]u8 align(64) = undefined;
                for (&src_buf, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);

                var dst_buf: [16384 + chunk_bytes]u8 align(64) = undefined;
                @memset(&dst_buf, 0xCD);

                const src = src_buf[src_off..][0..len];
                const dst = dst_buf[dst_off..][0..len];

                copy(u8, dst, src);
                try testing.expectEqualSlices(u8, src, dst);
            }
        }
    }
}

test "move: large forward across peel threshold" {
    // move_forward_align_peel_min = @max(stride * 2, 2048), so we need
    // sizes around and above 2048 with small gaps.
    const large_sizes = [_]usize{ 1024, 2048, 2049, 3000, 4096, 8192, 16384 };
    const gaps = [_]usize{ 1, 3, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, 63 };

    for (large_sizes) |len| {
        for (gaps) |gap| {
            var buf: [16384 + 64]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i *% 53 +% 7);

            var expected = buf;
            @memmove(expected[0..len], expected[gap..][0..len]);

            move(u8, buf[0..len], buf[gap..][0..len]);
            try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
        }
    }
}

test "move: large backward across peel threshold" {
    const large_sizes = [_]usize{ 1024, 2048, 2049, 3000, 4096, 8192, 16384 };
    const gaps = [_]usize{ 1, 3, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, 63 };

    for (large_sizes) |len| {
        for (gaps) |gap| {
            var buf: [16384 + 64]u8 = undefined;
            for (&buf, 0..) |*b, i| b.* = @truncate(i *% 53 +% 7);

            var expected = buf;
            @memmove(expected[gap..][0..len], expected[0..len]);

            move(u8, buf[gap..][0..len], buf[0..len]);
            try testing.expectEqualSlices(
                u8,
                expected[gap..][0..len],
                buf[gap..][0..len],
            );
        }
    }
}

test "move: non-overlapping regions" {
    // move() with disjoint src/dest should produce the same result as copy().
    const sizes = [_]usize{ 0, 1, 7, 16, 64, 256, 1024, 4096 };
    for (sizes) |len| {
        var src: [4096]u8 = undefined;
        for (&src, 0..) |*b, i| b.* = @truncate(i *% 41);

        var dest: [4096]u8 = .{0xAA} ** 4096;
        move(u8, dest[0..len], src[0..len]);
        try testing.expectEqualSlices(u8, src[0..len], dest[0..len]);
    }
}

test "move: small ABI and inline classes preserve every surrounding byte" {
    var original: [192]u8 = undefined;
    for (&original, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 11);
    for (0..65) |len| {
        for ([_]usize{ 0, 1, 16, 31, 33 }) |gap| {
            for (0..4) |offset| {
                for (0..2) |direction| {
                    const src = 32 + offset + if (direction == 0) gap else 0;
                    const dst = 32 + offset + if (direction == 0) 0 else gap;
                    var expected = original;
                    for (0..len) |i| expected[dst + i] = original[src + i];
                    var actual = original;
                    const returned = abi.memmove(&actual[dst], &actual[src], len);
                    try testing.expectEqual(@as(?*anyopaque, &actual[dst]), returned);
                    try testing.expectEqualSlices(u8, &expected, &actual);
                    actual = original;
                    move(u8, actual[dst..][0..len], actual[src..][0..len]);
                    try testing.expectEqualSlices(u8, &expected, &actual);
                }
            }
        }
    }
    try testing.expectEqual(@as(?*anyopaque, null), abi.memmove(null, null, 0));
}

test "move: identity (dest == src)" {
    const sizes = [_]usize{ 0, 1, 3, 8, 16, 63, 64, 128, 256, 1024, 4096 };
    for (sizes) |len| {
        var buf: [4096]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i *% 71 +% 3);

        const expected = buf;
        move(u8, buf[0..len], buf[0..len]);
        try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
    }
}

test "copy: zero-length for various types" {
    var u8_buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    copy(u8, u8_buf[0..0], u8_buf[4..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &u8_buf);

    var u32_buf = [_]u32{ 10, 20, 30, 40 };
    copy(u32, u32_buf[0..0], u32_buf[2..2]);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40 }, &u32_buf);

    var u64_buf = [_]u64{ 100, 200 };
    copy(u64, u64_buf[0..0], u64_buf[1..1]);
    try testing.expectEqualSlices(u64, &.{ 100, 200 }, &u64_buf);
}

test "move: zero-length for various types" {
    var u8_buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    move(u8, u8_buf[0..0], u8_buf[4..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &u8_buf);

    var u32_buf = [_]u32{ 10, 20, 30, 40 };
    move(u32, u32_buf[0..0], u32_buf[2..2]);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40 }, &u32_buf);
}

test "copy: multi-type elements" {
    // u16
    {
        var src = [_]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1111, 0x2222, 0x3333, 0x4444 };
        var dst: [8]u16 = undefined;
        copy(u16, &dst, &src);
        try testing.expectEqualSlices(u16, &src, &dst);
    }
    // u64
    {
        const len = 128;
        var src: [len]u64 = undefined;
        for (&src, 0..) |*v, i| v.* = @as(u64, i) *% 0xDEADBEEFCAFEBABE +% 1;
        var dst: [len]u64 = undefined;
        copy(u64, &dst, &src);
        try testing.expectEqualSlices(u64, &src, &dst);
    }
    // u128
    {
        const len = 32;
        var src: [len]u128 = undefined;
        for (&src, 0..) |*v, i| v.* = @as(u128, i) *% 0xFEDCBA9876543210FEDCBA9876543210 +% 1;
        var dst: [len]u128 = undefined;
        copy(u128, &dst, &src);
        try testing.expectEqualSlices(u128, &src, &dst);
    }
}

test "move: large overlap matrix" {
    // Extends the existing overlap matrix to cover multiple loop iterations.
    const max_len = stride * 4 + chunk_bytes;
    const max_gap = chunk_bytes * 2;
    const buf_len = max_len + max_gap;

    var base: [buf_len]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @truncate(i *% 29 +% 11);

    // Test a selection of lengths to keep runtime reasonable.
    const test_lens = [_]usize{
        0,              1,          chunk_bytes - 1, chunk_bytes,    chunk_bytes + 1,
        stride - 1,     stride,     stride + 1,      stride * 2 - 1, stride * 2,
        stride * 2 + 1, stride * 3, stride * 4,      max_len,
    };
    const test_gaps = [_]usize{
        0, 1, chunk_bytes - 1, chunk_bytes, chunk_bytes + 1, max_gap,
    };

    for (test_lens) |len| {
        for (test_gaps) |gap| {
            if (len + gap > buf_len) continue;

            // Forward: dest < src.
            {
                var buf = base;
                var expected = base;
                @memmove(expected[0..len], expected[gap..][0..len]);
                move(u8, buf[0..len], buf[gap..][0..len]);
                try testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
            }
            // Backward: dest > src.
            {
                var buf = base;
                var expected = base;
                @memmove(expected[gap..][0..len], expected[0..len]);
                move(u8, buf[gap..][0..len], buf[0..len]);
                try testing.expectEqualSlices(
                    u8,
                    expected[gap..][0..len],
                    buf[gap..][0..len],
                );
            }
        }
    }
}
