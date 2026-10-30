//! Model-specific defaults from docs/slop/research/x86_64-design.md, section 5.4.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("fastmem_options");
const cpu = std.Target.x86.cpu;

pub const available = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2);
pub const avx512 = available and builtin.cpu.has(.x86, .avx512bw);
pub const Tuning = struct {
    vec: u32,
    medium_vec: u32,
    abi_alignment: u32,
    medium_first: bool,
    abi_move_max: u32,
    rep_movsb_min: ?u64,
    // Null preserves the measured vector policy for every forward overlap.
    rep_fwd_gap_min: ?u64,
    nt_min: ?u64,
    fwd_source_min: ?u64,
    copy_source_min: ?u64,
    rep_stosb_min: ?u64,
    memset_nt_min: ?u64,
    alias_mask: u64,
    rep_src_align_mask: u64,

    /// The base row, before any per-model override.
    pub const init: Tuning = .{
        .vec = if (avx512) 64 else 32,
        .medium_vec = 64,
        .abi_alignment = 16,
        .medium_first = false,
        .abi_move_max = 512,
        .rep_movsb_min = null,
        .rep_fwd_gap_min = null,
        .nt_min = null,
        .fwd_source_min = null,
        .copy_source_min = null,
        .rep_stosb_min = null,
        // Null keeps the measured temporal fill path.
        .memset_nt_min = null,
        .alias_mask = 0xf00,
        .rep_src_align_mask = 0xe00,
    };
};

/// The knobs a per-model row overrides; a null knob keeps `Tuning.init`.
const Overrides = struct {
    vec: ?u32 = null,
    rep_movsb_min: ?u64 = null,
    nt_min: ?u64 = null,
    fwd_source_min: ?u64 = null,
    copy_source_min: ?u64 = null,
    rep_stosb_min: ?u64 = null,
    memset_nt_min: ?u64 = null,
};

fn model(comptime overrides: Overrides) Tuning {
    return .{
        .vec = overrides.vec orelse Tuning.init.vec,
        .medium_vec = Tuning.init.medium_vec,
        .abi_alignment = Tuning.init.abi_alignment,
        .medium_first = Tuning.init.medium_first,
        .abi_move_max = Tuning.init.abi_move_max,
        .rep_movsb_min = overrides.rep_movsb_min orelse Tuning.init.rep_movsb_min,
        .rep_fwd_gap_min = Tuning.init.rep_fwd_gap_min,
        .nt_min = overrides.nt_min orelse Tuning.init.nt_min,
        .fwd_source_min = overrides.fwd_source_min orelse Tuning.init.fwd_source_min,
        .copy_source_min = overrides.copy_source_min orelse Tuning.init.copy_source_min,
        .rep_stosb_min = overrides.rep_stosb_min orelse Tuning.init.rep_stosb_min,
        .memset_nt_min = overrides.memset_nt_min orelse Tuning.init.memset_nt_min,
        .alias_mask = Tuning.init.alias_mask,
        .rep_src_align_mask = Tuning.init.rep_src_align_mask,
    };
}

// Cache thresholds describe the fleet instance sizes, not every CPU with this model.
const defaults: Tuning = if (builtin.cpu.model == &cpu.sapphirerapids) model(.{
    .rep_movsb_min = 16384,
    .nt_min = 0x3580000,
    .rep_stosb_min = 2048,
    .memset_nt_min = 0x3580000,
}) else if (builtin.cpu.model == &cpu.graniterapids) model(.{
    .rep_movsb_min = 16384,
    .nt_min = 0xf100000,
    .rep_stosb_min = 2048,
    .memset_nt_min = 0xf100000,
}) else if (builtin.cpu.model == &cpu.znver4) model(.{
    // Zen 4 retains temporal stores at exactly 12 MiB. Neither AMD model uses REP.
    .nt_min = 0xc00001,
}) else if (builtin.cpu.model == &cpu.znver5) model(.{
    // Temporal stores win at 16 MiB. NT stores win at 64 MiB.
    // The composite tests a 32 MiB threshold. See docs/slop/results/p3-x86f.md.
    .nt_min = 0x2000000,
    .fwd_source_min = 0xc00001,
    .copy_source_min = 65536,
}) else if (builtin.cpu.model == &cpu.skylake_avx512 or
    builtin.cpu.model == &cpu.cascadelake or
    builtin.cpu.model == &cpu.icelake_client or
    builtin.cpu.model == &cpu.icelake_server) model(.{
    .vec = 32,
}) else Tuning.init;

// The independent two-page NT candidate is confined to Sapphire Rapids.
pub const nt_copy_pages = builtin.cpu.model == &cpu.sapphirerapids and avx512;
pub const nt_set_grouped = builtin.cpu.model == &cpu.znver5 and avx512;

pub const selected: Tuning = .{
    .vec = options.x86_vec orelse defaults.vec,
    .medium_vec = if (variant == .ymm_medium) 32 else defaults.medium_vec,
    .abi_alignment = if (variant == .medium_first) 64 else defaults.abi_alignment,
    .medium_first = variant == .medium_first,
    .abi_move_max = if (variant == .straight_1k) 1024 else defaults.abi_move_max,
    .rep_fwd_gap_min = options.x86_rep_fwd_gap_min orelse defaults.rep_fwd_gap_min,
    .rep_movsb_min = options.x86_rep_movsb_min orelse defaults.rep_movsb_min,
    .nt_min = options.x86_nt_min orelse
        if (temporal_large) 0x4000001 else defaults.nt_min,
    .fwd_source_min = options.x86_fwd_source_min orelse
        if (source_64) 65536 else if (source_early) 1048576 else defaults.fwd_source_min,
    .copy_source_min = options.x86_copy_source_min orelse defaults.copy_source_min,
    .rep_stosb_min = options.x86_rep_stosb_min orelse defaults.rep_stosb_min,
    .memset_nt_min = options.x86_memset_nt_min orelse defaults.memset_nt_min,
    .alias_mask = options.x86_alias_mask orelse defaults.alias_mask,
    .rep_src_align_mask = options.x86_rep_src_align_mask orelse defaults.rep_src_align_mask,
};
// Per-model small/medium selections from the p3-x86e fleet A/B
// (docs/slop/results/p3-x86e.md). `auto` takes the measured winners: medium-entry
// on Granite Rapids, the short-first inline dispatch on Sapphire Rapids. The
// Zen 4 short classes lost at 17-256 B and stay opt-in.
const experiment = options.x86_experiment;
const auto_experiment = switch (experiment) {
    .auto,
    .x86f_pairs,
    .x86f_chunks,
    .x86f_zen4,
    .x86f_source,
    .x86f_dispatch,
    .x86f_temporal,
    .x86f_source64,
    .x86g_temporal,
    .x86g_medium,
    => true,
    else => false,
};
// Fleet candidates retain all unrelated measured selections. auto takes the
// measured winners (docs/slop/results/p3-x86f.md): pairs on GNR, chunks on Intel,
// source+64KiB on Zen 5, temporal below 32 MiB on Zen 5.
// Fleet: x86g-temporal-256 (2026-09-28): c8a set 32 MiB 1.11 -> 0.99.
pub const temporal_set_256 = builtin.cpu.model == &cpu.znver5 and
    (experiment == .auto or experiment == .x86g_temporal);
pub const medium_fallthrough = experiment == .x86g_medium and
    builtin.cpu.model == &cpu.graniterapids;
pub const entry_pairs = builtin.cpu.model == &cpu.graniterapids and
    (auto_experiment or experiment == .x86f_pairs);
pub const medium_chunks = intel_model and
    (auto_experiment or experiment == .x86f_chunks);
pub const zen4_short = experiment == .x86f_zen4 and builtin.cpu.model == &cpu.znver4;
pub const temporal_large = experiment == .x86f_temporal and builtin.cpu.model == &cpu.znver5;
pub const source_64 = builtin.cpu.model == &cpu.znver5 and
    (auto_experiment or experiment == .x86f_source64);
pub const source_early = builtin.cpu.model == &cpu.znver5 and
    (auto_experiment or experiment == .x86f_source64 or experiment == .x86f_source);
pub const dispatch_small_max: u32 = options.x86_dispatch_small_max;
pub const medium_layout = builtin.cpu.model == &cpu.graniterapids and
    experiment == .medium_layout;
pub const medium_entry = builtin.cpu.model == &cpu.graniterapids and
    (auto_experiment or experiment == .medium_entry);
pub const short_scalar = builtin.cpu.model == &cpu.znver4 and
    experiment == .small_paths;
pub const inline_short_first = builtin.cpu.model == &cpu.sapphirerapids and
    (auto_experiment or experiment == .small_paths);
pub const vec = selected.vec;
pub const inline_max = options.x86_inline_max orelse 4 * vec;
// Model gates also apply to explicit experiments. Other CPUs retain their defaults.
// Keep the resolver in build.zig consistent with this table.
// p3-x86d fleet A/B (docs/slop/results/p3-x86d.md): straight_1k on SPR and GNR.
const intel_model = builtin.cpu.model == &cpu.graniterapids or
    builtin.cpu.model == &cpu.sapphirerapids;
const model_variant = if (builtin.cpu.model == &cpu.znver4)
    .tiered
else if (intel_model)
    .straight_1k
else
    .compact;
pub const variant = switch (options.x86_variant) {
    .auto => model_variant,
    .medium_first, .ymm_medium => if (builtin.cpu.model == &cpu.graniterapids)
        options.x86_variant
    else
        model_variant,
    .straight_1k => if (builtin.cpu.model == &cpu.graniterapids or
        builtin.cpu.model == &cpu.sapphirerapids)
        options.x86_variant
    else
        model_variant,
    else => options.x86_variant,
};
pub const high_regs = variant != .entry and avx512 and
    builtin.cpu.has(.x86, .avx512vl) and vec == 64;
pub const reordered = high_regs and variant != .high_regs;
pub const compact_short = variant != .tiered;
pub const small_masked_set = options.x86_small_masked_set;
const base_name: []const u8 = if (reordered)
    "x86-avx512-" ++ @tagName(variant) ++ "-v3"
else if (high_regs)
    "x86-avx512-high-regs-v2"
else if (vec == 64)
    "x86-avx512-entry-v2"
else
    "x86-avx2-entry-v2";

pub const experiment_suffix = switch (experiment) {
    .auto, .none, .medium_layout, .medium_entry, .small_paths => "",
    else => "+" ++ @tagName(experiment),
};
const model_suffix = if (entry_pairs or medium_chunks or
    source_early or source_64 or temporal_large)
    experiment_suffix
else
    "";
pub const name = base_name ++ model_suffix;
pub const set_name = base_name ++ if (medium_chunks) experiment_suffix else "";
pub const move_name = if (entry_pairs and high_regs and builtin.zig_backend == .stage2_llvm)
    name
else
    base_name ++ "+move-pairs-v1" ++ if (zen4_short) experiment_suffix else model_suffix;

comptime {
    if (available) {
        if (selected.rep_fwd_gap_min) |gap| {
            if (gap < 256) @compileError("x86-rep-fwd-gap-min must be at least 256");
        }
        if (vec != 32 and vec != 64) @compileError("x86-vec must be 32 or 64");
        if (vec == 64 and !avx512) @compileError("x86-vec=64 requires AVX-512BW");
        if (inline_max > 8 * vec) @compileError("x86-inline-max exceeds the straight-line classes");
    }
}
