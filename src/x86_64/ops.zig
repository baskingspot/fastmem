//! vector pointers preserve ZMM memory operations under Intel prefer_256_bit.
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const builtin = @import("builtin");

const tuning = @import("tuning.zig");
pub const width = tuning.vec;

pub const Vector = @Vector(width, u8);
pub const mask_available = builtin.zig_backend == .stage2_llvm and tuning.avx512;
const Mask = @Vector(64, bool);
extern fn @"llvm.masked.store.v64i8.p0"(
    value: @Vector(64, u8),
    ptr: *anyopaque,
    alignment: u32,
    mask: Mask,
) void;

pub inline fn load(comptime T: type, src: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(src)).*;
}
pub inline fn store(comptime T: type, dst: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(dst)).* = value;
}
pub inline fn storeAligned(dst: [*]u8, value: Vector) void {
    @as(*align(width) Vector, @ptrCast(@alignCast(dst))).* = value;
}
pub inline fn maskedSet(dst: [*]u8, value: u8, n: usize) void {
    if (comptime !mask_available) @compileError("maskedSet requires LLVM and AVX-512BW");
    const bits = (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
    @"llvm.masked.store.v64i8.p0"(@splat(value), dst, 1, @bitCast(bits));
}
pub inline fn streamStore(dst: [*]u8, value: Vector) void {
    if (comptime builtin.zig_backend != .stage2_llvm) {
        storeAligned(dst, value);
        return;
    }
    asm volatile ("vmovntdq %[value], (%[dst])"
        :
        : [value] "v" (value),
          [dst] "r" (dst),
        : .{ .memory = true });
}
// One barrier covers eight transfers, so offsets stay in memory operands.
// Two independent page streams expose more outstanding source cache misses.
pub noinline fn streamCopyPages(dst: [*]u8, src: [*]const u8) void {
    @disableIntrinsics();
    if (comptime !high_available) @compileError("streamCopyPages requires high AVX-512 registers");
    var d = dst;
    var s = src;
    var remaining: u64 = 4096;
    // Keep LLVM from expanding the fixed tile into sixteen assembly blocks.
    asm volatile ("1:\n" ++ streamCopyPagesText() ++
            "add $256, %[dst]\nadd $256, %[src]\nsub $256, %[remaining]\njnz 1b"
        : [dst] "=&r" (d),
          [src] "=&r" (s),
          [remaining] "=&r" (remaining),
        : [dst_in] "0" (d),
          [src_in] "1" (s),
          [remaining_in] "2" (remaining),
        : .{
          .zmm16 = true,
          .zmm17 = true,
          .zmm18 = true,
          .zmm19 = true,
          .zmm20 = true,
          .zmm21 = true,
          .zmm22 = true,
          .zmm23 = true,
          .memory = true,
        });
}

fn streamCopyPagesText() []const u8 {
    comptime var text: []const u8 = "";
    inline for (0..2) |page| {
        inline for (0..4) |line| {
            const ahead = page * 4096 + line * 64 + 512;
            text = text ++ fmt.comptimePrint("prefetcht0 {d}(%[src])\n", .{ahead});
        }
    }
    inline for (.{ "load", "store" }) |phase| {
        inline for (0..8) |i| {
            const offset = (i / 4) * 4096 + (i % 4) * 64;
            text = text ++ if (comptime mem.eql(u8, phase, "load"))
                fmt.comptimePrint("vmovdqu64 {d}(%[src]), %%zmm{d}\n", .{ offset, 16 + i })
            else
                fmt.comptimePrint("vmovntdq %%zmm{d}, {d}(%[dst])\n", .{ 16 + i, offset });
        }
    }
    return text;
}

// Group a full 512-byte fill behind one barrier and one address operand.
pub inline fn streamSetBlock(dst: [*]u8, value: Vector) void {
    comptime var text: []const u8 = "";
    inline for (0..8) |i| {
        text = text ++ fmt.comptimePrint("vmovntdq %[value], {d}(%[dst])\n", .{i * 64});
    }
    asm volatile (text
        :
        : [value] "v" (value),
          [dst] "r" (dst),
        : .{ .memory = true });
}

// Keep the existing four-store temporal body below LLVM's unroll pass.
// The caller supplies an aligned cursor below end and reserves a 256-byte tail.
pub inline fn temporalSetLoop(dst: [*]u8, end: [*]u8, value: Vector) void {
    if (comptime !high_available or width != 64)
        @compileError("temporalSetLoop requires 64-byte AVX-512 vectors");
    var cursor = dst;
    asm volatile (
        \\1:
        \\vmovdqa64 %[value], 0(%[cursor])
        \\vmovdqa64 %[value], 64(%[cursor])
        \\vmovdqa64 %[value], 128(%[cursor])
        \\vmovdqa64 %[value], 192(%[cursor])
        \\add $256, %[cursor]
        \\cmp %[end], %[cursor]
        \\jb 1b
        : [cursor] "=&r" (cursor),
        : [start] "0" (cursor),
          [end] "r" (end),
          [value] "v" (value),
        : .{ .memory = true });
}

pub inline fn fence() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}
pub inline fn repMove(dst: [*]u8, src: [*]const u8, n: usize) void {
    var d = dst;
    var s = src;
    var count = n;
    asm volatile ("rep movsb"
        : [d] "={rdi}" (d),
          [s] "={rsi}" (s),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [s_in] "{rsi}" (s),
          [count_in] "{rcx}" (count),
        : .{ .memory = true });
}
pub inline fn repSet(dst: [*]u8, value: u8, n: usize) void {
    var d = dst;
    var count = n;
    asm volatile ("rep stosb"
        : [d] "={rdi}" (d),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [count_in] "{rcx}" (count),
          [value] "{al}" (value),
        : .{ .memory = true });
}

// High EVEX registers do not dirty the low register bank that needs vzeroupper.
// The fragments implement the same independent head/tail classes as move.small.
pub const high_available = tuning.high_regs and builtin.zig_backend == .stage2_llvm;

fn highCopyText(comptime bytes: u32, comptime count: u32) []const u8 {
    @setEvalBranchQuota(300000);
    comptime var text: []const u8 = "";
    const reg = if (bytes == 64) "zmm" else "ymm";
    inline for (.{ "load", "store" }) |phase| {
        inline for (0..count) |i| {
            const offset: i32 = if (i < count / 2)
                @intCast(i * bytes)
            else
                -@as(i32, @intCast((count - i) * bytes));
            const suffix = if (i < count / 2) "" else ",%[n]";
            text = text ++ if (comptime mem.eql(u8, phase, "load"))
                fmt.comptimePrint("vmovdqu64 {d}(%[src]{s}), %%{s}{d}\n", .{
                    offset,
                    suffix,
                    reg,
                    16 + i,
                })
            else
                fmt.comptimePrint("vmovdqu64 %%{s}{d}, {d}(%[dst]{s})\n", .{
                    reg,
                    16 + i,
                    offset,
                    suffix,
                });
        }
    }
    return text;
}

pub inline fn highMove(
    comptime bytes: u32,
    comptime count: u32,
    dst: [*]u8,
    src: [*]const u8,
    n: usize,
) void {
    if (comptime !high_available) @compileError("highMove requires LLVM and AVX-512BW");
    if (comptime count > 8) {
        asm volatile (highCopyText(bytes, count)
            :
            : [dst] "r" (dst),
              [src] "r" (src),
              [n] "r" (n),
            : .{
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .memory = true,
            });
        return;
    }
    asm volatile (highCopyText(bytes, count)
        :
        : [dst] "r" (dst),
          [src] "r" (src),
          [n] "r" (n),
        : .{
          .zmm16 = true,
          .zmm17 = true,
          .zmm18 = true,
          .zmm19 = true,
          .zmm20 = true,
          .zmm21 = true,
          .zmm22 = true,
          .zmm23 = true,
          .memory = true,
        });
}

fn highSetText(comptime bytes: u32, comptime count: u32) []const u8 {
    @setEvalBranchQuota(300000);
    const reg = if (bytes == 64) "zmm" else "ymm";
    comptime var text: []const u8 = "vpbroadcastb %[value], %%" ++ reg ++ "16\n";
    inline for (0..count) |i| {
        const offset: i32 = if (i < count / 2)
            @intCast(i * bytes)
        else
            -@as(i32, @intCast((count - i) * bytes));
        const suffix = if (i < count / 2) "" else ",%[n]";
        text = text ++ fmt.comptimePrint("vmovdqu64 %%{s}16, {d}(%[dst]{s})\n", .{
            reg,
            offset,
            suffix,
        });
    }
    return text;
}

pub inline fn highSet(
    comptime bytes: u32,
    comptime count: u32,
    dst: [*]u8,
    value: c_int,
    n: usize,
) void {
    if (comptime !high_available) @compileError("highSet requires LLVM and AVX-512BW");
    asm volatile (highSetText(bytes, count)
        :
        : [dst] "r" (dst),
          [value] "r" (value),
          [n] "r" (n),
        : .{ .zmm16 = true, .memory = true });
}
