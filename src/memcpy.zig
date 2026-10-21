const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const common = @import("common.zig");
const forward = @import("forward.zig");

/// Tuning of the generic Zig fallback. It runs only where no dedicated
/// kernel applies: x86_64 without AVX2, and architectures other than
/// x86_64 and aarch64. The table matches the old generic x86_64 and
/// aarch64 entries. The fallback never calls memcpy, memmove, or memset
/// through a symbol (docs/slop/fastmem-plan.md).
const Flags = struct {
    tight_loop: bool,
    medium_straight_line: bool,
    copy_align_peel_min_strides: usize,
};

const flags: Flags = .{
    .tight_loop = false,
    .medium_straight_line = true,
    .copy_align_peel_min_strides = 8,
};

pub const copy_align_peel_min = flags.copy_align_peel_min_strides * common.stride;

pub const forward_options: forward.Options = .{
    .tight_loop = flags.tight_loop,
    .medium_straight_line = flags.medium_straight_line,
    .align_peel_min_bytes = copy_align_peel_min,
};

comptime {
    assert(copy_align_peel_min >= common.stride);
}

/// Non-overlapping copy. Prefer over @memcpy for runtime-sized copies
/// that may exceed ~32 bytes.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    @disableIntrinsics();
    assert(dest.len >= source.len);

    const byte_len = common.byteLen(T, source.len);
    if (byte_len == 0) return;

    const d: [*]u8 = @ptrCast(dest.ptr);
    const s: [*]const u8 = @ptrCast(source.ptr);

    const d_addr = @intFromPtr(d);
    const s_addr = @intFromPtr(s);

    assert(s_addr <= math.maxInt(usize) - byte_len);
    const s_end = s_addr + byte_len;
    assert(d_addr <= s_addr or d_addr >= s_end);

    forward.run(forward_options, d, s, byte_len);
}
