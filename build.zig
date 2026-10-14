const std = @import("std");

const X86Experiment = enum {
    auto,
    none,
    medium_layout,
    medium_entry,
    small_paths,
    x86f_pairs,
    x86f_chunks,
    x86f_zen4,
    x86f_source,
    x86f_dispatch,
    x86f_temporal,
    x86f_source64,
    x86g_temporal,
    x86g_medium,
};

const X86Variant = enum {
    auto,
    entry,
    high_regs,
    tiered,
    compact,
    medium_first,
    ymm_medium,
    straight_1k,
};

// The per-model default of the "auto" variant, from the p3-x86c fleet A/B
// (docs/results/p3-x86c.md). Keep in sync with src/x86_64/tuning.zig.
fn resolveX86Variant(cpu: []const u8, variant: X86Variant) X86Variant {
    const granite = std.mem.eql(u8, cpu, "graniterapids");
    const intel = granite or std.mem.eql(u8, cpu, "sapphirerapids");
    switch (variant) {
        .medium_first, .ymm_medium => if (granite) return variant,
        .straight_1k => if (intel) return variant,
        .auto => {},
        else => return variant,
    }
    // p3-x86d fleet A/B (docs/results/p3-x86d.md): straight_1k on Intel.
    if (intel) return .straight_1k;
    return if (std.mem.eql(u8, cpu, "znver4")) .tiered else .compact;
}

/// The kernel objects of the x86_64 runtime dispatch, one per -Dcpu
/// (docs/runtime-dispatch.md). src/x86_64/cpuid.zig names the same levels.
const dispatch_levels = [_][]const u8{
    "x86_64_v3",     "x86_64_v4", "sapphirerapids",
    "graniterapids", "znver4",    "znver5",
};

/// Every module of src/root.zig in this build gets its options and, for a
/// dispatch target, its level objects from here.
const Fastmem = struct {
    b: *std.Build,
    /// fastmem_options, indexed by [dispatch][access]. `dispatch` is true in
    /// a module that links the level objects. `.test_hooks` enables the test
    /// hooks (`dispatch.force`); the public module never gets it.
    options: [2][2]*std.Build.Step.Options,
    dispatch: bool,
    /// Unique per package instance: see `instanceId`.
    instance: []const u8,
    tuning: Tuning,
    /// Level objects per OS and ABI.
    levels: std.StringHashMapUnmanaged([]const *std.Build.Step.Compile) = .empty,

    const Access = enum { public, test_hooks };

    fn create(b: *std.Build, tuning: Tuning, dispatch: bool) *Fastmem {
        const fm = b.allocator.create(Fastmem) catch @panic("OOM");
        const instance = instanceId(b);
        fm.* = .{
            .b = b,
            .options = undefined,
            .dispatch = dispatch,
            .instance = instance,
            .tuning = tuning,
        };
        for (0..2) |d| for (std.enums.values(Access)) |access| {
            fm.options[d][@intFromEnum(access)] = tuningOptions(b, tuning, .{
                .dispatch = d == 1,
                .test_hooks = access == .test_hooks,
                .instance = instance,
                .resolver_trap = false,
            });
        };
        return fm;
    }

    /// The fastmem_options of a module without dispatch and test hooks.
    fn plain(fm: *const Fastmem) *std.Build.Step.Options {
        return fm.options[0][@intFromEnum(Access.public)];
    }

    /// Keep this rule consistent with `enabled` in src/x86_64/dispatch.zig.
    fn dispatches(fm: *const Fastmem, target: std.Build.ResolvedTarget) bool {
        const t = target.result;
        return fm.dispatch and t.cpu.arch == .x86_64 and t.os.tag == .linux and
            t.ofmt == .elf and !t.cpu.has(.x86, .avx2);
    }

    /// A module of src/root.zig with the settings of the public module.
    fn module(fm: *Fastmem, target: std.Build.ResolvedTarget, access: Access) *std.Build.Module {
        const m = fm.b.createModule(.{
            .root_source_file = fm.b.path("src/root.zig"),
            .target = target,
            .no_builtin = true,
            .omit_frame_pointer = true,
        });
        fm.configure(m, access);
        return m;
    }

    /// Add fastmem_options, and the level objects for a dispatch target.
    /// Module.addObject propagates: every compilation whose module graph
    /// contains this module links the objects.
    fn configure(fm: *Fastmem, m: *std.Build.Module, access: Access) void {
        const target = m.resolved_target.?;
        const dispatch = fm.dispatches(target);
        m.addOptions("fastmem_options", fm.options[@intFromBool(dispatch)][@intFromEnum(access)]);
        if (dispatch) for (fm.levelObjects(target)) |obj| m.addObject(obj);
    }

    fn levelObjects(
        fm: *Fastmem,
        target: std.Build.ResolvedTarget,
    ) []const *std.Build.Step.Compile {
        const b = fm.b;
        const t = target.result;
        const key = b.fmt("{s}-{s}", .{ @tagName(t.os.tag), @tagName(t.abi) });
        if (fm.levels.get(key)) |objects| return objects;
        const objects = b.allocator.alloc(
            *std.Build.Step.Compile,
            dispatch_levels.len,
        ) catch @panic("OOM");
        inline for (dispatch_levels, objects) |name, *object| {
            const level_target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = t.os.tag,
                .abi = t.abi,
                .cpu_model = .{ .explicit = &@field(std.Target.x86.cpu, name) },
            });
            const root = b.createModule(.{
                .root_source_file = b.path("src/x86_64/level.zig"),
                .target = level_target,
                // The kernels are always optimized, also in a Debug consumer.
                .optimize = .ReleaseFast,
                .no_builtin = true,
                .omit_frame_pointer = true,
                // The consumer can be a PIE or a shared library.
                .pic = true,
            });
            root.addOptions("fastmem_options", fm.plain());
            object.* = b.addObject(.{
                .name = "fastmem-x86-" ++ name,
                .root_module = root,
                .use_llvm = true,
            });
        }
        fm.levels.put(b.allocator, key, objects) catch @panic("OOM");
        return objects;
    }
};

/// A hex id that is unique per package instance in a build graph. The x86
/// dispatch symbols contain it, so that two fastmem packages in one link do
/// not collide (docs/runtime-dispatch.md). Zig creates one `std.Build` per
/// build root and user options (`dependencyInner` in std/Build.zig): the id
/// hashes the same key. A fetched package uses its root relative to the
/// global cache, so that the id does not depend on the cache location.
fn instanceId(b: *std.Build) []const u8 {
    var hasher: std.hash.Wyhash = .init(0);
    const root = b.build_root.path orelse ".";
    const global = b.graph.global_cache_root.path orelse "";
    const cached = global.len != 0 and std.mem.startsWith(u8, root, global);
    hasher.update(if (cached) root[global.len..] else root);
    var names: std.ArrayList([]const u8) = .empty;
    var it = b.user_input_options.iterator();
    while (it.next()) |entry| names.append(b.allocator, entry.key_ptr.*) catch @panic("OOM");
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    for (names.items) |name| {
        hasher.update(name);
        hasher.update("=");
        switch (b.user_input_options.get(name).?.value) {
            .scalar => |value| hasher.update(value),
            .list => |list| for (list.items) |item| {
                hasher.update(item);
                hasher.update(",");
            },
            else => |value| hasher.update(@tagName(value)),
        }
        hasher.update(";");
    }
    return b.fmt("{x:0>16}", .{hasher.final()});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.option(bool, "link-libc", "Compatibility option: benchmarks always link libc");
    const rev = b.option(
        []const u8,
        "rev",
        "Revision label reported in bench-fastmem meta records",
    ) orelse "unknown";

    // no_builtin: LLVM must not idiom-recognize fastmem's own loops into
    // memcpy/memset calls (recursion under the export layer).
    // omit_frame_pointer: the C-ABI kernels must not pay x29/x30 prologues
    // where a frame exists (docs/fastmem-plan.md Facts).
    const mod = b.addModule("fastmem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .no_builtin = true,
        .omit_frame_pointer = true,
    });

    const x86_variant = b.option(
        X86Variant,
        "x86-variant",
        "x86 small ABI path (auto = per-model default)",
    ) orelse .auto;
    const x86_dispatch = b.option(
        bool,
        "x86-dispatch",
        "Select the x86 kernels at run time in x86_64 Linux builds without AVX2 (default true)",
    ) orelse true;
    const x86_experiment = b.option(
        X86Experiment,
        "x86-experiment",
        "x86 small/medium selection (auto = per-model winners)",
    ) orelse .auto;
    const fm = Fastmem.create(b, readTuning(b, x86_variant, x86_experiment), x86_dispatch);
    fm.configure(mod, .public);
    const x86_options = fm.plain();

    // Benchmark executable — always built ReleaseFast.
    const bench_opts = b.addOptions();
    // A fixed-size label: the binary layout (and so the code alignment of every
    // kernel) must not depend on the revision name (p3-x86d review P1).
    if (rev.len > 64) @panic("-Drev must be at most 64 bytes");
    var rev_buf: [64]u8 = @splat(0);
    @memcpy(rev_buf[0..rev.len], rev);
    bench_opts.addOption([64]u8, "rev_padded", rev_buf);

    // The C surface of the two bench binaries. Zig 0.16 deprecates @cImport;
    // the headers are translated here and imported as the "c" module.
    const bench_c = b.addTranslateC(.{
        .root_source_file = b.path("src/bench_c.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const probe_c = b.addTranslateC(.{
        .root_source_file = b.path("src/probe_c.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench-fastmem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_fastmem.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "fastmem", .module = mod },
                .{ .name = "bench_options", .module = bench_opts.createModule() },
                .{ .name = "c", .module = bench_c.createModule() },
            },
        }),
    });
    bench_exe.bundle_compiler_rt = true;
    bench_exe.root_module.linkSystemLibrary("dl", .{});
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run fastmem benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);

    const libc_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/libc_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = probe_c.createModule() }},
    });
    if (target.result.os.tag == .linux and target.result.abi.isGnu())
        libc_probe_mod.linkSystemLibrary("dl", .{});

    const libc_probe = b.addExecutable(.{
        .name = "libc-probe",
        .root_module = libc_probe_mod,
    });
    const install_libc_probe = b.addInstallArtifact(libc_probe, .{});
    // `zig build install` ships libc-probe next to bench-fastmem for the
    // selected -Dtarget/-Dcpu, per docs/bench-design.md.
    b.getInstallStep().dependOn(&install_libc_probe.step);
    const libc_probe_step = b.step("libc-probe", "Build the libc symbol probe");
    libc_probe_step.dependOn(&install_libc_probe.step);

    // Match benchmark libc linkage until the kernels remove libc delegation.
    // The guard binary gets a private copy of the public module with the
    // test hooks (--x86-level). The kernels are the same.
    const correctness = b.addExecutable(.{
        .name = "fastmem-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{.{ .name = "fastmem", .module = fm.module(target, .test_hooks) }},
        }),
    });
    const install_correctness = b.addInstallArtifact(correctness, .{});
    b.getInstallStep().dependOn(&install_correctness.step);
    const test_bin = b.step("test-bin", "Install the guard-page correctness binary");
    test_bin.dependOn(&install_correctness.step);
    const guard_cmd = b.addRunArtifact(correctness);
    if (b.args) |args| guard_cmd.addArgs(args);
    b.step("test-guard", "Run the full guard-page matrix").dependOn(&guard_cmd.step);

    const find_guard = b.addExecutable(.{
        .name = "fastmem-find-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/find.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "fastmem", .module = mod }},
        }),
    });
    const install_find_guard = b.addInstallArtifact(find_guard, .{});
    b.getInstallStep().dependOn(&install_find_guard.step);
    b.step("find-test-bin", "Install the search guard binary").dependOn(&install_find_guard.step);
    const find_guard_cmd = b.addRunArtifact(find_guard);
    if (b.args) |args| find_guard_cmd.addArgs(args);
    b.step("test-find-guard", "Run the search guard matrix").dependOn(&find_guard_cmd.step);

    const find_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/find_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fastmem", .module = mod }},
        }),
    });
    const find_unit_cmd = b.addRunArtifact(find_unit);
    b.step("test-find", "Run search unit and fuzz tests").dependOn(&find_unit_cmd.step);
    const install_find_unit = b.addInstallArtifact(find_unit, .{
        .dest_sub_path = "fastmem-find-unit-tests",
    });
    b.step("test-find-unit-bin", "Install search unit tests").dependOn(&install_find_unit.step);

    // Assembly output for codegen inspection.
    addAsmStep(b, fm, target, "asm", "Emit assembly for the current (or -Dtarget) target");

    const asm_all_step = b.step("asm-all", "Emit assembly for all key targets");
    const asm_targets = [_][]const u8{
        "aarch64-linux-gnu",
        "aarch64-linux-musl",
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-macos-none",
    };
    for (asm_targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
        }) catch unreachable);
        const obj = addAsmObject(b, fm, resolved, triple);
        asm_all_step.dependOn(obj);
    }

    // Private cross probes must not replace the public dependency module.
    std.debug.assert(b.modules.get("fastmem").? == mod);
    const probes = addX86Codegen(b, fm, x86_variant, x86_experiment);
    addStdExportTests(b, x86_options);

    // Tests. The fastmem test module takes an explicit optimize so a
    // release-mode test build can dodge the 0.16.0 self-hosted-backend
    // bug in fuzz mode (ziglang/zig#30655) — see the `fuzz` Justfile
    // recipe. The library module itself stays null-optimize and inherits
    // each consumer's mode (ReleaseFast for bench, etc.).
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            // Match the production module so tests build the same code.
            .no_builtin = true,
            .omit_frame_pointer = true,
        }),
    });

    fm.configure(mod_tests.root_module, .test_hooks);

    const unit_install = b.addInstallArtifact(mod_tests, .{
        .dest_sub_path = "fastmem-unit-tests",
    });
    const unit_bin = b.step("test-unit-bin", "Install the unit test binary for cross execution");
    unit_bin.dependOn(&unit_install.step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addExportTests(b, fm, mod));
    test_step.dependOn(addDispatchTests(b, fm, probes));
    // Compile the shipped binaries too: a module-graph error (for example
    // one file imported by two modules) only shows up when they build.
    test_step.dependOn(&bench_exe.step);
    test_step.dependOn(&correctness.step);
    test_step.dependOn(&find_guard.step);
    test_step.dependOn(&find_unit_cmd.step);
    test_step.dependOn(&libc_probe.step);
    test_step.dependOn(&run_mod_tests.step);

    const bench_tests = b.addTest(.{ .root_module = bench_exe.root_module });
    bench_tests.bundle_compiler_rt = true;
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);
}

fn addAsmObject(
    b: *std.Build,
    fm: *Fastmem,
    resolved_target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step {
    // Create a target-specific fastmem module so comptime builtins
    // (cpu.model, cpu.arch, etc.) reflect the cross-compilation target.
    const target_mod = fm.module(resolved_target, .public);

    const obj = b.addObject(.{
        .name = "fastmem-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asm_probe.zig"),
            .target = resolved_target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "fastmem", .module = target_mod },
            },
        }),
    });

    const asm_file = obj.getEmittedAsm();
    const ll_file = obj.getEmittedLlvmIr();

    var asm_name_buf: [64]u8 = undefined;
    const asm_name = std.fmt.bufPrint(&asm_name_buf, "asm/{s}.s", .{name}) catch unreachable;
    var ll_name_buf: [64]u8 = undefined;
    const ll_name = std.fmt.bufPrint(&ll_name_buf, "asm/{s}.ll", .{name}) catch unreachable;

    const install_asm = b.addInstallFile(asm_file, asm_name);
    const install_ll = b.addInstallFile(ll_file, ll_name);

    // Return a step that depends on both installs.
    const group = b.allocator.create(std.Build.Step) catch @panic("OOM");
    group.* = std.Build.Step.init(.{
        .id = .custom,
        .name = name,
        .owner = b,
    });
    group.dependOn(&install_asm.step);
    group.dependOn(&install_ll.step);
    return group;
}

fn addAsmStep(
    b: *std.Build,
    fm: *Fastmem,
    target: std.Build.ResolvedTarget,
    step_name: []const u8,
    description: []const u8,
) void {
    const t = target.result;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}-{s}-{s}", .{
        @tagName(t.cpu.arch),
        @tagName(t.os.tag),
        @tagName(t.abi),
    }) catch unreachable;

    const obj_step = addAsmObject(b, fm, target, name);
    const step = b.step(step_name, description);
    step.dependOn(obj_step);
}

const tuning_u32 = .{ "vec", "inline-max" };
const tuning_u64 = .{
    "rep-movsb-min",   "nt-min",             "rep-stosb-min",   "memset-nt-min",
    "alias-mask",      "rep-src-align-mask", "rep-fwd-gap-min", "fwd-source-min",
    "copy-source-min",
};
const small_ops = .{ "copy", "move", "set" };

/// The tuning build options, read once. Each fastmem_options step writes them.
const Tuning = struct {
    variant: X86Variant,
    experiment: X86Experiment,
    u32s: [tuning_u32.len]?u32,
    u64s: [tuning_u64.len]?u64,
    small: [small_ops.len][]const u8,
    masked_set: bool,
    mid_entry: []const u8,
};

fn dispatchSmallMax(experiment: X86Experiment) u32 {
    return if (experiment == .x86f_dispatch) 64 else 128;
}

fn readTuning(b: *std.Build, variant: X86Variant, experiment: X86Experiment) Tuning {
    var t: Tuning = .{
        .variant = variant,
        .experiment = experiment,
        .u32s = undefined,
        .u64s = undefined,
        .small = undefined,
        .masked_set = undefined,
        .mid_entry = undefined,
    };
    inline for (tuning_u32, &t.u32s) |name, *value| {
        value.* = b.option(u32, "x86-" ++ name, "Override the x86 tuning default");
    }
    inline for (tuning_u64, &t.u64s) |name, *value| {
        value.* = b.option(u64, "x86-" ++ name, "Override the x86 tuning default");
    }
    // aarch64 small-path overrides (src/aarch64/tuning.zig). "auto" keeps
    // the per-CPU-model default; these serve local A/B runs.
    inline for (small_ops, &t.small) |op, *value| {
        value.* = b.option(
            []const u8,
            "small-" ++ op,
            "aarch64 SVE " ++ op ++ " small path: auto|sve|neon|hybrid",
        ) orelse "auto";
    }
    t.mid_entry = b.option(
        []const u8,
        "mid-entry",
        "aarch64 inline >64B calls enter the kernel mid block: auto|on|off",
    ) orelse "auto";
    t.masked_set = b.option(
        bool,
        "x86-small-masked-set",
        "Use masked small memset in LLVM builds",
    ) orelse true;
    return t;
}

const Variant = struct {
    dispatch: bool,
    test_hooks: bool,
    instance: []const u8,
    /// Only the resolver-trap fixture of test-dispatch sets it.
    resolver_trap: bool,
};

fn tuningOptions(b: *std.Build, t: Tuning, v: Variant) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(X86Experiment, "x86_experiment", t.experiment);
    options.addOption(u32, "x86_dispatch_small_max", dispatchSmallMax(t.experiment));
    inline for (tuning_u32, t.u32s) |name, value| {
        options.addOption(?u32, comptime "x86_" ++ replaceDash(name), value);
    }
    inline for (tuning_u64, t.u64s) |name, value| {
        options.addOption(?u64, comptime "x86_" ++ replaceDash(name), value);
    }
    options.addOption(X86Variant, "x86_variant", t.variant);
    inline for (small_ops, t.small) |op, value| {
        options.addOption([]const u8, "small_" ++ op, value);
    }
    options.addOption(bool, "x86_small_masked_set", t.masked_set);
    options.addOption([]const u8, "mid_entry", t.mid_entry);
    // True only in a module that links the level objects (Fastmem.configure).
    options.addOption(bool, "x86_dispatch", v.dispatch);
    // True only in fastmem's own test modules: it enables dispatch.force.
    options.addOption(bool, "x86_test_hooks", v.test_hooks);
    // The dispatch symbol names contain it (Fastmem.instance).
    options.addOption([]const u8, "x86_instance", v.instance);
    // True only in the resolver-trap fixture: every resolver executes ud2.
    options.addOption(bool, "x86_resolver_trap", v.resolver_trap);
    return options;
}

fn replaceDash(comptime name: []const u8) *const [name.len]u8 {
    comptime var result: [name.len]u8 = undefined;
    inline for (name, 0..) |c, i| result[i] = if (c == '-') '_' else c;
    return &result;
}

/// The comptime probes of the codegen gate. The dispatch gate compares
/// each level object with the probe of the same CPU.
const codegen_cpus = [_][]const u8{
    "sapphirerapids", "graniterapids", "znver4", "znver5", "x86_64_v3", "x86_64_v4",
};

fn codegenProbe(b: *std.Build, fm: *Fastmem, cpu: []const u8) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = cpu,
    }) catch unreachable);
    return b.addObject(.{
        .name = b.fmt("probe-{s}", .{cpu}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x86_64/codegen.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .omit_frame_pointer = true,
            .imports = &.{.{ .name = "fastmem", .module = fm.module(target, .public) }},
        }),
    });
}

fn addX86Codegen(
    b: *std.Build,
    fm: *Fastmem,
    variant: X86Variant,
    experiment: X86Experiment,
) [codegen_cpus.len]*std.Build.Step.Compile {
    const step = b.step(
        "codegen-x86",
        "Check x86 vector widths, ABI entries, and symbol independence",
    );
    var probes: [codegen_cpus.len]*std.Build.Step.Compile = undefined;
    for (codegen_cpus, &probes) |cpu, *probe| {
        const obj = codegenProbe(b, fm, cpu);
        probe.* = obj;
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/x86_64/check_codegen.py"));
        check.addArg(cpu);
        check.addArg(@tagName(resolveX86Variant(cpu, variant)));
        check.addFileArg(obj.getEmittedBin());
        check.addArgs(&.{ "--experiment", @tagName(experiment) });
        step.dependOn(&check.step);
        if (std.mem.eql(u8, cpu, "sapphirerapids") or std.mem.eql(u8, cpu, "graniterapids") or
            std.mem.eql(u8, cpu, "znver4") or std.mem.eql(u8, cpu, "znver5"))
        {
            const mutations = b.addSystemCommand(&.{"python3"});
            mutations.addFileArg(b.path("src/x86_64/test_check_codegen.py"));
            mutations.addArg(cpu);
            mutations.addArg(@tagName(resolveX86Variant(cpu, variant)));
            mutations.addFileArg(obj.getEmittedBin());
            mutations.addArgs(&.{ "--experiment", @tagName(experiment) });
            step.dependOn(&mutations.step);
        }
        const install = b.addInstallFile(obj.getEmittedBin(), b.fmt("codegen/{s}.o", .{cpu}));
        step.dependOn(&install.step);
    }
    return probes;
}

/// The runtime-dispatch gate (docs/runtime-dispatch.md): the stub shape and
/// the inline classes of a baseline build, the equality of each level object
/// with the comptime kernel for its CPU, and the unit tests under qemu.
fn addDispatchTests(
    b: *std.Build,
    fm: *Fastmem,
    probes: [codegen_cpus.len]*std.Build.Step.Compile,
) *std.Build.Step {
    const step = b.step("test-dispatch", "Check the x86_64 runtime dispatch of baseline builds");
    const target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = "x86_64",
    }) catch unreachable);
    if (!fm.dispatches(target)) return step;
    const probe = codegenProbe(b, fm, "x86_64");
    const check = b.addSystemCommand(&.{"python3"});
    check.addFileArg(b.path("src/x86_64/check_dispatch.py"));
    check.addArg(b.fmt("fastmem_x86_{s}_", .{fm.instance}));
    check.addFileArg(probe.getEmittedBin());
    check.addArg(b.fmt("{d}", .{dispatchSmallMax(fm.tuning.experiment)}));
    for (dispatch_levels, fm.levelObjects(target)) |level, object| {
        const comptime_probe = for (codegen_cpus, probes) |cpu, p| {
            if (std.mem.eql(u8, cpu, level)) break p;
        } else unreachable;
        check.addArg(level);
        check.addFileArg(object.getEmittedBin());
        check.addFileArg(comptime_probe.getEmittedBin());
    }
    step.dependOn(&check.step);
    const install = b.addInstallFile(probe.getEmittedBin(), "codegen/x86_64-dispatch.o");
    step.dependOn(&install.step);

    const probe_exe = b.addExecutable(.{
        .name = "dispatch-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x86_64/dispatch_probe.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "fastmem", .module = fm.module(target, .public) }},
        }),
    });
    const run_probe = b.addSystemCommand(&.{"python3"});
    run_probe.addFileArg(b.path("src/x86_64/run_dispatch.py"));
    run_probe.addArg("--probe");
    run_probe.addFileArg(probe_exe.getEmittedBin());
    step.dependOn(&run_probe.step);

    // The configured ABI limit separates local classes from resolver calls.
    // Trap resolvers prove this boundary without target-specific instructions.
    // A static musl binary runs under qemu.
    const musl = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-musl",
        .cpu_features = "x86_64",
    }) catch unreachable);
    const trap_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = musl,
        .no_builtin = true,
        .omit_frame_pointer = true,
    });
    trap_module.addOptions("fastmem_options", tuningOptions(b, fm.tuning, .{
        .dispatch = true,
        .test_hooks = false,
        .instance = fm.instance,
        .resolver_trap = true,
    }));
    for (fm.levelObjects(musl)) |obj| trap_module.addObject(obj);
    const trap_exe = b.addExecutable(.{
        .name = "dispatch-small-trap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x86_64/dispatch_small.zig"),
            .target = musl,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "fastmem", .module = trap_module }},
        }),
    });
    const run_trap = b.addSystemCommand(&.{"python3"});
    run_trap.addFileArg(b.path("src/x86_64/run_dispatch.py"));
    run_trap.addArg("--resolver-trap");
    run_trap.addArgs(&.{ "--small-max", b.fmt("{d}", .{dispatchSmallMax(fm.tuning.experiment)}) });
    run_trap.addFileArg(trap_exe.getEmittedBin());
    step.dependOn(&run_trap.step);
    for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .Debug }) |mode| {
        const tests_module = fm.module(target, .test_hooks);
        tests_module.optimize = mode;
        const tests = b.addTest(.{
            .name = b.fmt("dispatch-unit-{s}", .{@tagName(mode)}),
            .root_module = tests_module,
        });
        const run = b.addSystemCommand(&.{"python3"});
        run.addFileArg(b.path("src/x86_64/run_dispatch.py"));
        run.addFileArg(tests.getEmittedBin());
        step.dependOn(&run.step);
    }
    return step;
}

/// The dispatch test hook stays out of the public module, and two package
/// instances link together (docs/runtime-dispatch.md).
fn addPackageTests(b: *std.Build, fm: *Fastmem, public: *std.Build.Module) *std.Build.Step {
    const step = b.step("test-export-packages", "Check the package boundary of the x86 dispatch");
    const baseline = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = "x86_64",
    }) catch unreachable);
    const Row = struct { name: []const u8, module: *std.Build.Module };
    for ([_]Row{
        // The public module itself, for the -Dtarget of this build.
        .{ .name = "public", .module = public },
        // The public configuration of a dispatching baseline consumer.
        .{ .name = "x86_64-dispatch", .module = fm.module(baseline, .public) },
    }) |row| {
        const exe = b.addExecutable(.{
            .name = b.fmt("hooks-{s}", .{row.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/export/hooks.zig"),
                .target = row.module.resolved_target.?,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "fastmem", .module = row.module }},
            }),
        });
        exe.expect_errors = .{
            .contains = "error: fastmem.dispatch.force is a test hook; " ++
                "the public fastmem module does not provide it",
        };
        step.dependOn(&exe.step);
    }
    const two = b.addSystemCommand(&.{"python3"});
    two.addFileArg(b.path("src/export/two_packages.py"));
    two.addArg(b.graph.zig_exe);
    two.addArg(b.pathFromRoot("."));
    two.addArg(b.cache_root.join(b.allocator, &.{"fastmem-two-packages"}) catch @panic("OOM"));
    two.setCwd(b.path("."));
    step.dependOn(&two.step);
    return step;
}

fn addExportTests(b: *std.Build, fm: *Fastmem, public: *std.Build.Module) *std.Build.Step {
    const step = b.step("test-export", "Check opt-in memory symbols in linked ELF binaries");
    step.dependOn(addPackageTests(b, fm, public));
    step.dependOn(addExportCollisionTests(b, fm));
    step.dependOn(addArmByteTests(b));
    step.dependOn(addGenericSetTests(b, fm));
    inline for (.{ "test_runtime.py", "test_audit.py" }) |script| {
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/" ++ script));
        step.dependOn(&check.step);
    }
    step.dependOn(addExportRecursionTests(b, fm));
    const linux_host = b.graph.host.result.os.tag == .linux;
    // x86_64 baseline (no AVX2) exports the runtime-dispatch entries.
    const Row = struct { arch: []const u8, cpu: []const u8, label: []const u8 };
    for ([_]Row{
        .{ .arch = "aarch64", .cpu = "generic", .label = "aarch64" },
        .{ .arch = "x86_64", .cpu = "x86_64_v3", .label = "x86_64" },
        .{ .arch = "x86_64", .cpu = "x86_64", .label = "x86_64-dispatch" },
    }) |row| {
        const arch = row.arch;
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = row.cpu,
        }) catch unreachable);
        for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSafe }) |mode| {
            for ([_]bool{ false, true }) |libc| {
                for ([_]bool{ false, true }) |division| {
                    const name = b.fmt("export-{s}-{s}-libc{d}-div{d}", .{
                        row.label, @tagName(mode), @intFromBool(libc), @intFromBool(division),
                    });
                    const fixture = exportFixture(b, fm, target, mode, libc, division, true);
                    const exe = b.addExecutable(.{ .name = name, .root_module = fixture });
                    const check = b.addSystemCommand(&.{"python3"});
                    check.addFileArg(b.path("src/export/check.py"));
                    check.addArgs(&.{
                        "--arch", arch, "--division", if (division) "yes" else "no",
                    });
                    if (!libc and linux_host) check.addArg("--run");
                    check.addFileArg(exe.getEmittedBin());
                    step.dependOn(&check.step);
                }
            }
        }
        for ([_]bool{ false, true }) |enabled| {
            const mode: std.builtin.OptimizeMode = if (enabled) .Debug else .ReleaseFast;
            const fixture = exportFixture(b, fm, target, mode, false, true, enabled);
            const exe = b.addExecutable(.{
                .name = b.fmt("export-{s}-{s}", .{
                    row.label, if (enabled) "debug-llvm" else "disabled",
                }),
                .root_module = fixture,
                .use_llvm = true,
            });
            const check = b.addSystemCommand(&.{"python3"});
            check.addFileArg(b.path("src/export/check.py"));
            check.addArgs(&.{ "--arch", arch, "--division", "yes" });
            if (linux_host) check.addArg("--run");
            if (!enabled) check.addArg("--disabled");
            check.addFileArg(exe.getEmittedBin());
            step.dependOn(&check.step);
        }
        // The builtin lowering probe does not import fastmem: one per arch.
        if (!std.mem.eql(u8, row.cpu, "x86_64")) {
            const debug = b.addObject(.{
                .name = b.fmt("export-debug-lowering-{s}", .{arch}),
                .use_llvm = false,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/export/debug.zig"),
                    .target = target,
                    .optimize = .Debug,
                }),
            });
            const debug_check = b.addSystemCommand(&.{"python3"});
            debug_check.addFileArg(b.path("src/export/check_debug.py"));
            debug_check.addArg(arch);
            debug_check.addFileArg(debug.getEmittedBin());
            step.dependOn(&debug_check.step);
        }
        const refused = b.addObject(.{
            .name = b.fmt("export-refused-{s}", .{row.label}),
            .use_llvm = false,
            .root_module = exportFixture(b, fm, target, .Debug, false, false, true),
        });
        refused.expect_errors = .{
            .contains = "fastmem.exportSymbols requires the LLVM backend (use -fllvm in Debug)",
        };
        step.dependOn(&refused.step);
        const strong = b.addObject(.{
            .name = b.fmt("export-strong-{s}", .{row.label}),
            .root_module = exportFixture(b, fm, target, .ReleaseFast, false, true, true),
        });
        const strong_check = b.addSystemCommand(&.{"python3"});
        strong_check.addFileArg(b.path("src/export/check_object.py"));
        strong_check.addFileArg(strong.getEmittedBin());
        step.dependOn(&strong_check.step);
        // Dynamic executable and DSO: hidden definitions must stay local in both.
        const Link = enum { dynamic, shared, shared_no_rt };
        for ([_]Link{ .dynamic, .shared, .shared_no_rt }) |kind| {
            const shared = kind != .dynamic;
            const division = kind != .shared_no_rt;
            const fixture = exportFixture(b, fm, target, .ReleaseFast, true, division, true);
            const artifact = if (shared)
                b.addLibrary(.{
                    .name = b.fmt("export-{s}-{s}", .{ @tagName(kind), row.label }),
                    .root_module = fixture,
                    .linkage = .dynamic,
                })
            else
                b.addExecutable(.{
                    .name = b.fmt("export-dynamic-{s}", .{row.label}),
                    .root_module = fixture,
                });
            const check = b.addSystemCommand(&.{"python3"});
            check.addFileArg(b.path("src/export/check.py"));
            check.addArgs(&.{ "--arch", arch, "--division", if (division) "yes" else "no" });
            if (kind == .shared_no_rt) artifact.bundle_compiler_rt = false;
            if (shared) check.addArg("--shared");
            check.addFileArg(artifact.getEmittedBin());
            step.dependOn(&check.step);
        }
    }
    for ([_][]const u8{ "neoverse_v1", "neoverse_v2", "neoverse_v3", "x86_64" }) |cpu| {
        const arch = if (std.mem.eql(u8, cpu, "x86_64")) "x86_64" else "aarch64";
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = cpu,
        }) catch unreachable);
        const exe = b.addExecutable(.{
            .name = b.fmt("export-{s}", .{cpu}),
            .root_module = exportFixture(b, fm, target, .ReleaseFast, false, true, true),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check.py"));
        check.addArgs(&.{ "--arch", arch, "--division", "yes" });
        if (linux_host and std.mem.eql(u8, cpu, "x86_64")) check.addArg("--run");
        check.addFileArg(exe.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

fn exportFixture(
    b: *std.Build,
    fm: *Fastmem,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    libc: bool,
    division: bool,
    enabled: bool,
) *std.Build.Module {
    const kernel = fm.module(target, .public);
    const options = b.addOptions();
    options.addOption(bool, "division", division);
    options.addOption(bool, "enabled", enabled);
    const fixture = b.createModule(.{
        .root_source_file = b.path("src/export/consumer.zig"),
        .target = target,
        .optimize = mode,
        .link_libc = libc,
        .imports = &.{.{ .name = "fastmem", .module = kernel }},
    });
    fixture.addOptions("export_options", options);
    fixture.addCSourceFile(.{
        .file = b.path("src/export/consumer.c"),
        .flags = &.{ "-fno-builtin", "-fno-stack-protector" },
    });
    return fixture;
}

fn addStdExportTests(b: *std.Build, tuning: *std.Build.Step.Options) void {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("src/export/std_tests.py"));
    run.addArg(b.graph.zig_exe);
    run.addArg(b.graph.zig_lib_directory.path.?);
    run.addFileArg(b.path("src/root.zig"));
    run.addFileArg(tuning.getOutput());
    const step = b.step("test-export-std", "Check upstream std tests with memory exports");
    step.dependOn(&run.step);
}

fn addExportCollisionTests(b: *std.Build, fm: *Fastmem) *std.Build.Step {
    const step = b.step("test-export-collisions", "Reject competing memory definitions");
    for ([_][]const u8{ "generic", "neoverse_v3", "x86_64_v3", "x86_64" }) |cpu| {
        const arch = if (std.mem.startsWith(u8, cpu, "x86_64")) "x86_64" else "aarch64";
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = cpu,
        }) catch unreachable);
        const kernel = fm.module(target, .public);
        const Kind = enum { strong, weak, default, compiler_rt };
        for ([_]Kind{ .strong, .weak, .default, .compiler_rt }) |kind| {
            for ([_][]const u8{ "memcpy", "memmove", "memset" }) |symbol| {
                const options = b.addOptions();
                options.addOption(Kind, "kind", kind);
                options.addOption([]const u8, "symbol", symbol);
                const fixture = b.createModule(.{
                    .root_source_file = b.path("src/export/collision.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{.{ .name = "fastmem", .module = kernel }},
                });
                fixture.addOptions("collision_options", options);
                const obj = b.addObject(.{
                    .name = b.fmt("collision-{s}-{s}-{s}", .{
                        cpu, symbol, @tagName(kind),
                    }),
                    .root_module = fixture,
                });
                if (kind == .compiler_rt) obj.bundle_compiler_rt = true;
                obj.expect_errors = .{
                    .contains = b.fmt("exported symbol collision: {s}", .{symbol}),
                };
                step.dependOn(&obj.step);
            }
        }
    }
    return step;
}

fn addGenericSetTests(b: *std.Build, fm: *Fastmem) *std.Build.Step {
    const step = b.step("test-generic-set", "The generic memset has no byte-store loop (issue #1)");
    for ([_][]const u8{"x86_64-linux-gnu"}) |triple| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
            .cpu_features = "baseline",
        }) catch unreachable);
        // The generic kernels are the dispatch level `generic` in this build.
        const kernel = fm.module(target, .public);
        const obj = b.addObject(.{
            .name = b.fmt("generic-set-{s}", .{triple}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/export/kernel_bytes.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "fastmem", .module = kernel }},
            }),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check_generic_set.py"));
        check.addFileArg(obj.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

fn addArmByteTests(b: *std.Build) *std.Build.Step {
    const step = b.step("test-export-arm-bytes", "Pin measured aarch64 kernel instruction bytes");
    const defaults = b.addOptions();
    inline for (.{ "copy", "move", "set" }) |op| {
        defaults.addOption([]const u8, "small_" ++ op, "auto");
    }
    for ([_][]const u8{ "generic", "neoverse_v1", "neoverse_v2", "neoverse_v3" }) |cpu| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = "aarch64-linux-gnu",
            .cpu_features = cpu,
        }) catch unreachable);
        const kernel = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .no_builtin = true,
        });
        kernel.addOptions("fastmem_options", defaults);
        const obj = b.addObject(.{
            .name = b.fmt("kernel-bytes-{s}", .{cpu}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/export/kernel_bytes.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "fastmem", .module = kernel }},
            }),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check_kernel_bytes.py"));
        check.addArg(cpu);
        check.addFileArg(obj.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

fn addExportRecursionTests(b: *std.Build, fm: *Fastmem) *std.Build.Step {
    const step = b.step(
        "test-export-recursion",
        "Audit std helpers and local intrinsic suppression",
    );
    const target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = "x86_64",
    }) catch unreachable);
    const bad = b.addExecutable(.{
        .name = "export-recursive-std",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export/recursion.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const reject = b.addSystemCommand(&.{"python3"});
    reject.addFileArg(b.path("src/export/check_recursion_fixture.py"));
    reject.addFileArg(bad.getEmittedBin());
    step.dependOn(&reject.step);
    for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSafe, .Debug }) |mode| {
        const fixture = exportFixture(b, fm, target, mode, false, true, true);
        // Prove that each fallback also resists intrinsic formation locally.
        fixture.import_table.get("fastmem").?.no_builtin = false;
        const exe = b.addExecutable(.{
            .name = b.fmt("export-local-suppression-{s}", .{@tagName(mode)}),
            .root_module = fixture,
            .use_llvm = true,
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check.py"));
        check.addArgs(&.{ "--arch", "x86_64", "--division", "yes" });
        if (b.graph.host.result.os.tag == .linux) check.addArg("--run");
        check.addFileArg(exe.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}
