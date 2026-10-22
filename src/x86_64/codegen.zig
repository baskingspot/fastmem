//! Binary probes keep the consumer builtins enabled.
const std = @import("std");
const comptimePrint = std.fmt.comptimePrint;

const fastmem = @import("fastmem");

comptime {
    @setEvalBranchQuota(10_000_000);
    @export(fastmem.abi.memcpy, .{ .name = "probe_abi_copy" });
    @export(fastmem.abi.memmove, .{ .name = "probe_abi_move" });
    @export(fastmem.abi.memset, .{ .name = "probe_abi_set" });
    for (1..257) |n| {
        @export(&Fixed(n).copy, .{ .name = comptimePrint("probe_copy_{d}", .{n}) });
        @export(&Fixed(n).move, .{ .name = comptimePrint("probe_move_{d}", .{n}) });
        @export(&Fixed(n).set, .{ .name = comptimePrint("probe_set_{d}", .{n}) });
    }
}

fn Fixed(comptime n: u32) type {
    return struct {
        fn copy(d: [*]u8, s: [*]const u8) callconv(.c) void {
            fastmem.copy(u8, d[0..n], s[0..n]);
        }
        fn move(d: [*]u8, s: [*]const u8) callconv(.c) void {
            fastmem.move(u8, d[0..n], s[0..n]);
        }
        fn set(d: [*]u8, c: u8) callconv(.c) void {
            fastmem.set(u8, d[0..n], c);
        }
    };
}

// Range facts eliminate unrelated classes without a separate kernel implementation.
export fn probeMoveVec2(d: [*]u8, s: [*]const u8, n: usize) void {
    if (n < 64 or n > 128) unreachable;
    fastmem.move(u8, d[0..n], s[0..n]);
}
export fn probeMoveVec4(d: [*]u8, s: [*]const u8, n: usize) void {
    if (n < 129 or n > 256) unreachable;
    fastmem.move(u8, d[0..n], s[0..n]);
}
export fn probeSetVec2(d: [*]u8, c: u8, n: usize) void {
    if (n < 64 or n > 128) unreachable;
    fastmem.set(u8, d[0..n], c);
}
export fn probeSetVec4(d: [*]u8, c: u8, n: usize) void {
    if (n < 129 or n > 256) unreachable;
    fastmem.set(u8, d[0..n], c);
}

// Unbounded lengths retain the complete inline-to-large call graph.
export fn probeRuntimeCopy(d: [*]u8, s: [*]const u8, n: usize) void {
    fastmem.copy(u8, d[0..n], s[0..n]);
}
export fn probeRuntimeMove(d: [*]u8, s: [*]const u8, n: usize) void {
    fastmem.move(u8, d[0..n], s[0..n]);
}
export fn probeRuntimeSet(d: [*]u8, c: u8, n: usize) void {
    fastmem.set(u8, d[0..n], c);
}
