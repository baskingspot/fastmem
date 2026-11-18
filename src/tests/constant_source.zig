//! A comptime-known source as the source of copy and move. The inline
//! classes that load through a `@Vector` must still lower to a run-time
//! load (issue #3). Before that fix the inline `load` helpers kept the
//! comptime pointer through `@ptrCast` and the compiler required a
//! well-defined layout for the vector type, so the build failed at
//! 16..64 bytes on aarch64, 16..128 bytes on an x86_64 256-bit-vector
//! build (baseline and x86_64_v3), and 16..256 bytes on an AVX-512 build.
//! Every other test copies a run-time buffer, whose pointer hides the
//! defect.
const std = @import("std");
const testing = std.testing;
const fastmem = @import("../root.zig");

/// The widest inline class on any build, so the ladder covers all of them
/// on every target: aarch64 inlines up to 64 bytes, an x86_64 build up to
/// `4 * vector width`, which is 128 bytes with 256-bit vectors and 256
/// with AVX-512. Above the limit both architectures call the C-ABI kernel.
const max = 256;

/// A `[*:0]const u8` constant, so `source[0..n]` at a comptime `n` keeps the
/// comptime pointer. A named array of the same bytes reproduces the defect
/// too; both forms reach `load` with a comptime-known pointer.
const source = "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210" ++
    "0123456789abcdef" ++ "fedcba9876543210";

test "copy: a string-literal source reaches every inline size" {
    // 257 inline expansions of the ladder, each with a comptime pointer.
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
