//! Level selection for the x86_64 runtime dispatch, from CPUID and XCR0
//! values. This file is pure logic: it compiles and tests on every host,
//! with synthetic register values. dispatch.zig reads the real registers.
//!
//! The model table mirrors the Zig 0.16 host detection
//! (lib/std/zig/system/x86.zig, MIT) for the models that fastmem tunes.
//! A level is the -Dcpu of one kernel object. A host runs the object that
//! a comptime build for its own model selects in tuning.zig.
const std = @import("std");
const testing = std.testing;

pub const Level = enum(u8) {
    /// The generic Zig kernels, compiled for the consumer CPU.
    generic,
    /// The AVX2 kernels. Also the 32-byte-vector row of tuning.zig for
    /// Skylake-SP, Cascade Lake, and Ice Lake.
    x86_64_v3,
    /// The AVX-512 kernels without model tuning: no REP, no NT stores.
    x86_64_v4,
    sapphirerapids,
    graniterapids,
    znver4,
    znver5,

    /// The CPU features that the kernel object of this level requires.
    pub fn requires(level: Level) Isa {
        @disableIntrinsics();
        return switch (level) {
            .generic => .baseline,
            .x86_64_v3 => .v3,
            else => .v4,
        };
    }
};

/// The instruction-set levels that the dispatcher checks. A model object
/// requires v4. The model match comes from the vendor, family, and model.
pub const Isa = enum { baseline, v3, v4 };

pub const Vendor = enum { intel, amd, other };

/// The raw CPUID and XCR0 values that the selection reads.
pub const Raw = struct {
    /// CPUID.0:EBX, the first four bytes of the vendor string.
    vendor_ebx: u32,
    /// CPUID.1:EAX, the processor signature.
    leaf1_eax: u32,
    leaf1_ecx: u32,
    /// CPUID.(EAX=7,ECX=0):EBX. Zero when the maximum leaf is below 7.
    leaf7_ebx: u32,
    /// CPUID.80000001H:ECX. Zero when the extended leaf is absent.
    ext1_ecx: u32,
    /// Zero when CPUID.1:ECX.OSXSAVE is clear: XGETBV is then undefined.
    xcr0: u64,
};

pub const Info = struct {
    vendor: Vendor,
    /// The display family and model (base plus extended fields).
    family: u32,
    model: u32,
    features: Mask,

    pub fn decode(raw: Raw) Info {
        @disableIntrinsics();
        const base_family = (raw.leaf1_eax >> 8) & 0xf;
        const extended = base_family == 0xf;
        const extended_model = if (extended or base_family == 6) (raw.leaf1_eax >> 16) & 0xf else 0;
        return .{
            .vendor = switch (raw.vendor_ebx) {
                0x756e6547 => .intel, // "Genu"
                0x68747541 => .amd, // "Auth"
                else => .other,
            },
            .family = base_family + if (extended) (raw.leaf1_eax >> 20) & 0xff else 0,
            .model = (raw.leaf1_eax >> 4) & 0xf | extended_model << 4,
            .features = .{
                .leaf1_ecx = raw.leaf1_ecx,
                .leaf7_ebx = raw.leaf7_ebx,
                .ext1_ecx = raw.ext1_ecx,
                .xcr0 = raw.xcr0,
            },
        };
    }

    pub fn has(info: Info, isa: Isa) bool {
        @disableIntrinsics();
        const mask = switch (isa) {
            .baseline => return true,
            .v3 => v3,
            .v4 => v4,
        };
        return info.features.contains(mask);
    }

    pub fn supports(info: Info, level: Level) bool {
        @disableIntrinsics();
        return info.has(level.requires());
    }

    pub fn select(info: Info) Level {
        @disableIntrinsics();
        if (!info.has(.v3)) return .generic;
        if (!info.has(.v4)) return .x86_64_v3;
        return switch (info.vendor) {
            .intel => if (info.family != 6) .x86_64_v4 else switch (info.model) {
                0x8f => .sapphirerapids,
                0xad => .graniterapids,
                // skylake_avx512, cascadelake, cooperlake (0x55), and
                // icelake_server/client: tuning.zig uses 32-byte vectors.
                // The dispatcher does not read the stepping, so Cooper Lake
                // also takes this row.
                0x55, 0x6a, 0x6c, 0x7d, 0x7e => .x86_64_v3,
                else => .x86_64_v4,
            },
            .amd => switch (info.family) {
                0x19 => switch (info.model) {
                    0x10...0x1f, 0x60...0x6f, 0x70...0x7f, 0xa0...0xaf => .znver4,
                    else => .x86_64_v4,
                },
                0x1a => .znver5,
                else => .x86_64_v4,
            },
            .other => .x86_64_v4,
        };
    }
};

/// Feature bits in the CPUID registers and XCR0.
pub const Mask = struct {
    leaf1_ecx: u32,
    leaf7_ebx: u32,
    ext1_ecx: u32,
    xcr0: u64,

    fn contains(have: Mask, want: Mask) bool {
        @disableIntrinsics();
        return have.leaf1_ecx & want.leaf1_ecx == want.leaf1_ecx and
            have.leaf7_ebx & want.leaf7_ebx == want.leaf7_ebx and
            have.ext1_ecx & want.ext1_ecx == want.ext1_ecx and
            have.xcr0 & want.xcr0 == want.xcr0;
    }
};

fn bits(comptime positions: []const u5) u32 {
    var mask: u32 = 0;
    for (positions) |p| mask |= @as(u32, 1) << p;
    return mask;
}

/// x86-64-v3, as LLVM and Zig define the x86_64_v3 CPU: the v2 set plus
/// AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, and XSAVE.
const v3: Mask = .{
    // SSE3, SSSE3, FMA, CX16, SSE4.1, SSE4.2, MOVBE, POPCNT, XSAVE,
    // OSXSAVE, AVX, F16C.
    .leaf1_ecx = bits(&.{ 0, 9, 12, 13, 19, 20, 22, 23, 26, 27, 28, 29 }),
    // BMI1, AVX2, BMI2.
    .leaf7_ebx = bits(&.{ 3, 5, 8 }),
    // LAHF/SAHF, LZCNT.
    .ext1_ecx = bits(&.{ 0, 5 }),
    // The OS saves the SSE and AVX (YMM upper) state.
    .xcr0 = 0b110,
};

/// x86-64-v4: v3 plus AVX512F, AVX512DQ, AVX512CD, AVX512BW, AVX512VL.
const v4: Mask = .{
    .leaf1_ecx = v3.leaf1_ecx,
    .leaf7_ebx = v3.leaf7_ebx | bits(&.{ 16, 17, 28, 30, 31 }),
    .ext1_ecx = v3.ext1_ecx,
    // Also the opmask, ZMM_Hi256, and Hi16_ZMM state.
    .xcr0 = v3.xcr0 | 0b1110_0000,
};

// Synthetic hosts. The model numbers of the fleet come from
// docs/slop/research/hosts/*/lscpu.txt.
fn host(vendor: Vendor, family: u32, model: u32) Info {
    return .{ .vendor = vendor, .family = family, .model = model, .features = v4 };
}

test "dispatch: the fleet models select their comptime tuning rows" {
    try testing.expectEqual(Level.sapphirerapids, host(.intel, 6, 143).select()); // c7i
    try testing.expectEqual(Level.graniterapids, host(.intel, 6, 173).select()); // c8i
    try testing.expectEqual(Level.znver4, host(.amd, 25, 17).select()); // c7a
    try testing.expectEqual(Level.znver5, host(.amd, 26, 2).select()); // c8a
}

test "dispatch: other AVX-512 models take the untuned or 32-byte rows" {
    try testing.expectEqual(Level.x86_64_v4, host(.intel, 6, 0xcf).select()); // Emerald Rapids
    try testing.expectEqual(Level.x86_64_v4, host(.intel, 6, 0xae).select()); // Granite Rapids-D
    try testing.expectEqual(Level.x86_64_v4, host(.intel, 19, 1).select()); // a future family
    try testing.expectEqual(Level.x86_64_v3, host(.intel, 6, 0x55).select()); // Skylake-SP
    try testing.expectEqual(Level.x86_64_v3, host(.intel, 6, 0x6a).select()); // Ice Lake-SP
    // A Zen 3 model number with the AVX-512 bits set.
    try testing.expectEqual(Level.x86_64_v4, host(.amd, 25, 0x01).select());
    try testing.expectEqual(Level.x86_64_v4, host(.amd, 27, 0).select());
    try testing.expectEqual(Level.x86_64_v4, host(.other, 6, 0x8f).select());
}

test "dispatch: a missing feature or OS state lowers the level" {
    // The OS does not save the ZMM state: AVX-512 is not usable.
    var info = host(.intel, 6, 143);
    info.features.xcr0 = v3.xcr0;
    try testing.expectEqual(Level.x86_64_v3, info.select());
    // AVX512VL off (the high-register kernels use ymm16-31).
    info = host(.amd, 26, 2);
    info.features.leaf7_ebx &= ~bits(&.{31});
    try testing.expectEqual(Level.x86_64_v3, info.select());
    // BMI2 off: the v3 objects can contain BMI2 instructions.
    info.features.leaf7_ebx &= ~bits(&.{8});
    try testing.expectEqual(Level.generic, info.select());
    // OSXSAVE clear: dispatch.zig does not execute XGETBV and passes 0.
    info = host(.intel, 6, 143);
    info.features.leaf1_ecx &= ~bits(&.{27});
    info.features.xcr0 = 0;
    try testing.expectEqual(Level.generic, info.select());
    // No LZCNT (CPUID.80000001H:ECX.ABM).
    info = host(.amd, 25, 17);
    info.features.ext1_ecx = 0;
    try testing.expectEqual(Level.generic, info.select());
    try testing.expect(!info.supports(.x86_64_v3));
    try testing.expect(info.supports(.generic));
}

test "dispatch: AVX2 hosts without AVX-512 select x86_64_v3" {
    var info = host(.intel, 6, 0x97); // Alder Lake
    info.features.leaf7_ebx = v3.leaf7_ebx;
    info.features.xcr0 = v3.xcr0;
    try testing.expectEqual(Level.x86_64_v3, info.select());
    try testing.expect(info.supports(.x86_64_v3));
    try testing.expect(!info.supports(.sapphirerapids));
    info = host(.amd, 25, 0x21); // Zen 3
    info.features.leaf7_ebx = v3.leaf7_ebx;
    try testing.expectEqual(Level.x86_64_v3, info.select());
}

test "dispatch: the signature decodes the display family and model" {
    const raw: Raw = .{
        .vendor_ebx = 0x756e6547,
        .leaf1_eax = 0x000806f8, // c7i
        .leaf1_ecx = v4.leaf1_ecx,
        .leaf7_ebx = v4.leaf7_ebx,
        .ext1_ecx = v4.ext1_ecx,
        .xcr0 = v4.xcr0,
    };
    const c7i: Info = .decode(raw);
    try testing.expectEqual(Vendor.intel, c7i.vendor);
    try testing.expectEqual(@as(u32, 6), c7i.family);
    try testing.expectEqual(@as(u32, 143), c7i.model);
    try testing.expectEqual(Level.sapphirerapids, c7i.select());
    var other = raw;
    other.leaf1_eax = 0x000a06d1; // c8i
    try testing.expectEqual(Level.graniterapids, Info.decode(other).select());
    other.vendor_ebx = 0x68747541;
    other.leaf1_eax = 0x00a10f11; // c7a
    const c7a: Info = .decode(other);
    try testing.expectEqual(Vendor.amd, c7a.vendor);
    try testing.expectEqual(@as(u32, 25), c7a.family);
    try testing.expectEqual(@as(u32, 17), c7a.model);
    try testing.expectEqual(Level.znver4, c7a.select());
    other.leaf1_eax = 0x00b00f21; // c8a
    const c8a: Info = .decode(other);
    try testing.expectEqual(@as(u32, 26), c8a.family);
    try testing.expectEqual(@as(u32, 2), c8a.model);
    try testing.expectEqual(Level.znver5, c8a.select());
    // Family 6 without the extended family field, model with extension.
    other.vendor_ebx = 0x6f6f6f6f;
    other.leaf1_eax = 0x000506e3;
    const unknown: Info = .decode(other);
    try testing.expectEqual(Vendor.other, unknown.vendor);
    try testing.expectEqual(@as(u32, 0x5e), unknown.model);
    try testing.expectEqual(Level.x86_64_v4, unknown.select());
}
