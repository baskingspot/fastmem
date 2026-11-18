//! A string literal as the source of copy and move. Its pointer is
//! comptime-known, so every inline class that loads through a `@Vector`
//! must still lower to a run-time load (issue #3). Before that fix the
//! inline `load` helpers kept the comptime pointer through `@ptrCast` and
//! the compiler required a well-defined layout for the vector type:
//! aarch64 failed to compile at 16..64 bytes, a dispatching x86_64 build
//! at 16..128 bytes. Every other test copies a run-time buffer, whose
//! pointer hides the defect.
const std = @import("std");
const testing = std.testing;
const fastmem = @import("../root.zig");

/// The widest first-failure range: the x86_64 inline limit. Above it both
/// architectures call the C-ABI kernel with a run-time pointer.
const max = 128;

/// A `[*:0]const u8` constant, so `source[0..n]` at a comptime `n` keeps the
/// comptime pointer. A named array value does not reproduce the defect.
const source = "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210";

test "copy: a string-literal source reaches every inline size" {
    // 129 inline expansions of the ladder, each with a comptime pointer.
    @setEvalBranchQuota(100_000);
    var got: [max]u8 = undefined;
    inline for (0..max + 1) |n| {
        @memset(&got, 0xa5);
        fastmem.copy(u8, got[0..n], source[0..n]);
        try testing.expectEqualStrings(source[0..n], got[0..n]);
    }
}

test "move: a string-literal source reaches every inline size" {
    @setEvalBranchQuota(100_000);
    var got: [max]u8 = undefined;
    inline for (0..max + 1) |n| {
        @memset(&got, 0xa5);
        fastmem.move(u8, got[0..n], source[0..n]);
        try testing.expectEqualStrings(source[0..n], got[0..n]);
    }
}
