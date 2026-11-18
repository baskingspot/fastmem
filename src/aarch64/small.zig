//! Loop-free small-size (<= 64 bytes) copy/move/set classes, inlined at
//! the call site of fastmem.copy/move/set on aarch64. These are the same
//! size classes as the neon variant of the C-ABI kernels
//! (src/aarch64/tuning.zig), written in Zig so they inline:
//! - every load/store is sized to the count, so guard-page tails stay
//!   safe (no 16-byte reads of a 3-byte copy),
//! - all loads of a class precede all stores, so overlapping moves stay
//!   correct (LLVM cannot sink the stores before the loads: the pointers
//!   may alias and there is no noalias here),
//! - chunk copies use @Vector through align(1) pointers, never [N]u8
//!   array copies, which spill to the stack (aarch64-design.md E10),
//! - no loops: an inlined loop takes the caller's builtin setting and
//!   can be idiom-recognized into a memcpy/memset call (E11).
//!
//! The classes mirror AOR memcpy-advsimd.S / memset-advsimd.S
//! (in-tree ports carry the attribution).

const Vec16 = @Vector(16, u8);
const Vec32 = @Vector(32, u8);

/// Largest size handled inline; above this the C-ABI kernel is called.
pub const max_inline = 64;

inline fn load(comptime T: type, p: [*]const u8) T {
    // The round-trip needs the check off. @ptrFromInt asserts a non-null
    // pointer in safety-checked builds, and that branch stops LLVM from
    // hoisting the loads out of the size ladder: ReleaseSafe grew every
    // inline class. A source pointer is never null, so the check is noise.
    @setRuntimeSafety(false);
    // Through the integer, not @ptrCast: a comptime-known pointer (a string
    // literal source) stays comptime-known through @ptrCast, so `q.*` becomes
    // a comptime dereference of a @Vector, which has no defined layout and is
    // rejected (issue #3). The round-trip always yields a run-time pointer.
    const q: *align(1) const T = @ptrFromInt(@intFromPtr(p));
    return q.*;
}

inline fn store(comptime T: type, p: [*]u8, v: T) void {
    const q: *align(1) T = @ptrCast(p);
    q.* = v;
}

/// Copy exactly n bytes, 0 <= n <= 64. Overlap-safe, so copy and move
/// share it (same property the AOR small classes rely on).
pub inline fn copyMove(d: [*]u8, s: [*]const u8, n: usize) void {
    if (n < 16) {
        if (n < 8) {
            if (n < 4) {
                if (n == 0) return;
                // 1..3 bytes: head, middle, tail (the same byte for n < 3).
                const a = s[0];
                const b = s[n / 2];
                const c = s[n - 1];
                d[0] = a;
                d[n / 2] = b;
                d[n - 1] = c;
            } else {
                // 4..7 bytes: two overlapping 4-byte pieces.
                const a = load(u32, s);
                const b = load(u32, s + n - 4);
                store(u32, d, a);
                store(u32, d + n - 4, b);
            }
        } else {
            // 8..15 bytes: two overlapping 8-byte pieces.
            const a = load(u64, s);
            const b = load(u64, s + n - 8);
            store(u64, d, a);
            store(u64, d + n - 8, b);
        }
    } else if (n <= 32) {
        // 16..32 bytes: two overlapping 16-byte vectors.
        const a = load(Vec16, s);
        const b = load(Vec16, s + n - 16);
        store(Vec16, d, a);
        store(Vec16, d + n - 16, b);
    } else {
        // 33..64 bytes: overlapping 32-byte head and tail.
        const a = load(Vec32, s);
        const b = load(Vec32, s + n - 32);
        store(Vec32, d, a);
        store(Vec32, d + n - 32, b);
    }
}

/// Set exactly n bytes, 0 <= n <= 64, to value.
pub inline fn set(d: [*]u8, value: u8, n: usize) void {
    if (n < 16) {
        if (n < 4) {
            if (n == 0) return;
            // 1..3 bytes: head, middle, tail.
            d[0] = value;
            d[n / 2] = value;
            d[n - 1] = value;
        } else {
            // 4..15 bytes: four 4-byte stores, off = 4 & (n >> 1) * 4.
            const v: u32 = @as(u32, value) * 0x01010101;
            const off: usize = (n >> 3) * 4;
            store(u32, d, v);
            store(u32, d + off, v);
            store(u32, d + n - off - 4, v);
            store(u32, d + n - 4, v);
        }
    } else {
        // 16..64 bytes: four overlapping 16-byte stores with the AOR
        // offset mask. off is 0, 16, or 32 and never exceeds n - 16.
        const v: Vec16 = @splat(value);
        const off: usize = 48 & (n >> 1);
        store(Vec16, d, v);
        store(Vec16, d + off, v);
        store(Vec16, d + n - off - 16, v);
        store(Vec16, d + n - 16, v);
    }
}
