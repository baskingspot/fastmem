//! The root of one kernel object of the x86_64 runtime dispatch
//! (docs/runtime-dispatch.md). build.zig compiles this file once per
//! level, with -Dcpu set to the level name. The object contains the same
//! kernels as a comptime build for that CPU, under hidden symbol names
//! that contain the package instance id and the level name.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("fastmem_options");
const move = @import("move.zig");
const set = @import("set.zig");
const tuning = @import("tuning.zig");
const find = @import("find_kernel");

// The same names as `kernels` in dispatch.zig: prefix, instance, level.
const prefix = "fastmem_x86_" ++ options.x86_instance ++ "_" ++ builtin.cpu.model.name ++ "_";
const kernel_name = std.fmt.comptimePrint("{s}{s}", .{
    tuning.move_name,
    if (tuning.dispatch_small_max == 64) "+above64" else "",
});

comptime {
    if (!tuning.available) @compileError("a dispatch level object requires AVX2");
    @export(&move.moveKernel, .{ .name = prefix ++ "memmove", .visibility = .hidden });
    @export(&set.kernel, .{ .name = prefix ++ "memset", .visibility = .hidden });
    @export(&move.kernelAboveSmall, .{
        .name = prefix ++ "memmove_above_small",
        .visibility = .hidden,
    });
    @export(&set.kernelAboveSmall, .{
        .name = prefix ++ "memset_above_small",
        .visibility = .hidden,
    });
    @export(&name, .{ .name = prefix ++ "name", .visibility = .hidden });
    @export(&find.kernel, .{
        .name = "fastmem_find_" ++ options.x86_instance ++ "_" ++ builtin.cpu.model.name,
        .visibility = .hidden,
    });
}

// A function, not a data symbol: the harness disassembles every
// fastmem_* symbol of the benchmark binary.
fn name() callconv(.c) [*:0]const u8 {
    return kernel_name.ptr;
}
