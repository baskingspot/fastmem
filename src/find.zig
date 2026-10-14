//! Forward one-shot byte search, ported from BurntSushi/memchr.
//! Copyright (c) 2015 Andrew Gallant. MIT; see licenses/memchr-MIT.txt.
//! Upstream bd6068c30e9074a90c285e47912fa0b047d07597:
//! src/memmem/{mod,searcher}.rs, src/arch/all/{rabinkarp,twoway}.rs,
//! src/arch/all/packedpair/{mod,default_rank}.rs and
//! src/arch/generic/packedpair.rs. Only forward algorithm mechanics are ported.
//! Bounded vector loads and overlapping tails retain upstream policy.
//! No dynamic union, ownership, iterators, libc comparisons or allocations.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const rank = @import("find/rank.zig").rank;

// Deliberately retain AVX2/NEON defaults even on AVX512/SVE targets.
const width = if (builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2)) 32 else 16;
const tiny_haystack = 64;
const packed_max = 32;
// A difference of 16 permits 17 starts, including the initial equality check.
const few_starts_max_difference = 16;
const min_skips = 50;
const min_skip_bytes = 8;

pub fn find(haystack: []const u8, needle: []const u8) ?usize {
    @disableIntrinsics();
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == haystack.len) return if (equal(haystack, needle)) 0 else null;
    if (needle.len == 1) return findByte(haystack, needle[0]);
    if (haystack.len < tiny_haystack) return rabinKarp(haystack, needle);
    if (needle.len > packed_max) {
        // Avoid one-shot preprocessing when a bounded full comparison suffices.
        if (equal(haystack[0..needle.len], needle)) return 0;
        const last = haystack.len - needle.len;
        if (last <= few_starts_max_difference) {
            var pos: usize = 1;
            while (pos <= last) : (pos += 1) {
                if (equal(haystack[pos..][0..needle.len], needle)) return pos;
            }
            return null;
        }
    }
    const pair = selectPair(needle);
    return if (needle.len <= packed_max)
        packedSearch(haystack, needle, pair)
    else
        twoWay(haystack, needle, pair);
}

// Internal dispatch boundary: maxInt cannot be a match for a nonempty needle.
pub fn kernel(h: [*]const u8, hlen: usize, n: [*]const u8, nlen: usize) callconv(.c) usize {
    @disableIntrinsics();
    return find(h[0..hlen], n[0..nlen]) orelse std.math.maxInt(usize);
}

inline fn load(comptime W: comptime_int, p: [*]const u8) @Vector(W, u8) {
    return @as(*align(1) const @Vector(W, u8), @ptrCast(p)).*;
}

fn equal(a: []const u8, b: []const u8) bool {
    @disableIntrinsics();
    var i: usize = 0;
    while (a.len - i >= width) : (i += width) {
        if (!@reduce(.And, load(width, a.ptr + i) == load(width, b.ptr + i))) return false;
    }
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn findByte(haystack: []const u8, byte: u8) ?usize {
    @disableIntrinsics();
    var pos: usize = 0;
    const splat: @Vector(width, u8) = @splat(byte);
    while (haystack.len - pos >= width) : (pos += width) {
        const mask = laneMask(width, load(width, haystack.ptr + pos) == splat);
        if (mask != 0) return pos + @ctz(mask);
    }
    for (haystack[pos..], pos..) |b, i| if (b == byte) return i;
    return null;
}

fn rabinKarp(haystack: []const u8, needle: []const u8) ?usize {
    @disableIntrinsics();
    var wanted: u32 = 0;
    var hash: u32 = 0;
    var factor: u32 = 1;
    for (needle, haystack[0..needle.len], 0..) |n, h, i| {
        wanted = (wanted << 1) +% n;
        hash = (hash << 1) +% h;
        if (i != 0) factor <<= 1;
    }
    var pos: usize = 0;
    const last = haystack.len - needle.len;
    while (true) : (pos += 1) {
        if (hash == wanted and equal(haystack[pos..][0..needle.len], needle)) return pos;
        if (pos == last) return null;
        hash = ((hash -% (@as(u32, haystack[pos]) *% factor)) << 1) +%
            haystack[pos + needle.len];
    }
}

const Pair = struct { first: u8, second: u8 };

fn selectPair(needle: []const u8) Pair {
    @disableIntrinsics();
    var pair: Pair = .{ .first = 0, .second = 1 };
    if (rank[needle[1]] < rank[needle[0]]) pair = .{ .first = 1, .second = 0 };
    // Match upstream's take(u8::MAX): offset 254 is the final inspected byte.
    for (needle[2..@min(needle.len, 255)], 2..) |byte, i| {
        if (rank[byte] < rank[needle[pair.first]]) {
            pair.second = pair.first;
            pair.first = @intCast(i);
        } else if (byte != needle[pair.first] and rank[byte] < rank[needle[pair.second]]) {
            pair.second = @intCast(i);
        }
    }
    return pair;
}

// Boolean-vector bitcasts have target-dependent bit order on big-endian
// backends (aarch64_be and powerpc64 differ). Construct lane weights there
// instead, keeping ctz and overlapping-tail masks in memory order.
inline fn laneMask(comptime W: comptime_int, matches: @Vector(W, bool)) @Int(.unsigned, W) {
    if (comptime builtin.cpu.arch.endian() == .little) return @bitCast(matches);
    const mask_type = @Int(.unsigned, W);
    const ones: @Vector(W, mask_type) = @splat(1);
    const weights = ones << std.simd.iota(mask_type, W);
    const zeroes: @Vector(W, mask_type) = @splat(0);
    return @reduce(.Or, @select(mask_type, matches, weights, zeroes));
}

inline fn pairMask(
    comptime W: comptime_int,
    h: [*]const u8,
    n: []const u8,
    pair: Pair,
) @Int(.unsigned, W) {
    const a: @Vector(W, u8) = @splat(n[pair.first]);
    const b: @Vector(W, u8) = @splat(n[pair.second]);
    return laneMask(W, (load(W, h + pair.first) == a) & (load(W, h + pair.second) == b));
}

fn packedSearch(haystack: []const u8, needle: []const u8, pair: Pair) ?usize {
    @disableIntrinsics();
    if (comptime width == 32) {
        if (haystack.len < @as(usize, @max(pair.first, pair.second)) + width)
            return packedImp(16, haystack, needle, pair);
    }
    return packedImp(width, haystack, needle, pair);
}

fn packedImp(
    comptime W: comptime_int,
    haystack: []const u8,
    needle: []const u8,
    pair: Pair,
) ?usize {
    @disableIntrinsics();
    const minimum = @max(needle.len, @as(usize, @max(pair.first, pair.second)) + W);
    if (haystack.len < minimum) return rabinKarp(haystack, needle);
    const last_load = haystack.len - minimum;
    const last_match = haystack.len - needle.len;
    var pos: usize = 0;
    while (true) {
        var mask = pairMask(W, haystack.ptr + pos, needle, pair);
        while (mask != 0) {
            const found = pos + @ctz(mask);
            if (found > last_match) return null;
            if (equal(haystack[found..][0..needle.len], needle)) return found;
            mask &= mask - 1;
        }
        if (last_load - pos >= W) {
            pos += W;
        } else {
            const overlap = W - (last_load - pos);
            if (last_match - pos < W) return null;
            // The final load overlaps the preceding load. Suppress starts
            // already verified; loads themselves remain wholly in bounds.
            mask = pairMask(W, haystack.ptr + last_load, needle, pair) &
                (@as(@Int(.unsigned, W), std.math.maxInt(@Int(.unsigned, W))) << @intCast(overlap));
            while (mask != 0) {
                const found = last_load + @ctz(mask);
                if (found > last_match) return null;
                if (equal(haystack[found..][0..needle.len], needle)) return found;
                mask &= mask - 1;
            }
            return null;
        }
    }
}

fn candidate(haystack: []const u8, needle: []const u8, pair: Pair) ?usize {
    @disableIntrinsics();
    const max_offset: usize = @max(pair.first, pair.second);
    if (comptime width == 32) {
        if (haystack.len < max_offset + width)
            return candidateImp(16, haystack, needle, pair);
    }
    return candidateImp(width, haystack, needle, pair);
}

fn candidateImp(
    comptime W: comptime_int,
    haystack: []const u8,
    needle: []const u8,
    pair: Pair,
) ?usize {
    @disableIntrinsics();
    const minimum = @max(needle.len, @as(usize, @max(pair.first, pair.second)) + W);
    if (haystack.len < minimum) {
        // Upstream's small-haystack prefilter checks only the rarest byte.
        const found = findByte(haystack, needle[pair.first]) orelse return null;
        return found -| pair.first;
    }
    const last_load = haystack.len - minimum;
    var pos: usize = 0;
    while (true) {
        const mask = pairMask(W, haystack.ptr + pos, needle, pair);
        if (mask != 0) return pos + @ctz(mask);
        if (last_load - pos < W) break;
        pos += W;
    }
    // All prior positions were rejected, so overlapping starts need no mask.
    const mask = pairMask(W, haystack.ptr + last_load, needle, pair);
    return if (mask != 0) last_load + @ctz(mask) else null;
}

const Suffix = struct { pos: usize, period: usize };
const SuffixKind = enum { minimal, maximal };

fn suffix(needle: []const u8, kind: SuffixKind) Suffix {
    @disableIntrinsics();
    // Upstream's zero-based form eliminates the traditional -1 sentinel.
    // All additions stay <= needle.len, including candidate's final advance.
    var result: Suffix = .{ .pos = 0, .period = 1 };
    var start: usize = 1;
    var offset: usize = 0;
    while (offset < needle.len - start) {
        const current = needle[result.pos + offset];
        const next = needle[start + offset];
        if (current == next) {
            if (offset + 1 == result.period) {
                start += result.period;
                offset = 0;
            } else offset += 1;
        } else if (if (kind == .minimal) next < current else next > current) {
            result = .{ .pos = start, .period = 1 };
            start += 1;
            offset = 0;
        } else {
            start += offset + 1;
            offset = 0;
            result.period = start - result.pos;
        }
    }
    return result;
}

const Factorization = struct {
    critical: usize,
    shift: usize,
    kind: enum { small, large },

    fn init(needle: []const u8) Factorization {
        @disableIntrinsics();
        const min = suffix(needle, .minimal);
        const max = suffix(needle, .maximal);
        const chosen = if (min.pos > max.pos) min else max;
        const critical = chosen.pos;
        const period = chosen.period;
        // Subtraction rather than critical*2 avoids overflow.
        if (critical < needle.len - critical and critical <= period and
            equal(needle[0..critical], needle[period..][0..critical]))
        {
            return .{ .critical = critical, .shift = period, .kind = .small };
        }
        return .{
            .critical = critical,
            .shift = @max(critical, needle.len - critical),
            .kind = .large,
        };
    }
};

const Prefilter = struct {
    attempts: u32 = 0,
    skipped: u32 = 0,
    state: enum { active, inert } = .active,

    fn effective(self: *Prefilter) bool {
        if (self.state == .inert) return false;
        // Widen before multiplication; upstream's u32 multiply can overflow.
        if (self.attempts < min_skips or self.skipped >=
            @as(u64, self.attempts) * min_skip_bytes) return true;
        self.state = .inert;
        return false;
    }

    fn update(self: *Prefilter, skipped: usize) void {
        self.attempts +|= 1;
        self.skipped +|= @intCast(@min(skipped, std.math.maxInt(u32)));
    }
};

fn twoWay(haystack: []const u8, needle: []const u8, pair: Pair) ?usize {
    @disableIntrinsics();
    const factor = Factorization.init(needle);
    var byteset: u64 = 0;
    for (needle) |byte| byteset |= @as(u64, 1) << @as(u6, @truncate(byte));
    var pre: Prefilter = .{};
    var pos: usize = 0;
    var memory: usize = 0;
    const last = haystack.len - needle.len;
    while (true) {
        if (pre.effective()) {
            const skip = candidate(haystack[pos..], needle, pair) orelse return null;
            pre.update(skip);
            if (skip > last - pos) return null;
            pos += skip;
            // Reset even for zero skip, matching upstream's prefilter path.
            memory = 0;
        }
        const tail = haystack[pos + needle.len - 1];
        var advance: usize = needle.len;
        if (byteset & (@as(u64, 1) << @as(u6, @truncate(tail))) != 0) {
            var i = @max(factor.critical, memory);
            while (i < needle.len and needle[i] == haystack[pos + i]) : (i += 1) {}
            if (i < needle.len) {
                advance = i - factor.critical + 1;
                memory = 0;
            } else {
                var j = factor.critical;
                while (j > memory and needle[j - 1] == haystack[pos + j - 1]) : (j -= 1) {}
                if (j <= memory) return pos;
                advance = factor.shift;
                memory = if (factor.kind == .small) needle.len - factor.shift else 0;
            }
        } else memory = 0;
        // Check before advancing; pos+needle.len and final shifts cannot wrap.
        if (advance > last - pos) return null;
        pos += advance;
    }
}

fn oracle(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |pos| {
        var i: usize = 0;
        while (i < needle.len and haystack[pos + i] == needle[i]) : (i += 1) {}
        if (i == needle.len) return pos;
    }
    return null;
}

test "exhaustive binary alphabet search and Two-Way" {
    var h: [9]u8 = undefined;
    var n: [7]u8 = undefined;
    for (0..h.len + 1) |hlen| {
        for (0..@as(usize, 1) << @intCast(hlen)) |bits| {
            for (h[0..hlen], 0..) |*b, i| b.* = @truncate((bits >> @intCast(i)) & 1);
            for (0..n.len + 1) |nlen| {
                for (0..@as(usize, 1) << @intCast(nlen)) |nbits| {
                    for (n[0..nlen], 0..) |*b, i| b.* = @truncate((nbits >> @intCast(i)) & 1);
                    const expected = oracle(h[0..hlen], n[0..nlen]);
                    try testing.expectEqual(expected, find(h[0..hlen], n[0..nlen]));
                    if (nlen >= 2 and nlen <= hlen) {
                        const pair = selectPair(n[0..nlen]);
                        try testing.expectEqual(expected, twoWay(h[0..hlen], n[0..nlen], pair));
                        try testing.expectEqual(
                            expected,
                            packedSearch(h[0..hlen], n[0..nlen], pair),
                        );
                    }
                }
            }
        }
    }
}

test "suffix factorization periodic and nonperiodic" {
    try testing.expectEqual(Suffix{ .pos = 2, .period = 2 }, suffix("banana", .maximal));
    try testing.expectEqual(Suffix{ .pos = 1, .period = 2 }, suffix("banana", .minimal));
    try testing.expectEqual(.small, Factorization.init("abababab").kind);
    try testing.expectEqual(@as(usize, 2), Factorization.init("abababab").shift);
    try testing.expectEqual(.large, Factorization.init("abcdef").kind);
    try testing.expectEqual(@as(usize, 0), suffix("aaaaaaaa", .maximal).pos);
}

test "random differential binary and low entropy with shared slices" {
    var prng = std.Random.DefaultPrng.init(0x623a9935);
    const random = prng.random();
    var h: [1100]u8 = undefined;
    var n: [300]u8 = undefined;
    for (0..12000) |trial| {
        random.bytes(&h);
        random.bytes(&n);
        if (trial % 3 == 0) {
            for (&h) |*byte| byte.* &= 3;
            for (&n) |*byte| byte.* &= 3;
        }
        const hoff = random.uintLessThan(usize, 32);
        const noff = random.uintLessThan(usize, 32);
        const hlen = random.uintLessThan(usize, 1025);
        const nlen = random.uintLessThan(usize, 257);
        const hs = h[hoff..][0..hlen];
        const ns = n[noff..][0..nlen];
        if (trial % 2 == 0 and nlen <= hlen) {
            const pos = random.uintLessThan(usize, hlen - nlen + 1);
            for (ns, hs[pos..][0..nlen]) |byte, *out| out.* = byte;
        }
        try testing.expectEqual(oracle(hs, ns), find(hs, ns));
        if (nlen <= hlen) {
            const shared = hs[hlen - nlen ..];
            try testing.expectEqual(oracle(hs, shared), find(hs, shared));
        }
    }
}

test "vector boundaries tails and pathological prefilter fallback" {
    var h: [2048]u8 = @splat('a');
    var n: [512]u8 = @splat('a');
    for ([_]usize{ 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 511 }) |nlen| {
        n[nlen / 2] = 'b';
        for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65 }) |padding| {
            const hlen = nlen + padding;
            h = @splat('a');
            for (n[0..nlen], h[padding..][0..nlen]) |byte, *out| out.* = byte;
            try testing.expectEqual(oracle(h[0..hlen], n[0..nlen]), find(h[0..hlen], n[0..nlen]));
        }
        n[nlen / 2] = 'a';
        // Both selected bytes match everywhere; middle mismatch forces fallback.
        n[nlen - 1] = 'b';
        h = @splat('a');
        try testing.expectEqual(
            @as(?usize, null),
            twoWay(&h, n[0..nlen], .{ .first = 0, .second = 1 }),
        );
        n[nlen - 1] = 'a';
    }
    var pre: Prefilter = .{};
    for (0..min_skips) |_| pre.update(0);
    try testing.expect(!pre.effective());
    pre = .{ .attempts = std.math.maxInt(u32), .skipped = std.math.maxInt(u32) };
    pre.update(std.math.maxInt(usize));
    try testing.expectEqual(std.math.maxInt(u32), pre.skipped);
    try testing.expect(!pre.effective());
}

test "maximal suffix against independent ternary lexicographic oracle" {
    var bytes: [8]u8 = undefined;
    var combinations: usize = 1;
    for (1..bytes.len + 1) |len| {
        combinations *= 3;
        for (0..combinations) |encoding| {
            var digits = encoding;
            for (bytes[0..len]) |*byte| {
                byte.* = @intCast(digits % 3);
                digits /= 3;
            }
            var best: usize = 0;
            for (1..len) |start| {
                var offset: usize = 0;
                while (start + offset < len and
                    bytes[start + offset] == bytes[best + offset]) : (offset += 1)
                {}
                if (start + offset < len and bytes[start + offset] > bytes[best + offset])
                    best = start;
            }
            const result = suffix(bytes[0..len], .maximal);
            try testing.expectEqual(best, result.pos);
            for (result.pos + result.period..len) |i|
                try testing.expectEqual(bytes[i - result.period], bytes[i]);
        }
    }
}

test "pair offset limit and vector minimum boundaries" {
    var n: [300]u8 = @splat(' ');
    n[254] = 1;
    n[255] = 255;
    const pair = selectPair(&n);
    try testing.expectEqual(@as(u8, 254), pair.first);
    try testing.expect(pair.first != pair.second);
    var h: [400]u8 = @splat(' ');
    for ([_]Pair{
        .{ .first = 0, .second = 1 },
        .{ .first = 1, .second = 0 },
        .{ .first = 15, .second = 31 },
        .{ .first = 31, .second = 15 },
        .{ .first = 254, .second = 255 },
    }) |selected_pair| {
        const nlen: usize = @max(selected_pair.first, selected_pair.second) + @as(usize, 1);
        n = @splat(' ');
        n[selected_pair.first] = 'x';
        n[selected_pair.second] = 'y';
        for (0..66) |padding| {
            h = @splat(' ');
            for (n[0..nlen], h[padding..][0..nlen]) |byte, *out| out.* = byte;
            const hs = h[0 .. nlen + padding];
            const ns = n[0..nlen];
            const expected = oracle(hs, ns);
            try testing.expectEqual(expected, packedImp(16, hs, ns, selected_pair));
            try testing.expectEqual(expected, packedImp(32, hs, ns, selected_pair));
            const found = candidate(hs, ns, selected_pair);
            try testing.expect(found != null and found.? <= expected.?);
        }
    }
}

test "guard seam values select the intended prefix offsets" {
    var needle: [4096]u8 = undefined;
    for ([_]usize{ 2, 3, 15, 16, 17, 31, 32, 33, 254, 255, 256, 257, 512, 4096 }) |len| {
        for ([_]usize{ 0, (len - 1) / 2, @min(len - 1, 254), @min(len - 1, 255) }) |wanted| {
            const limit = @min(len, 255);
            const first = @min(wanted, limit - 1);
            const second = (first + 1) % limit;
            @memset(needle[0..len], ' ');
            needle[first] = 1;
            needle[second] = 0;
            const pair = selectPair(needle[0..len]);
            try testing.expectEqual(first, @as(usize, pair.first));
            try testing.expectEqual(second, @as(usize, pair.second));
        }
    }
}

test "only rare byte beyond the automatic prefix stays unselected" {
    var haystack: [1024]u8 = @splat(' ');
    var needle: [512]u8 = @splat(' ');
    needle[needle.len - 1] = 1;
    try testing.expect(rank[1] < rank[' ']);
    try testing.expectEqual(Pair{ .first = 0, .second = 1 }, selectPair(&needle));
    try testing.expectEqual(@as(?usize, null), find(&haystack, &needle));
    @memcpy(haystack[512..], &needle);
    try testing.expectEqual(@as(?usize, 512), find(&haystack, &needle));
}

test "lane masks preserve ascending memory order" {
    var bytes: [64]u8 = @splat(0);
    for (0..32) |lane| {
        bytes = @splat(0);
        bytes[lane] = 1;
        const matches = load(32, &bytes) == @as(@Vector(32, u8), @splat(1));
        const mask = laneMask(32, matches);
        try testing.expectEqual(@as(u32, 1) << @intCast(lane), mask);
        try testing.expectEqual(@as(usize, std.simd.firstTrue(matches).?), @ctz(mask));
        try testing.expectEqual(@as(?usize, lane), findByte(&bytes, 1));
        if (lane < 16) {
            const short = load(16, &bytes) == @as(@Vector(16, u8), @splat(1));
            try testing.expectEqual(@as(u16, 1) << @intCast(lane), laneMask(16, short));
        }
    }
    bytes[32] = 1;
    try testing.expectEqual(@as(?usize, 31), findByte(&bytes, 1));
}

test "long one-shot all legal starts threshold and independent alignments" {
    var hstorage: [4097 + 33 + 63]u8 = undefined;
    var nstorage: [4097 + 63]u8 = undefined;
    const offsets = [_]usize{ 0, 1, 15, 16, 31, 32, 63 };
    for ([_]usize{ 32, 33, 63, 64, 65, 4095, 4096, 4097 }) |nlen| {
        for (offsets) |hoff| {
            for (offsets) |noff| {
                const ns = nstorage[noff..][0..nlen];
                @memset(ns, 'a');
                ns[0] = 0;
                ns[nlen - 1] = 'b';
                // Also cross the tiny-haystack boundary for 32/33-byte needles.
                for ([_]usize{ 0, 1, 2, 15, 16, 17, 18, 31, 32, 33 }) |difference| {
                    const hs = hstorage[hoff..][0 .. nlen + difference];
                    for (0..difference + 1) |pos| {
                        @memset(hs, 0xee);
                        @memcpy(hs[pos..][0..nlen], ns);
                        // Alignment changes addresses, not these fully reset slice bytes.
                        if (hoff == 0 and noff == 0)
                            try testing.expectEqual(@as(?usize, pos), oracle(hs, ns));
                        // The unique zero marker permits only the planted start.
                        try testing.expectEqual(@as(?usize, pos), find(hs, ns));
                    }
                }
            }
        }
    }
}

test "long one-shot absence rejects complete match outside logical tail" {
    var hstorage: [4097 + 18 + 64]u8 = @splat(0xa5);
    var nstorage: [4097 + 64]u8 = @splat(0x5a);
    for ([_]usize{ 32, 33, 63, 64, 65, 4095, 4096, 4097 }) |nlen| {
        for (0..64) |hoff| {
            const noff = (hoff * 5 + 1) % 64;
            const ns = nstorage[noff..][0..nlen];
            @memset(ns, 0);
            ns[nlen - 1] = 1;
            for ([_]usize{ 0, 1, 15, 16, 17, 18 }) |difference| {
                const hlen = nlen + difference;
                const hs = hstorage[hoff..][0..hlen];
                @memset(hs, 0);
                // The only complete match starts one byte beyond the legal limit.
                hstorage[hoff + hlen] = 1;
                const hbefore = hstorage;
                const nbefore = nstorage;
                // All alignments contain identical zeros versus a terminal one.
                if (hoff == 0) try testing.expectEqual(@as(?usize, null), oracle(hs, ns));
                try testing.expectEqual(@as(?usize, null), find(hs, ns));
                try testing.expectEqualSlices(u8, &hbefore, &hstorage);
                try testing.expectEqualSlices(u8, &nbefore, &nstorage);
            }
        }
    }
}

test "long one-shot repeated overlapping zero matches and shared storage" {
    var hstorage: [4096 + 18 + 63]u8 = @splat(0xa5);
    var nstorage: [4096 + 63]u8 = @splat(0x5a);
    for ([_]usize{ 32, 33, 64, 4096 }) |nlen| {
        for (0..64) |hoff| {
            const noff = (hoff * 3 + 17) % 64;
            const ns = nstorage[noff..][0..nlen];
            @memset(ns, 0);
            for (0..19) |difference| {
                const hs = hstorage[hoff..][0 .. nlen + difference];
                @memset(hs, 0);
                // Slice bytes are reset identically at every alignment.
                if (hoff == 0) try testing.expectEqual(@as(?usize, 0), oracle(hs, ns));
                try testing.expectEqual(@as(?usize, 0), find(hs, ns));
                hs[0] = 1;
                const expected: ?usize = if (difference == 0) null else 1;
                if (hoff == 0) try testing.expectEqual(expected, oracle(hs, ns));
                try testing.expectEqual(expected, find(hs, ns));
                const shared = hs[difference..][0..nlen];
                const before = hstorage;
                // Identical slices match at zero; a zero-only suffix first matches at one.
                const shared_expected: ?usize = if (difference == 0) 0 else 1;
                if (hoff == 0) try testing.expectEqual(shared_expected, oracle(hs, shared));
                try testing.expectEqual(shared_expected, find(hs, shared));
                try testing.expectEqualSlices(u8, &before, &hstorage);
            }
        }
    }
}
