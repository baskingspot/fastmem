//! The resolver-trap fixture (docs/slop/runtime-dispatch.md). build.zig links it
//! with a fastmem module whose dispatch resolvers execute ud2.
//! Every path covers lengths through the configured ABI limit.
//! The program prints "small ok" before its first ABI call above that limit.
//! src/x86_64/run_dispatch.py requires the line and then SIGILL.
const std = @import("std");
const fastmem = @import("fastmem");
const linux = std.os.linux;

// No exportSymbols: before main, the Zig start code zeroes the TLS area
// with @memset (std/os/linux/tls.zig). That call is over 128 bytes and
// traps. The exported symbols are the abi entries at the same address
// (src/export/check.py proves it), so the abi calls below cover them.

var src: [256]u8 = undefined;
var dst: [256]u8 = undefined;

fn check(ok: bool, code: u8) void {
    if (!ok) linux.exit(code);
}

fn expect(offset: usize, n: usize, want: fn (usize) u8) void {
    @disableIntrinsics();
    for (dst[0..offset]) |b| check(b == 0xee, 10);
    for (dst[offset..][0..n], 0..) |b, i| check(b == want(i), 11);
    for (dst[offset + n ..]) |b| check(b == 0xee, 12);
}

fn reset() void {
    @disableIntrinsics();
    for (&dst) |*b| b.* = 0xee;
}

fn source(i: usize) u8 {
    return @truncate(i *% 29 +% 7);
}

fn fill(_: usize) u8 {
    return 0x5c;
}

pub fn main() void {
    for (&src, 0..) |*b, i| b.* = source(i);
    var n: usize = 0;
    while (n <= fastmem.dispatch.small_max) : (n += 1) {
        const len = @as(*volatile usize, &n).*;
        for ([_]usize{ 0, 1, 63 }) |offset| {
            const d = dst[offset..][0..len];
            reset();
            _ = fastmem.abi.memcpy(d.ptr, &src, len);
            expect(offset, len, source);
            reset();
            _ = fastmem.abi.memmove(d.ptr, &src, len);
            expect(offset, len, source);
            reset();
            _ = fastmem.abi.memset(d.ptr, 0x15c, len);
            expect(offset, len, fill);
            // The inline layer.
            reset();
            fastmem.copy(u8, d, src[0..len]);
            expect(offset, len, source);
            reset();
            fastmem.move(u8, d, src[0..len]);
            expect(offset, len, source);
            reset();
            fastmem.set(u8, d, 0x5c);
            expect(offset, len, fill);
        }
        // Overlapping moves in both directions.
        for (&dst, 0..) |*b, i| b.* = source(i);
        _ = fastmem.abi.memmove(dst[1..].ptr, &dst, len);
        for (0..len) |i| check(dst[i + 1] == source(i), 13);
        for (&dst, 0..) |*b, i| b.* = source(i);
        _ = fastmem.abi.memmove(&dst, dst[1..].ptr, len);
        for (0..len) |i| check(dst[i] == source(i + 1), 14);
    }
    const line = "small ok\n";
    _ = linux.write(1, line, line.len);
    // The first size above small_max reaches a resolver, which traps.
    var large: usize = fastmem.dispatch.small_max + 1;
    _ = fastmem.abi.memcpy(&dst, &src, @as(*volatile usize, &large).*);
    linux.exit(3);
}
