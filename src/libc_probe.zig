//! libc-probe: report how this build resolves the libc memory functions.
//!
//! Prints one JSON object on stdout (see docs/slop/bench-design.md):
//!
//! {"libc_path":"...","glibc_version":"...",
//!  "symbols":{"memcpy":{"address":"0x..","symbol":".."|null,"offset":"0x.."},
//!             "memmove":{...}}}
//!
//! Addresses and offsets are lowercase 0x-prefixed hex strings. offset is
//! relative to the library base (dli_fbase) of the symbol that dladdr
//! resolved; the harness disassembles the implementation at that offset.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const builtin = @import("builtin");

const c = @import("c");

// Resolve through dlopen("libc.so.6") + dlsym rather than extern symbols:
// the executable's own compiler_rt memcpy/memmove win symbol resolution
// under BIND_NOW, so &memcpy would point back into this binary instead of
// at the libc implementation the harness wants to disassemble.

// glibc only; referenced only under a comptime isGnu guard so musl and
// other libcs still link.
extern fn gnu_get_libc_version() [*:0]const u8;

const Probe = struct {
    address: usize,
    symbol: ?[]const u8,
    offset: usize,
    library_path: []const u8,
};

fn probeSymbol(handle: *anyopaque, name: [*:0]const u8) !Probe {
    const func = c.dlsym(handle, name) orelse return error.DlsymFailed;
    var info: c.Dl_info = mem.zeroes(c.Dl_info);
    if (c.dladdr(func, &info) == 0) {
        return error.DladdrFailed;
    }

    const address = @intFromPtr(func);
    const base: usize = if (info.dli_fbase != null) @intFromPtr(info.dli_fbase) else 0;

    return .{
        .address = address,
        .symbol = if (info.dli_sname != null) mem.span(info.dli_sname) else null,
        .offset = address - base,
        .library_path = if (info.dli_fname != null) mem.span(info.dli_fname) else "",
    };
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeSymbol(w: *Io.Writer, name: []const u8, probe: Probe, first: bool) !void {
    if (!first) try w.writeByte(',');
    try w.print("\"{s}\":{{\"address\":\"0x{x}\",\"symbol\":", .{ name, probe.address });
    if (probe.symbol) |s| {
        try writeJsonString(w, s);
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"offset\":\"0x{x}\"}}", .{probe.offset});
}

pub fn main(init: std.process.Init) !void {
    const handle = c.dlopen("libc.so.6", c.RTLD_NOW) orelse {
        std.debug.print("libc-probe: dlopen(libc.so.6) failed: {s}\n", .{
            if (c.dlerror()) |e| mem.span(e) else "unknown",
        });
        std.process.exit(1);
    };

    const memcpy_probe = probeSymbol(handle, "memcpy") catch |err| {
        std.debug.print("libc-probe: probing memcpy failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const memmove_probe = probeSymbol(handle, "memmove") catch |err| {
        std.debug.print("libc-probe: probing memmove failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const memset_probe = probeSymbol(handle, "memset") catch |err| {
        std.debug.print("libc-probe: probing memset failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const glibc_version: ?[]const u8 = if (comptime builtin.target.abi.isGnu())
        mem.span(gnu_get_libc_version())
    else
        null;

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &stdout_file_writer.interface;

    try w.writeAll("{\"libc_path\":");
    try writeJsonString(w, memcpy_probe.library_path);
    try w.writeAll(",\"glibc_version\":");
    if (glibc_version) |v| {
        try writeJsonString(w, v);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"symbols\":{");
    try writeSymbol(w, "memcpy", memcpy_probe, true);
    try writeSymbol(w, "memmove", memmove_probe, false);
    try writeSymbol(w, "memset", memset_probe, false);
    try w.writeAll("}}\n");
    try w.flush();
}
