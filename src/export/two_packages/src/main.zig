//! Two fastmem copies in one link. Copy a exports the memory symbols, and
//! copy b serves explicit calls. Both dispatch at run time on x86_64
//! baseline, and use their own kernels on aarch64.
const std = @import("std");
const builtin = @import("builtin");
const a = @import("fastmem_a");
const b = @import("fastmem_b");
const linux = std.os.linux;

comptime {
    a.exportSymbols();
}

pub fn main() void {
    var src: [5001]u8 = undefined;
    var dst: [5001]u8 = undefined;
    for (&src, 0..) |*x, i| x.* = @truncate(i *% 13 +% 5);
    var n: usize = 0;
    while (n <= src.len) : (n += 1) {
        const len = @as(*volatile usize, &n).*;
        @memcpy(dst[0..len], src[0..len]);
        if (!std.mem.eql(u8, dst[0..len], src[0..len])) linux.exit(1);
        b.set(u8, dst[0..len], 0x44);
        for (dst[0..len]) |c| if (c != 0x44) linux.exit(2);
        b.copy(u8, dst[0..len], src[0..len]);
        if (!std.mem.eql(u8, dst[0..len], src[0..len])) linux.exit(3);
        b.move(u8, dst[1..][0 .. len - @min(len, 1)], dst[0 .. len - @min(len, 1)]);
    }
    // The Level types differ: each package copy is its own module.
    if (builtin.cpu.arch == .x86_64) {
        const level = @tagName(a.dispatch.level().?);
        if (!std.mem.eql(u8, level, @tagName(b.dispatch.level().?))) linux.exit(4);
    }
    var buffer: [128]u8 = undefined;
    const label = if (builtin.cpu.arch == .x86_64)
        @tagName(a.dispatch.level().?)
    else
        a.impl.copy;
    const line = std.fmt.bufPrint(&buffer, "{s}\n", .{label}) catch linux.exit(5);
    _ = linux.write(1, line.ptr, line.len);
}
