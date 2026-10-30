//! Print the level that the runtime dispatch selects on this CPU, as one
//! JSON line. src/x86_64/run_dispatch.py runs it under several qemu CPU
//! models and checks the level.
const std = @import("std");
const Io = std.Io;
const fastmem = @import("fastmem");
const linux = std.os.linux;

pub fn main() void {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const info = fastmem.dispatch.detect().?;
    var src: [300]u8 = @splat(0x5a);
    var dst: [300]u8 = @splat(0);
    // The first call resolves the level through the lazy pointer.
    _ = fastmem.abi.memcpy(&dst, &src, src.len);
    if (dst[299] != 0x5a) linux.exit(2);
    std.json.Stringify.value(.{
        .level = @tagName(fastmem.dispatch.level().?),
        .kernel = fastmem.dispatch.kernelName().?,
        .vendor = @tagName(info.vendor),
        .family = info.family,
        .model = info.model,
    }, .{}, &writer) catch linux.exit(3);
    writer.writeByte('\n') catch linux.exit(3);
    const line = writer.buffered();
    _ = linux.write(1, line.ptr, line.len);
}
