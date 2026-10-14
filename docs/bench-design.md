# Benchmark system design

This document is the contract for the benchmark system. It replaces
`infra/bench.nu`, the OrbStack target, and the per-box build flow.
Three components implement it: the infrastructure (`infra/`), the
harness (`bench/`), and the measurement binary (`src/bench_fastmem.zig`).
Each component owns its own files. The interfaces between them are
fixed here. Change an interface in this file first, then in the code.

## Goals

1. A benchmark loop that takes minutes: build, ship, run, analyze.
2. Parallel runs across all CPU families, with one command.
3. Results that are repeatable and that record their full provenance.
4. A noise floor that is measured on every run, not assumed.
5. An agent can operate the fleet without a human, and cannot leak money.
6. The generic parts are copyable into other projects (for example
   `~/code/handoff`) without edits.

## Non-goals

- A custom AMI. The official NixOS AMI plus `user_data` is enough for now.
- Multi-region. The fleet is `us-west-2` only.
- A results database. Results are files on the local disk.
- Spot instances. On-demand only.
- Benchmarks of revisions that predate this design. Their binaries do
  not emit the JSONL schema.

## Core decisions

- **Build locally, ship binaries.** The harness cross-compiles every
  binary on the dev machine with Zig. A box receives only binaries. A box
  has no Zig, no repository, and no `nix develop` step.
- **Explicit CPU models.** Each target has an explicit `-Dcpu` value.
  The harness never builds with `native`.
- **State lives in AWS tags.** The harness has no local state file. It
  finds instances by tag. Two harness processes can run at the same time.
- **OpenTofu owns only durable resources.** OpenTofu creates the IAM user,
  the security group, the key pair, and the launch templates. The harness
  launches and terminates instances through the EC2 API.
- **Boxes destroy themselves.** Every instance has an `ExpiresAt` tag.
  A timer on the box powers it off after that time. The launch template
  sets shutdown behavior to `terminate`.

## Targets

| Target | Instance type | ISA | Zig target | `-Dcpu` |
|---|---|---|---|---|
| `c7i` | `c7i.xlarge` | x86_64 | `x86_64-linux-gnu` | `sapphirerapids` |
| `c8i` | `c8i.xlarge` | x86_64 | `x86_64-linux-gnu` | `graniterapids` |
| `c7a` | `c7a.xlarge` | x86_64 | `x86_64-linux-gnu` | `znver4` |
| `c8a` | `c8a.xlarge` | x86_64 | `x86_64-linux-gnu` | `znver5` |
| `c7g` | `c7g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v1` |
| `c8g` | `c8g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v2` |
| `c9g` | `c9g.xlarge` | aarch64 | `aarch64-linux-gnu` | `neoverse_v3` |

The `-Dcpu` value for `c9g` is unverified. The host facts step records
the real core, and a human corrects the table if it is wrong.

Intel families have two threads for each core. AMD and Graviton families
have one thread for each core. The harness reads the topology from sysfs.
It does not assume it.

A target can also run a "baseline" build (`x86_64` or `generic`).
The target table is data in `bench.toml`, not code.

## Repository layout

```
bench.toml                  project config for the harness
infra/
  modules/bench-iam/        OpenTofu module: IAM user, policy, reaper Lambda
  modules/bench-base/       OpenTofu module: security group, key pair,
                            launch templates, box NixOS configuration
  iam/                      root stack for bench-iam. A human applies it.
  base/                     root stack for bench-base. The bench user applies it.
  base/image.nix            project NixOS module (fastmem packages)
  README.md                 runbook
bench/
  pyproject.toml            uv project
  ec2bench/                 generic fleet library and CLI. No fastmem code.
  fastmem_bench/            fastmem adapter: build, run protocol, analysis
  tests/
src/bench_c.h               C surface of bench-fastmem (translate-c input)
src/bench_fastmem.zig       measurement binary
src/probe_c.h               C surface of libc-probe (translate-c input)
src/libc_probe.zig          libc symbol probe
```

`infra/modules/` and `bench/ec2bench/` are the copyable pattern. They
version as one unit: the Python assumes the tags and the outputs that the
modules produce. They stay in this repository until a second project
(handoff) adopts them. Then they move to their own repository, and
projects pin a tag (`git::...//modules/bench-base?ref=v0.1` and a uv git
dependency).

The root stacks pin provider versions and commit their lock files. The
modules declare only minimum versions.

## AWS account

- Account `396684171460` ("playground"), region `us-west-2`.
- The human bootstrap profile is `playground-ops` (SSO).
- The agent profile is `fastmem-bench`. It holds static keys for the
  IAM user `fastmem-bench`.
- Use the default VPC and its default subnets. Do not create a VPC.

## Tags

Every resource that the system creates has these tags:

| Tag | Value |
|---|---|
| `Project` | `fastmem-bench` (from `bench.toml`, `project.name`) |
| `ManagedBy` | `tofu` or `ec2bench` |

Every instance also has these tags:

| Tag | Value |
|---|---|
| `Name` | `<project>-<target>` |
| `Target` | target name, for example `c8g` |
| `ExpiresAt` | UTC time in RFC 3339 format, for example `2026-09-24T04:00:00Z` |
| `Owner` | free text, for example `agent` or `matt` |

A RunInstances request tags the instance, its volumes, and its network
interfaces. Tag keys must have exactly these spellings: the IAM policy
rejects other keys, in any case. The IAM policy uses the `Project` tag as
its security boundary.

## Lifetime guarantee

Two mechanisms end a box. They are independent.

1. The TTL guard on the box (fast path). A systemd timer reads `ExpiresAt`
   from instance metadata every minute and runs `poweroff`. The launch
   template sets shutdown behavior to `terminate`. The guard falls back to
   12 hours after boot when the tag is missing or malformed.
2. The reaper (the guarantee). A Lambda in the bench-iam module runs every
   5 minutes, outside every box. It terminates each project instance that
   is stopped, has no valid `ExpiresAt`, is past `ExpiresAt`, or is older
   than 24 hours. It deletes orphaned project volumes and network
   interfaces.

The agent can apply `infra/base`, so it can change launch templates, and
it can write any `ExpiresAt` value. The guest guard therefore does not
bind the agent. The reaper does: its role, schedule, and limits belong to
the human-applied stack. The worst case is one allowed instance for 24
hours. The harness caps a TTL at `fleet.max_ttl` (12 hours).

## infra/modules/bench-iam

- An IAM user with one customer managed policy and one access key.
  `infra/iam/write-credentials.sh` writes the key to the profile.
- The policy allows every `ec2:Describe*` and `ec2:Get*` action.
- `ec2:RunInstances` requires: a project launch template, the NixOS AMI
  from that template, the `Project` and `ExpiresAt` request tags, an
  allowed instance family (`c7i`, `c8i`, `c7a`, `c8a`, `c7g`, `c8g`,
  `c9g`, all sizes, no variants), on-demand market, default tenancy, gp3
  volumes up to 100 GiB, 3000 IOPS and 125 MiB/s, and project tags on new
  network interfaces.
- Tag writes need canonical tag keys. Nobody can delete `Project` or
  `ExpiresAt`, in any case.
- `ec2:TerminateInstances` only on project instances. No Stop or Start:
  a stopped instance escapes the guest guard.
- Create, change, and delete of the security group, key pair, and launch
  templates that bench-base needs, scoped by the project tag.
- Every action outside `us-west-2` is denied. No IAM, S3, Lambda, or
  other service. No `iam:PassRole`.
- The reaper Lambda, its role, its log group, and its schedule.
  `infra/README.md` describes the checks after an apply.

## infra/modules/bench-base

- A security group `<project>-ssh` in the default VPC, with inbound SSH.
- An ED25519 key pair. The private key goes to `var.key_file`, mode
  `0600`, gitignored.
- One launch template per architecture (`<project>-x86_64`,
  `<project>-arm64`): a pinned AMI, shutdown behavior `terminate`, IMDSv2
  with instance metadata tags, a gp3 root volume, tag specifications for
  instances, volumes, and network interfaces, and no instance type.
- The user_data is `image.nix.tftpl`, rendered with `var.image_version`
  and the project module `var.nixos_module`. The template owns the fleet
  contract: the TTL guard, `programs.nix-ld` (the shipped binaries use the
  standard interpreter paths), ASLR off, perf sysctls, masked noisy
  services, and `/etc/bench-image`. The project module adds packages.
- Outputs: `launch_template_ids` (by architecture), `key_file`,
  `security_group_id`. The harness reads them with `tofu output -json`.

## bench.toml

```toml
[project]
name = "fastmem-bench"
region = "us-west-2"
profile = "fastmem-bench"
adapter = "fastmem_bench"
remote_dir = "/root/bench"
image_version = "1"          # must match /etc/bench-image on the box
# Optional, with these defaults (they make ec2bench layout-independent):
tofu_dir = "infra/base"
key_output = "key_file"
templates_output = "launch_template_ids"
ssh_user = "root"
results_dir = "bench-results"
cache_dir = ".bench-cache"
minimum_effect = 0.0         # adapter: minimum fractional effect for marks

[fleet]
default_ttl = "4h"
max_ttl = "12h"              # up and extend refuse a longer TTL
default_owner = "agent"

[targets.c7i]
instance_type = "c7i.xlarge"
arch = "x86_64"
zig_target = "x86_64-linux-gnu"
zig_cpu = "sapphirerapids"   # -Dcpu of the G1-G4 builds
baseline_cpu = "x86_64"      # -Dcpu of the G6 builds (bench run --cpu baseline)
# ... one table for each target in the Targets section
```

`baseline_cpu` is `x86_64` on the x86 targets and `generic` on the
aarch64 targets (plan, G6). The x86 build selects its kernel at runtime.
Without the key, the adapter uses these architecture defaults.

`ec2bench` reads `[project]`, `[fleet]`, and the `instance_type` and
`arch` fields of `[targets.*]`. The adapter reads the other fields.
`ec2bench` ignores keys that it does not know.

## bench/ec2bench (generic)

`ec2bench` contains no fastmem code. It depends on `boto3`, `rich`, and
`click`. It uses the system `ssh` and `rsync` with SSH connection
multiplexing (`ControlMaster`).

Commands (entry point `bench`, run as `uv run bench <command>`):

| Command | Behavior |
|---|---|
| `up <target>... [--ttl 4h] [--size xlarge]` | Reap first. Launch the missing instances from the launch templates, in parallel. Wait until SSH works and `/etc/bench-image` matches. Terminate a box that does not become ready. |
| `ls` | Show the instances with the `Project` tag: target, type, state, IP, time until `ExpiresAt`. |
| `down <target>... \| --all` | Terminate instances. |
| `extend <target>... --ttl 2h` | Set `ExpiresAt` to now plus the TTL. |
| `reap` | Terminate every instance with the `Project` tag whose `ExpiresAt` is in the past or absent. |
| `ssh <target> [cmd...]` | Open a shell, or run one command. |
| `facts <target>...` | Collect host facts and print them. |
| `analyze <run-dir>` | Analyze saved raw rounds again, without AWS, SSH, or builds (adapter command). |

Library responsibilities:

- `Config`: parse `bench.toml`.
- `Fleet`: find instances by tag, launch, terminate, extend, reap.
  One running instance for each target at a time.
- `Box`: SSH command execution with timeout and streamed output, file
  upload, and file download for one instance.
- `parallel`: run one function across boxes at the same time, with a
  `rich` live display for each box. One failed box does not stop the
  others. The caller receives a result or an error for each box.
- Host facts: collect generic facts and cache them by instance ID under
  `bench-results/.facts/<instance-id>.json`. Generic facts are:
  `/proc/cpuinfo` model and flags, `lscpu -J`, CPU topology from sysfs,
  `uname -a`, the kernel command line, the IMDS instance identity document,
  `/etc/bench-image`, and the NixOS version. Each probe is optional: a
  failure goes into the facts record and never stops a run.
- CPU isolation: a function that selects one benchmark CPU for each box.
  It selects the last physical core. On SMT hosts, it also leaves the
  SMT sibling idle. It restricts `system.slice`, `user.slice`, and
  `init.scope` to the other CPUs with `systemctl set-property --runtime`
  `AllowedCPUs=`. It returns the CPU number. A directory in `/run` is an
  atomic claim, and an active `ec2bench-run-*` unit means "box busy".
  `run_isolated` executes a command as a transient `ec2bench-run-<name>`
  unit in `bench.slice` on that CPU (the SSH session itself stays in the
  restricted `user.slice`). `stop_isolated` stops a group of these units
  after an interrupt. The old state is restored on exit.
- Plugin hook: an adapter registers more `click` commands on the `bench`
  group. `ec2bench` finds the adapter from `bench.toml`
  (`[project] adapter = "fastmem_bench"`).
- Run directories: `bench-results/<run-id>/`. The run ID is
  `<UTC yyyymmddTHHMMSSZ>-<label>`. `manifest.json` holds the git state,
  the command line, the targets, and the instance IDs.

## bench/fastmem_bench (adapter)

Command: `bench run`.

```
bench run [--rev REV]... [--target T]... [--suite quick|standard|large|const|dist]
          [--rounds N] [--cpu target|baseline] [--no-aa] [--up] [--label L]
          [--filter S] [--impl a,b] [--samples N] [--sample-ms M]
          [--minimum-effect F] [--dist-file PATH] [--x86-experiment E]
```

- `--rev` names a git revision. `WORKTREE` names the current working
  tree, uncommitted edits included. The default is `WORKTREE` only.
  With two or more revisions, the first revision is the baseline.
- `--x86-experiment` passes `-Dx86-experiment` to every source build
  (default `auto`: the per-model tuning table). Use it to A/B an opt-in
  experiment without flipping the table; the build cache keys on it and
  the manifest records it per source. Experiments are branch-local: a
  revision whose build does not declare the value builds its own
  default, with a note on stderr and in the manifest.
- `--target` defaults to all targets with a running instance.
- `--rounds` defaults to 5.
- `--cpu target` (the default) builds with `zig_cpu`. `--cpu baseline`
  builds every revision with `baseline_cpu`, for G6. The manifest records
  `cpu_mode` and the CPU of each target (`cpus`). Analysis rejects a raw
  file whose `meta.cpu` differs from that CPU.
- An x86_64 `--cpu baseline` build selects its kernels at run time
  (`docs/runtime-dispatch.md`). The manifest records the expected level of
  each target in `dispatch_levels`: the `zig_cpu` of the target. Analysis
  rejects a raw file whose `meta.dispatch.level` differs from it.
- The dispatch capability of a binary is its codegen evidence: a
  dispatching binary exports `fastmem_x86_<id>_resolve_*`. Analysis requires
  `meta.dispatch` exactly when `meta.codegen` names a resolver. The build
  step rejects a revision whose `build.zig` declares `x86-dispatch` when its
  G6 x86 binary has no resolver. A binary of an older revision has neither,
  and no level applies to it.
- `--up` launches missing targets first, and measures the targets that
  came up.
- `--filter`, `--impl`, `--samples`, and `--sample-ms` go to the binary.
  Prefer fewer samples and more rounds: the round is the unit of independence.

Protocol:

1. Resolve each revision to a source tree. A committed revision gets a
   `git worktree` under `.bench-cache/src/<sha>`. `WORKTREE` uses the
   repository root.
2. Build for each (revision, target) pair:
   `zig build install -Dtarget=<zig_target> -Dcpu=<zig_cpu or baseline_cpu>
   -Doptimize=ReleaseFast -Dlink-libc=true -Drev=<label> --prefix <dir>`.
   Cache the output by (source hash, target, cpu). Build the pairs in
   parallel, limited to the number of local CPUs.
3. Disassemble the `fastmem_*` and `builtin_*` symbols of each local
   binary with `llvm-objdump`. Save the result in the run directory.
4. For each target, in parallel:
   1. Upload the binaries and `libc-probe` to `<remote_dir>/<run-id>/`.
   2. Collect host facts (cached). Run `libc-probe`. Disassemble the
      three resolved glibc memory implementations on the box.
   3. Isolate the benchmark CPU.
   4. Build the variant list: one variant for each revision, plus an
      `A/A` variant that runs the baseline binary a second time. `--no-aa`
      removes the `A/A` variant.
   5. For each round, order the variants by a seeded, balanced Latin
      square row that the manifest records. Run each variant once with
      `run_isolated`. Write stdout to `raw/<variant>/r<round>.jsonl`.
      Download and validate each round file as soon as it finishes; a
      bad file fails that target at once.
   6. On any exit, stop the run's units and restore CPU isolation.
5. Analyze and write `summary.json` and `report.md`. Print the summary
   table.

Analysis:

- The unit of measurement is ns per operation. One round is one process
  run of one variant. The round is the unit of independence.
- For each (target, variant, case, impl, round) cell, take the median of
  the samples of the round: the round median.
- Report these ratios for each case, as `candidate / reference`:
  - Each fastmem implementation against itself in the baseline revision.
  - `builtin/glibc`, `fastmem_abi/glibc`, and `fastmem_inline/glibc` for each revision.
  - `fastmem_abi/builtin` for each revision.
  - `fastmem_inline/builtin_const` for const cases.
  - `A/A` against the baseline for every implementation.
- Two variants run in separate processes. For A/A and revision rows, use
  the logarithms of the round medians of the two cells. The ratio is
  `exp(median(c_i - r_j))` over all pairs of rounds: the two-sample
  Hodges-Lehmann estimate.
- For these rows, compute the exact Mann-Whitney interval over all
  rounds: `[d_(k), d_(nm+1-k)]` of the sorted pairwise log differences.
- The implementations of one variant run in the same processes. Round `i`
  of the candidate and round `i` of the reference share one process. For
  these rows, use the per-round log ratios `l_i = log(c_i / r_i)`.
- For these rows, the ratio is `exp` of the median of the Walsh averages
  `(l_i + l_j) / 2`, `i <= j`: the one-sample Hodges-Lehmann estimate.
  The interval is the exact Wilcoxon signed-rank interval
  `[w_(k), w_(N+1-k)]` of the sorted Walsh averages.
- In both methods, `k` is the largest value that gives a coverage of at
  least 95%. If no `k` reaches 95%, `k` is 1: the full range.
- Record the nominal coverage in `ci_level` and the method in `ci_method`
  (`mann-whitney` or `signed-rank`). `report.md` shows the level of each
  row. The analysis has no random component.
- The Mann-Whitney coverage is 96.8% for 5 against 5 rounds. The
  signed-rank coverage is 93.75% for 5 rounds, 96.9% for 6 rounds, and
  95.3% for 7 rounds. For 5 and 6 rounds, the paired interval is the range
  of the per-round ratios. That range needs no symmetry assumption.
- The levels are nominal under a model. The Mann-Whitney interval assumes
  a location shift between the two processes' log times. The signed-rank
  interval assumes that the per-round log ratios are symmetric about their
  center; above 6 rounds an asymmetric distribution can miss more often
  than the level says. The 5- and 6-round ranges are distribution-free
  intervals for the median.
- G4's const rule uses the G3 margin: a const size violates only when its
  whole interval lies above 1 + max(floor, 0.01). The const A/A null
  reference uses the same rule.
- G6 uses the G3 rule on the `fastmem_abi/builtin` rows of a baseline
  build (`--cpu baseline`).
- A row with fewer than 5 rounds has insufficient evidence
  (`evidence: "insufficient"`). It gets no mark, and its goal components
  are NA.
- Flag an outlier round in each cell with at least 5 rounds. A round is
  an outlier if its log distance from the median of the other rounds is
  larger than both of these values:
  - 5 robust standard deviations of the other rounds (1.4826 times the
    median absolute deviation, minimum 0.005).
  - `log(1.05)`.
- If two or more rounds of a cell meet this condition, flag no round.
- Report each outlier in `summary.json` (`outliers`), in each row that
  uses the cell (`outlier_rounds`), and in `report.md`. An outlier stays
  in every ratio and every interval.
- The noise floor is per (target, op, size): the 95th percentile of
  `|log ratio|` over the A/A rows of the group, pooled across profiles and
  all impls. Interpolate linearly between order statistics. Report the
  floor as `exp(q) - 1`. `dist` cases use one floor per (op, size tier).
  Interval endpoints do not enter the floor.
- Mark a ratio as significant only if the row has sufficient evidence and
  the whole interval is outside `[1/(1+m), 1+m]`. `m` is the larger value
  of the floor and `minimum_effect`.
- Revisions with different case sets are compared on their common cases,
  with a warning.
- Report the geometric mean of the ratios for each (op, size tier). The
  size tiers are 0–16, 17–64, 65–256, 257–1024, 1025–16384, and above
  16384 bytes.
- `report.md` puts one table for each target and marks significant rows.

Stability (`bench/fastmem_bench/stability.py`):

- The analysis groups the variants by the executable digest of their
  codegen evidence (`binary_sha256`). Without evidence, the A/A variant
  joins its baseline. Two revisions that resolve to the same source give
  one group.
- A spike is a round median more than 10% above the median of all rounds
  of its (case, impl) in the group. The definition is the one of
  "Estimator evidence" below.
- For each group and metric (`ns` and `cycles` per operation),
  `summary.json` (`stability.groups`) has these values: the spike count,
  the spike rate over all round cells, and the count per variant and per
  process. It also gives the share of the worst process. Spikes that
  cluster by process give that process a large share.
- The `cycles` metric uses only samples that the PMU counted for the
  whole batch. Cycles exclude the time when the thread is not scheduled.
  A cycles spike is therefore an effect inside the core, for example of
  placement. A spike in `ns` only is time outside the thread, for example
  preemption.
- A group with two or more variants also has a null floor: the A/A floor
  computation on its first two variants. The report gives the median,
  p90, and maximum over the floor groups.
- `memory` gives the THP coverage of the schema-v3 arena for each
  process. A warning gives the number of processes that did not get THP
  for the whole arena, and the lowest coverage.
- These numbers describe the measurement. They do not enter a ratio, an
  interval, a floor, or a goal.

### Estimator evidence

The evidence comes from `bench-results/20260924T041207Z-baseline-016/`.
That run has 7 targets and 5 rounds. Its `aa` variant runs the same binary
as `v0`, so every A/A difference is noise. "Old" is the analysis before
736ab60. "Rejected" is 736ab60 to 7da76c3: it removed outlier rounds from
the interval and used the two-sample interval for all rows.

A spike is a round median more than 10% above the median of the 10 runs
of its cell. These facts describe the spikes:

- They affect 0.06% (c7i) to 3.9% (c8a) of cells. Neither variant has
  systematically more spikes (v0/aa: 280/277 on c7a, 373/254 on c8a,
  29/57 on c8i). The count changes more between processes: on c8a, one
  aa process has 203 and another has 4.
- In 80% (c7i) to 97% (c8a) of spike cells, at least three of the four
  samples of the round are high. A spike lasts for the whole case, so
  the sample median does not remove it.
- For the 458 spike cells above 25% (c7i, c8i, c7a, c8a, c7g), the cycles
  per operation rise by the same factor as the time. The instructions per
  operation do not change. On x86, ref-cycles rise by the same factor.
- The thread thus runs at the same clock and needs more cycles for the
  same instructions. Preemption and frequency changes do not explain the
  spikes. The mechanism is unverified.
- Spikes are co-located. On six targets, other implementations of the
  same case and round spike at 4 to 160 times the base rate. Cases within
  two positions in time spike at 2.7 to 18 times the base rate. c7i has
  only 10 spike cells, and none of them is co-located.
- The binary runs the cases in size order. A spike window thus covers
  all profiles and implementations of one or more sizes: one floor group.
  The old maximum-based floor gave that group the spike.
- Some cells are multimodal, not spiky. c7a `builtin` below 64 bytes and
  c7g size-0 `builtin` take two or three discrete speeds per process.
  c8g `set/*/3 builtin` is 1.79 ns or 2.26 ns per process. No robust
  estimator removes this noise at 5 rounds.

The point estimator must be stable on the null. The table gives the 95th
and 99th percentiles of `|log ratio|` (%) over 16 null splits. Each split
puts one run of each round slot on each side: 1630 (case, impl) rows.

| Target | Pooled-sample median (old) | Median of paired round ratios | Two-sample Hodges-Lehmann |
|---|---|---|---|
| c7i | 1.73 / 4.73 | 1.81 / 4.58 | 1.62 / 3.82 |
| c8i | 1.43 / 5.83 | 1.44 / 4.63 | 1.19 / 3.74 |
| c7a | 4.84 / 31.8 | 3.56 / 21.8 | 2.85 / 17.2 |
| c8a | 4.70 / 13.2 | 3.23 / 11.6 | 2.78 / 10.4 |
| c7g | 1.06 / 11.6 | 0.91 / 3.46 | 0.79 / 3.05 |
| c8g | 1.01 / 3.49 | 1.08 / 3.57 | 0.93 / 3.19 |
| c9g | 1.09 / 4.01 | 1.14 / 3.34 | 0.97 / 3.36 |

For separate processes, pairs by round index do not help: the paired
median is less stable than the two-sample estimate on every target. The
floor therefore uses the two-sample estimate.

Two exact nulls from the review of the rejected analysis set the interval
rules:

- Independent null with a minority mode: each round draws one log value
  from `(-0.005, 0, 0.005, 0.295, 0.3, 0.305)`, 5 rounds on each side,
  all 6^10 assignments. The Mann-Whitney interval over all rounds misses
  1 in 1.408%. With flagged rounds removed, it misses 8.482%. A minority
  mode that appears once in 5 rounds is a legitimate draw, not an error.
- Dependent null: 5 processes with a factor `z` from `(-0.024, -0.012,
  -0.001, 0.001, 0.012, 0.024)`. The candidate takes `exp(z)` and the
  reference takes `exp(-z)`. Both have the same distribution. The
  two-sample interval claims 96.8% and misses 1 in 8.436% of the 7776
  assignments. The paired interval misses 6.250%, its exact level.

`bench/tests/test_coverage.py` holds both nulls and one analyze-level
counterexample of each. The analyze-level tests fail on 7da76c3.

The table compares the three analyses on the cross-process null (16
splits). "Marks" use floors from the other cases of the group
(leave-one-case-out), on the aa-v0 split. The floors are the median / p90
/ max over the 105 groups (%). The rejected and new floors are identical.

| Target | Interval misses 1 (old, rejected, new) | Lower > 1.00 | Marks | Old floors | New floors |
|---|---|---|---|---|---|
| c7i | 13.0%, 3.9%, 3.6% | 6.5%, 2.0%, 1.8% | 0.37%, 0.61%, 0.37% | 3.5 / 14 / 38 | 0.40 / 3.1 / 8.8 |
| c8i | 12.8%, 3.5%, 3.2% | 6.4%, 1.7%, 1.5% | 0.31%, 0.49%, 0.25% | 3.6 / 12 / 58 | 0.28 / 1.7 / 4.8 |
| c7a | 12.0%, 3.3%, 2.5% | 5.5%, 1.6%, 1.2% | 0.31%, 0.37%, 0.00% | 14 / 50 / 93 | 0.47 / 9.9 / 21 |
| c8a | 11.6%, 3.5%, 2.8% | 5.8%, 1.9%, 1.5% | 0.06%, 0.06%, 0.06% | 12 / 173 / 373 | 0.24 / 7.1 / 28 |
| c7g | 12.7%, 3.2%, 2.9% | 4.0%, 1.0%, 1.0% | 0.25%, 0.25%, 0.12% | 3.2 / 14 / 100 | 0.31 / 1.9 / 13 |
| c8g | 11.7%, 3.3%, 3.0% | 6.0%, 1.6%, 1.4% | 0.18%, 0.31%, 0.12% | 2.5 / 14 / 27 | 0.25 / 2.2 / 8.8 |
| c9g | 11.6%, 2.7%, 2.5% | 4.7%, 1.2%, 1.0% | 0.06%, 0.06%, 0.00% | 2.1 / 11 / 18 | 0.23 / 2.0 / 7.0 |

The old bootstrap interval covered only 87% to 88%. The new Mann-Whitney
interval misses 2.5% to 3.6%, below its 3.17% limit on six targets. On
c7i, 3.6% is within the random error of 16 correlated splits.

A within-process null from the data splits each cell into two halves of
its own samples: samples 0 and 3 against samples 1 and 2. The halves come
from the same process and case, and they alternate in time. Each half
contributes the median of its two samples per round. The null has 3260
rows per target (v0 and aa).

| Target | Interval misses 1 (old, rejected, new) | New level |
|---|---|---|
| c7i | 14.1%, 2.4%, 6.5% | 93.75% |
| c8i | 14.2%, 2.6%, 7.6% | 93.75% |
| c7a | 11.6%, 3.2%, 6.1% | 93.75% |
| c8a | 8.8%, 1.3%, 6.6% | 93.75% |
| c7g | 14.1%, 3.2%, 7.9% | 93.75% |
| c8g | 14.0%, 2.7%, 7.4% | 93.75% |
| c9g | 12.0%, 2.2%, 7.5% | 93.75% |

The halves share the state of their process. This positive dependence
makes the two-sample interval conservative on this null. The dependent
null above shows that the two-sample interval fails for other dependence.
The new misses are 6.1% to 7.9% against a limit of 6.25%. A part of the
excess is a real difference between the halves: on c7g, c8g, and c9g, v0
and aa miss in the same direction for the same cell 1.5 to 2.9 times as
often as independent processes give.

The new analysis keeps real effects. `builtin/glibc` for memset above 64
bytes stays marked on 36 of 36 rows on every target. c7i memcpy from 65
to 256 bytes stays marked on 24 of 24 rows. Some within-variant pairs
have all 10 round ratios between 1.02 and 1.05, or all between 1/1.05 and
1/1.02. The old, rejected, and new analyses mark 34% to 57%, 91% to 100%,
and 91% to 100% of these pairs.

G3 compares 134 copy cases and 233 move cases. A rule of "lower bound
above 1.00" gives 2.5 to 10 false violations per (target, op) on the
within-process null. The G3 rule `lower > 1 + max(floor, 0.01)` gives
0, except 0.5 for c7g move. The G2 case rule (lower bound above 1.10)
gives 0 on every target. The G4 const rule (lower bound above 1.00, 13
cases) gives at least one false violation for 4 of the 14 (target,
variant) pairs.

The floor falls as the rounds increase. A whole-run bootstrap from the 10
runs gives the p90 group floor (%) for n rounds on each side. It is
optimistic because it repeats runs.

| Target | 5 | 10 | 15 | 20 | Rounds for a p90 floor of 2% |
|---|---|---|---|---|---|
| c7i | 2.4 | 1.4 | 1.0 | 0.8 | 7 |
| c8i | 1.8 | 0.8 | 0.8 | 0.5 | 5 |
| c7a | 9.1 | 3.0 | 2.3 | 0.6 | 20 |
| c8a | 10 | 2.8 | 0.9 | 0.8 | 15 |
| c7g | 1.2 | 0.8 | 0.5 | 0.3 | 5 |
| c8g | 1.7 | 0.9 | 0.7 | 0.6 | 5 |
| c9g | 1.9 | 1.0 | 0.7 | 0.5 | 5 |

The maximum group floor stays above 2% at 20 rounds on every target
(2.3% to 5.0%). The multimodal cells cause it. A paired interval reaches
95% only with 6 or more rounds.

## Measurement binary: bench-fastmem

This section defines schema v3.
The implementation is `src/bench_fastmem.zig`.
The parser is `bench/fastmem_bench/jsonl.py`.
The native integration tests are `bench/tests/test_binary_v2.py`.

The binary writes JSONL to stdout and diagnostics to stderr.
It retains samples until the run ends, so the first record includes all performance counter errors.
An interrupted run has no complete JSONL artifact.

### CLI

```text
bench-fastmem [--suite quick|standard|large|const|dist]
              [--filter <substring>]...
              [--impl builtin,glibc,fastmem_abi,fastmem_inline,builtin_const]
              [--samples N] [--sample-ms M] [--warmup-ms W]
              [--seed S] [--dist-file <path>] [--codegen-file <path>] [--list]
```

The defaults are `standard`, all applicable implementations, 20 ms per sample, 10 ms warmup, and seed 1.
The default sample count is the least common multiple of the applicable implementation counts across selected cases.
An unfiltered standard or quick run uses four samples.
A const run uses two samples.
An explicit `--samples` value overrides balance.

The filter selects case IDs by substring.
Multiple filters form a union.
The parser accepts both `--flag value` and `--flag=value`.
Empty selections and invalid arguments cause a nonzero exit.

### Implementations and resolution

| Name | Operation |
|---|---|
| `builtin` | The validated `@extern` pointer to compiler-rt `memcpy`, `memmove`, or `memset` |
| `glibc` | The function pointer from `dlopen("libc.so.6")` and `dlsym` |
| `fastmem_abi` | The public fastmem API in a noinline C-ABI wrapper |
| `fastmem_inline` | The public fastmem API directly in the timed loop |
| `builtin_const` | `@memcpy`, `@memmove`, or `@memset` with a comptime-known length directly in the timed loop |

The three indirect implementations share one timed loop for each operation.
A volatile load reads the selected function pointer once before each batch.
The loop calls that pointer for each operation.
The const profile compares only `builtin_const` and `fastmem_inline`.

The meta field `fastmem_set` records whether the public API provides `fastmem.set`.
A compile-time declaration check enables both fastmem set paths when that API exists.
Without it, set cases contain only `builtin`, `glibc`, and `builtin_const` samples.

At startup, `dlinfo(RTLD_DI_LINKMAP)` identifies the library that `dlopen` returns.
Each glibc pointer must have the same `dladdr` path and base as that library.
The path must end with `/libc.so.6`.
The library base must differ from the executable base.

The builtin evidence comes from `@extern` addresses for `memcpy`, `memmove`, and `memset`.
Each address must resolve to the executable, not libc.
A failed invariant causes a nonzero exit and an error on stderr.
The build includes compiler-rt explicitly.
Builtin wrappers remain only for the codegen proof.
The timed builtin path calls their resolved callees directly, without the extra wrapper.
The harness binary check proves that each builtin wrapper calls the corresponding local text symbol.

The inline and ABI paths call the existing public fastmem API without kernel modifications.
These names identify call boundaries, not independent kernel implementations.

### Cases and buffers

A fixed-size case ID is `<op>/<profile>/<size>`.
The operation is `copy`, `move`, or `set`.

| Operation | Profiles |
|---|---|
| copy | `aligned`: offsets 0/0, `misaligned`: offsets 1/3, `cross-lane`: offsets `chunk-1`/`chunk/2`, `page-offset`: offsets 0/2048 |
| move | `disjoint`, plus `fwd-gapN` and `bwd-gapN` for gaps 1, `chunk-1`, and `chunk+1` |
| set | `aligned`: destination offset 0, `misaligned`: destination offset 3 |
| all | `const`: offsets 0/0, comptime-known size, separate source and destination regions |

Forward move places the destination below the source.
Backward move places the destination above the source.
The requested gap remains fixed even when the size does not exceed it.
Such small cases do not overlap.
Disjoint move uses the separate source and destination regions.

The standard runtime sizes are:

```text
0, 1, 2, 3, 4, 7, 8, 15, 16, 24, 31, 32, 48, 63, 64, 96,
127, 128, 192, 255, 256, 384, 511, 512, 768, 1024, 2048,
4096, 8192, 16384, 65536, 262144, 1048576
```

The quick runtime sizes are:

```text
8, 32, 64, 256, 1024, 4096, 16384, 262144
```

The large runtime sizes for every operation are:

- 1 MiB
- 4 MiB
- 16 MiB
- 64 MiB

The large suite also includes these fill-only sizes:

- 24 MiB
- 32 MiB
- 48 MiB

The extra fill sizes bracket the experimental Zen 5 NT threshold at 32 MiB.
Both aligned and misaligned profiles apply.
Large remains a separate suite.
The const suite uses the `copy/const/<size>`, `move/const/<size>`, and `set/const/<size>` profiles at these sizes:

```text
1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256
```

The const suite contains 39 cases.
The standard suite also includes all const cases and both synthetic distributions for every operation.
Standard contains 540 cases and quick contains 120 cases.
These counts follow the construction in `buildCases` and the native coverage test.

#### Memory arena (schema v3)

Schema v2 mapped fresh source and destination buffers for each case.
Physical placement then changed from case to case and from process to process.
The baseline run showed spikes with more cycles at a constant instruction count (see "Estimator evidence").
The stats-lane characterization adds these facts for AMD: 3% to 4% of cells spike, and the spikes cluster by process.
They hit the separate-buffer profiles with equal page offsets.
The mechanism is unverified.
Placement that changes with each mapping is a candidate cause.

Schema v3 allocates one arena at startup, before any timing:

1. Reserve the arena size plus 1 GiB as `PROT_NONE`.
   Map the arena at the 1 GiB boundary inside the reservation, and release the rest.
   The virtual address bits below 30 are then the same in every process.
2. Apply `MADV_HUGEPAGE` before the first touch.
3. Pre-fault with `MADV_POPULATE_WRITE`, then write the initial bytes.
4. Apply `MADV_COLLAPSE` (Linux 6.1) as a synchronous retry when a fault got small pages.
5. Read `AnonHugePages` over the arena from `/proc/self/smaps`.

The arena has three regions, and every region is a multiple of 2 MiB:

| Region | Offset | Use |
|---|---|---|
| source | 0 | Source bytes. Shared (overlapping) moves use only this region. |
| destination | `region_bytes + 4096` | Destination bytes of separate-buffer cases |
| sequence | `2 * region_bytes` | The 4096 entries of the distribution being measured |

`region_bytes` is the largest case footprint of the run plus 4096, rounded up to 2 MiB.
A footprint is the maximum length plus the maximum offset plus one byte, or plus 512 bytes for a distribution.
Standard and quick use 2 MiB regions, so their cases use the same addresses.
Every case uses the same region starts plus its profile offsets.
Before a case, the binary restores the initial bytes of the case footprint.
Pre-fault writes `0x5a` to the whole arena.
Source byte `i` is `i * 131 + 17` modulo 256, and destination bytes are `0x5a`.

With THP, the physical address bits below 21 equal the virtual address bits.
Cache indexes that depend only on those bits are then the same in every round.
Indexes that use higher physical bits (for example large L2 or L3 slices
and hashed LLC sets) can still differ between processes.
Without THP, the physical pages still stay fixed for all cases of one process.
The meta record gives the THP state (see the `memory` table below).

The fixed layout removes the variation of virtual placement between processes, and with THP the variation of physical placement inside each 2 MiB page.
It does not remove a placement effect.
If the layout is slow for a case, every round of that case is slow, for all implementations.
The destination starts one page past its 2 MiB boundary.
Equal profile offsets keep their page offset, which is the subject of the profiles (4K aliasing).
The two addresses are not congruent modulo 2 MiB, so caches and predictors that index bits 12 to 20 see two different lines.
Schema v2 mapped the destination after the source. With top-down `mmap`, a small destination was then usually the page below its source (unverified).

The `page-offset` profile separates the source and destination offsets modulo 4096 by 2048 bytes.
The loop does not mutate source bytes between operations.
Copy and move read a destination byte after each operation.
Set writes the nonzero byte 165 and reads a destination byte.
A memory clobber preserves the entire inline operation, not only the observed byte.
There is no accumulated checksum or checksum dependency between iterations.

### Distributions

A distribution contains 4096 seeded entries with sizes and offsets.
The loop repeats that sequence.
The sample field `size` is its arithmetic mean.
The `ns` field remains a total over `iters` calls, not a per-call value.

| Case suffix | Size distribution | Offset range |
|---|---|---|
| `dist/small` | Minimum of two uniform draws from 0 through 256 | 0 through 127 |
| `dist/mixed` | Log-uniform sizes from 0 through 16384 | 0 through 511 |
| `dist/file` | Weighted draws from the supplied histogram | 0 through 511 |

Distribution copy uses the separate source and destination regions.
Distribution move uses independently selected offsets in the source region.
Distribution set ignores the source offset.

The option `--dist-file` requires `--suite dist` and replaces the synthetic distributions.
Its JSON format is `{"<size>": weight, ...}`.
Sizes are integer byte counts from zero through 1 GiB.
Weights are finite, nonnegative numbers, with a positive total.
The file limit is 1 MiB.

The adapter accepts `--dist-file`, saves its bytes and SHA-256 digest, and uploads the file with the binary.
The manifest records the original path and digest.
The meta record contains the path that the binary reads.

### Calibration and sample order

Each implementation starts with a 64-iteration pilot after its warmup.
Calibration scales the batch both downward and upward toward the requested sample duration.
It stops within 25 percent, after 12 attempts, or at the iteration limits.
The limits are one operation and 1073741824 operations.
A single slow operation can exceed the duration target.

Each recorded sample contains its actual iteration count.
The next sample uses a proportional adjustment from the previous duration.
Within a case, sample `s` starts at implementation index `s % count`.
This rotation balances positions when the sample count is a multiple of the implementation count.

### Performance counters

The Linux group contains cycles, instructions, and x86 ref-cycles.
The group counts the benchmark thread and excludes kernel and hypervisor execution.
Its read format is `GROUP | TOTAL_TIME_ENABLED | TOTAL_TIME_RUNNING`.
Every reset, enable, and disable ioctl uses `PERF_IOC_FLAG_GROUP`.
Every ioctl result is checked.

The sample stores unscaled event counts.
The fields `time_enabled` and `time_running` expose multiplexing in nanoseconds.
They are per-sample deltas because `PERF_EVENT_IOC_RESET` does not reset those kernel time fields.
The group reset does reset all event counts.

A ref-cycles open failure retries the group with only cycles and instructions.
The meta error names the failed event, and `perf.events` names the retained group.
A successful retry keeps `perf.available` true.
Other open failures and all ioctl or read failures disable the group for the rest of the run.
Affected samples contain null counter and time fields.
Earlier successful samples retain their counts.
The meta record contains the error and sets `perf.available` to false.
The consecutive-sample test skips when the host denies access or supplies no PMU runtime.

### JSONL schema, version 3

Every measurement consists of one meta record, sample records, and one end record.
The parser accepts schema v2 and v3, so that old run directories still analyze.
Schema v3 adds the meta `memory` object and the `const` profile for move and set.
A v2 record has no `memory` field, and its const cases are copy cases only.
The parser rejects schema v1, v2 records with v3 fields, v3 records without `memory`, and files without an end record.
It also rejects duplicate samples and incomplete per-case implementation sets.
All record objects reject unknown fields and duplicate JSON keys.
Integer fields reject floats, strings, and booleans.
Cross-field checks enforce case IDs, sizes, offsets, gaps, suites, and perf event consistency.

Meta fields:

| Field | Type and meaning |
|---|---|
| `type`, `schema` | Literal `"meta"` and integer 3 (2 for old runs) |
| `rev`, `zig`, `target`, `cpu`, `optimize` | Build identifiers. Optimize is `"ReleaseFast"`. |
| `link_libc`, `chunk_bytes` | Literal true and the SIMD chunk size |
| `suite`, `seed`, `samples`, `sample_ms`, `warmup_ms` | Effective configuration |
| `impls` | Selected implementation names applicable to at least one selected case |
| `dist_file` | String path or null |
| `set_value`, `fastmem_set` | Integer 165 and the availability of the public set API |
| `libc_path`, `libc_base` | The `dlopen` library path and integer base address |
| `resolution` | Objects for `memcpy`, `memmove`, and `memset` |
| `codegen` | Binary inspection evidence, or null without `--codegen-file` |
| `memory` | The arena object (v3). Null in `--list` output. |
| `perf` | Object with `available`, `events`, and `error` |
| `dispatch` | The runtime-dispatch object. Only a binary that dispatches at run time emits it. |

The `dispatch` object has these fields (`docs/runtime-dispatch.md`):

| Field | Type and meaning |
|---|---|
| `level` | The selected level: `generic`, `x86_64_v3`, `x86_64_v4`, `sapphirerapids`, `graniterapids`, `znver4`, or `znver5` |
| `kernel` | The kernel name of the level, as `fastmem.impl` names it in a comptime build |
| `vendor`, `family`, `model` | The CPUID vendor (`intel`, `amd`, `other`) and the display family and model |

The `memory` object has these fields:

| Field | Type and meaning |
|---|---|
| `layout` | Literal `"arena"` |
| `arena_bytes`, `region_bytes`, `base_align` | Arena size, region size, and base alignment (1 GiB) in bytes |
| `src_offset`, `dst_offset`, `seq_offset` | View offsets: 0, `region_bytes + 4096`, and `2 * region_bytes` |
| `hugepage_advice`, `populate`, `collapse` | The errno name of `MADV_HUGEPAGE`, `MADV_POPULATE_WRITE`, and `MADV_COLLAPSE`: `SUCCESS` or an error such as `INVAL` or `NOMEM` |
| `thp_enabled`, `thp_defrag` | The selected value of the sysfs THP policy, for example `madvise`, or null |
| `thp_pmd_bytes` | `hpage_pmd_size` from sysfs, or null |
| `anon_huge_bytes_start`, `anon_huge_bytes_end` | `AnonHugePages` over the arena after pre-fault and after the last case, in bytes, or null |

THP backs the whole arena when both huge-page counts equal `arena_bytes`.
A difference between the two counts shows a collapse by `khugepaged` during the run.

Each resolution object contains `glibc` and `builtin` evidence objects.
Each evidence object contains these fields:

| Field | Type and meaning |
|---|---|
| `address` | Positive integer function pointer |
| `dli_fname` | Nonempty library or executable path |
| `dli_fbase` | Positive integer base address |
| `offset` | Nonnegative integer `address - dli_fbase` |

The `perf.events` list names the final attempted group, including any ref-cycles fallback.
The `perf.error` field is a diagnostic string or null.
The `perf.available` field is true when the final group remains usable throughout the run.

A sample has this shape. The numbers are illustrative, not benchmark evidence.

```json
{"type":"sample","case":"copy/aligned/64","op":"copy","profile":"aligned","size":64,"src_off":0,"dst_off":0,"gap":null,"impl":"fastmem_abi","sample":0,"iters":1000,"ns":10000,"cycles":30000,"instructions":9000,"ref_cycles":null,"time_enabled":11000,"time_running":11000}
```

Sample fields:

| Field | Type and meaning |
|---|---|
| `case`, `op`, `profile` | Case identity and operation metadata |
| `size` | Nonnegative number. Fixed size or distribution mean, in bytes. |
| `src_off`, `dst_off` | Nonnegative integers for fixed cases, null for distributions |
| `gap` | Integer for a fixed directional move, otherwise null |
| `impl` | One applicable implementation name |
| `sample` | Zero-based sample index within this case and implementation |
| `iters` | Positive integer operation count |
| `ns` | Positive integer elapsed nanoseconds for the batch |
| `cycles`, `instructions`, `ref_cycles` | Nonnegative integer totals or null |
| `time_enabled`, `time_running` | Nonnegative integer nanoseconds or null |

On aarch64, `ref_cycles` is always null.
The source offset has no operational meaning for set.
Consumers compute ns per operation as `ns / iters`.
They do not scale wall-clock time with the PMU time fields.

The end record has this shape:

```json
{"type":"end","cases":104,"elapsed_ns":123456789}
```

The field `cases` counts selected cases, not samples.
The field `elapsed_ns` includes warmup, calibration, and measurements, but excludes JSON emission.
With `--list`, case records replace samples.
A case record has `type`, `case`, `op`, `profile`, and `size` fields.
The analysis parser does not accept list output as a measurement.

### Adapter comparisons and goals

The adapter reports these comparisons for each common case:

- `builtin/glibc`: the ecosystem gap.
- `fastmem_abi/glibc`: the G2 kernel comparison.
- `fastmem_inline/glibc`: the G4 inline comparison.
- `fastmem_abi/builtin`: the G3 compiler-rt comparison.
- `fastmem_inline/builtin_const`: the const comparison.
- Each fastmem implementation against itself in the baseline revision.

Ratios use candidate time divided by reference time.
The adapter uses the round estimators and the per-operation, per-size A/A floors of the Analysis section.
Rows between two variants use the Mann-Whitney interval.
Rows between two implementations of one variant use the paired signed-rank interval.
Significance requires at least five rounds and an available A/A floor.
Distribution floors remain per operation and size tier.

Both output files contain a Goals section for each target, revision, and operation.
The machine representation is `targets.<target>.goals` in `summary.json`.
Each entry contains `G2`, `G3`, `G4`, and `G6` objects with PASS, FAIL, NA, or INVALID status.
Missing cases, fewer than five rounds (insufficient evidence), or absent A/A evidence produce NA for the affected component.
Each component lists the interval levels of its rows in `ci_levels`.

G2 includes the fixed standard runtime cases and `dist/small` and `dist/mixed`.
Its evidence includes the overall geometric mean, tier means, and significant regressions above 1.10.
A G2 row violates its threshold when the confidence interval lower bound exceeds that threshold.
The G2 check does not add the A/A floor or minimum effect to the threshold.
The tier criterion uses the tier geometric mean of the ratios, with no interval.
Each G2, G3, and G4 const entry contains an `aa_reference` object.
It applies the rule of the goal to the A/A rows of the same implementation and cases.
That count is the violation count of a null. It does not change the verdict.
A/A rows use the Mann-Whitney interval, so the count is a reference for the paired goal rows, not a calibration.

G3 requires the standard runtime cases and both synthetic distributions.
A case violates G3 only when its whole interval lies above `1 + max(floor, 0.01)`.
G3 tests hundreds of cases against 1.00, and this margin controls the false violations of a null.
The evidence contains the worst ratio, the rule, and the violations.
G4 evaluates `dist/small` and the const timing component independently, for copy, move, and set.
The const component requires `<op>/const/<size>` for all 13 const sizes.
Schema-v2 runs have no move or set const cases, so those components are NA.
Its no-call component is NA: `checked by binary test, P4`.
G4 is therefore FAIL or NA for every operation. A timing pass does not imply a G4 pass.

G6 applies the G3 rule to a baseline build (`bench run --cpu baseline`).
It uses the same cases, A/A floors, margin, and codegen evidence as G3.
In a baseline build, G2, G3, and G4 keep their evidence with status NA.
In a target build, G6 is NA.
The reason field names the CPU mode in both cases.

The goal implementation is `bench/fastmem_bench/goals.py`.
The goal tests are `bench/tests/test_v2.py`.
The coverage regressions are `bench/tests/test_coverage.py`.
The thresholds come from G2 through G4 in `docs/fastmem-plan.md`.

### Delegation evidence

The harness disassembles every `fastmem_*` ABI entry and every `runFastmemInline` loop body.
Separate inline entry names keep builtin const loops outside that check.
The check detects calls and tail branches to `memcpy`, `memmove`, or `memset`.
It examines caller disassembly, not glibc implementation code.

The build artifact `bin/codegen.json` contains these fields:

| Field | Type and meaning |
|---|---|
| `binary_sha256` | 64 lowercase hexadecimal characters that identify the executable bytes |
| `checked_roots` | The unique ABI and inline symbols that the harness inspects |
| `delegations` | A list of objects with `caller`, `symbol`, and hexadecimal instruction `address` strings |

Missing ABI or inline roots fail the build check.
The harness supplies `--codegen-file` on every remote run.
The binary checks its `/proc/self/exe` digest against the sidecar before any measurement.
A digest mismatch causes a nonzero exit.
The binary emits the evidence unchanged in `meta.codegen`.

The manifest records the same evidence for every target and variant.
The harness checks raw meta records against that evidence.
Offline analysis also checks the raw records against the manifest.
Evidence must remain identical across rounds of one variant.

Any detected delegation marks G2, G3, and G6 INVALID for that target and variant, across all operations.
The reason names each symbol, for example `fastmem delegates to memcpy`.
INVALID takes precedence over incomplete timing evidence and over a favorable ratio.
No codegen evidence produces NA, never PASS, for G2, G3, and G6.
The fastmem kernels remain unchanged.

### Build and libc-probe

The option `-Drev=<string>` sets the revision label. Its default is `unknown`.
Benchmarks always link libc and include compiler-rt.
The option `-Dlink-libc` remains accepted for command compatibility.
The library module and kernels remain unchanged.

The install step includes `bench-fastmem` and `libc-probe` for the selected target and CPU.
The bench step runs the measurement binary locally.
The test step includes startup resolution, calibration, order balance, and PMU reset tests.

The probe prints its libc path, glibc version, and resolved memory symbols as one JSON object.
Each symbol contains its address, optional symbol name, and actual pointer offset from the library base.
The symbol set includes `memcpy`, `memmove`, and `memset`.
Probe addresses and offsets remain hexadecimal strings for compatibility.

Each raw file must agree with the independent probe on all three glibc offsets and the libc path.
Process addresses are not compared because ASLR can change them.
A mismatch fails that target immediately, including during offline analysis.
The manifest retains the probe evidence.

The harness saves on-box disassembly for all three glibc functions beside the target artifacts.
These artifacts remain under gitignored result directories.
They never enter this MIT repository.
The clean-room rule is in `docs/fastmem-plan.md`.

## Search measurements (`fastmem-find/1`)

`bench-find` measures one-shot `u8` search in nanoseconds per call.
The `find` and `find-analyze` commands use separate search protocols and
analysis modules. They do not change the memory-operation schemas or goals.
The `find-test` command uses a separate correctness matrix.

The primary ratio is `fastmem_direct/std_direct` for runtime needles.
A ratio below one favors fastmem. Fixed-needle comparisons remain separate.
The indirect comparison uses one shared loop and pointer-return C ABI for
stdlib, fastmem, and the verified glibc destination. Each runtime call includes
needle setup. Fixed calls retain compiler optimizations for literal needles.

| Suite | Runtime cases | Fixed cases | Total cases | Cells per sample |
|---|---:|---:|---:|---:|
| quick | 38 | 9 | 47 | 208 |
| standard | 210 | 9 | 219 | 1068 |

Each case contributes equally to its comparison's geometric mean.
These are stress weights, not user-frequency estimates. End matches,
absence, and boundaries receive deliberate emphasis. Ten controlled cases
vary haystack and needle alignment independently, with identical input bytes.
Each actual input must satisfy its advertised first-match position.
Empty needles return zero. Oversized needles return null, regardless of their
position labels.

Accepted runs require at least five rounds and the exact baseline binary
for A/A replay. Results report actual confidence coverage. Five paired rounds
provide 93.75% coverage, not 95%. Outliers remain in all estimates and intervals.

Each A/A floor group fixes these attributes:

- Haystack length.
- Needle length.
- Runtime or fixed needle.

A group pools all implementations and input patterns. Positions and alignments
also pool within that group. The floor uses the 95th percentile of absolute
log ratios from A/A. Significance uses the larger of the measured floor and
the configured `minimum_effect`.

Offline analysis requires consistent retained evidence:

- Manifest revisions and source hashes.
- Exact build commands, command sidecars, and source identities.
- Executable bytes, digests, and codegen sidecars.
- Target configuration and selected dispatch levels.
- Instance identity, topology, isolated CPU, and isolation protocol.
- The glibc probe, seeded round order, and exact measurement commands.
- Exact baseline A/A reuse.

The dispatch level names the shared CPU selection, not a per-case search path.
Tiny and degenerate searches can remain local. The search metadata does not
present a memory-kernel family name as a find entry identity.

The executable audit must reject unknown indirect edges and forbidden calls.
It retains distinct function addresses even when symbols share a name.
Anti-hoist and result-retention review applies to the exact executable bytes.
Invalid or contradictory evidence fails analysis. Pending evidence and protocol
completion do not constitute performance acceptance.

Search acceptance follows `docs/find-plan.md`. A performance claim names its
retained run and a file in `docs/results/`. Aggregate means do not replace
adversarial checks or dispositions for significant regressions above 10%.

## Correctness tests (G1)

`src/tests/main.zig` exercises the public API, not private kernels.
`zig build install` installs the Linux binary at `zig-out/bin/fastmem-tests`.
`zig build test-bin` installs only this binary.
`zig build test-guard -Doptimize=ReleaseFast` executes the full guard suite.
The separate step keeps the exhaustive matrix outside the short unit-test cycle.

The test binary links glibc, like the benchmark binary.
This preserves the same kernel policy while the old kernels retain libc delegation.
Cross builds depend only on glibc components and use the fleet's `nix-ld` interpreter support.

The API contract is:

```zig
pub fn copy(comptime T: type, dest: []T, source: []const T) void;
pub fn move(comptime T: type, dest: []T, source: []const T) void;
pub fn set(comptime T: type, dest: []T, value: T) void;
pub const impl = .{
    .copy = @as([]const u8, "kernel-name"),
    .move = @as([]const u8, "kernel-name"),
    .set = @as([]const u8, "kernel-name"),
};
```

Functions can be inline.
Each `impl` field identifies the selected kernel family at comptime.
The tests gate `set` with `@hasDecl` until the public function exists.
The parser requires `impl.set == "unavailable"` exactly when `set_available` is false.
A pass without set covers only copy and move, not all of G1.

### Guard coverage

Each mapping has inaccessible pages on both sides of its accessible window.
The suite sorts three mappings by address and puts the destination between two read-only sources.
Disjoint move tests both source address orders.
The suite reuses mappings per size class and slides slices inside them.
Small classes retain small windows, irrespective of the target's maximum size.

The source pattern uses a splitmix64 hash of each byte index instead of a repeating 64 KiB block.
The oracle uses independent byte loops, with intrinsics disabled.
Every case compares the entire accessible destination window, which includes all canaries outside the destination slice.
Overlap references read an immutable snapshot, not the mutated source.

| Runtime path | Lengths | Source/destination insets | Move gaps | Union insets |
|---|---|---|---|---|
| Small | Every length 0..1024 | Independent 0..63 | Every gap 0..128 | 0, 1, 17, 63 |
| Large through 64 KiB | Boundary samples | Independent 0, 1, 15, 16, 31, 32, 33, 63 | 0..128 and wide gaps | 0, 1, 17, 63 |
| Large through 1 MiB | Boundary samples | Independent 0 and 1 | 0..128 and wide gaps | 0, 1, 17, 63 |
| Above 1 MiB | Ceiling minus one and ceiling | 0 | 0, 4095, len/2, len-1 | 0 |

Every row uses both start and end placement, and both overlap directions.
Wide gaps are 3840, 3841, 3968, 4000, 4095, 4096, 4097, 8192, len/2, and len-1.
The suite adds wide gaps when the length exceeds 1024.
Set uses each destination inset with values 0x00, 0x5a, and 0xff.
Gap zero tests identity moves.
Duplicate gaps remain separate cases.

Boundary samples include powers of two from 1024 through 1 MiB, with adjacent lengths within the limit.
They also include 4095, 4096, and 4097 multiplied by powers of two through the same limit.
Duplicate lengths remain separate cases.

`src/tests/paths.zig` adds two entry paths:

- C-ABI exports `fastmem_copy`, `fastmem_move`, and optional `fastmem_set`, through volatile-loaded function pointers.
- Specialized public calls with a comptime length for every size 1..256.

Both paths use independent small insets 0, 1, 17, and 63.
Their overlap probes use union inset zero and gaps 0, 1, 128, 3841, 4000, 4096, 8192, len/2, and len-1.
The ABI path also repeats every large sample through 1 MiB with independent insets 0 and 1.
Above 1 MiB, the ABI path repeats the sparse runtime matrix.
These extra paths supplement the exhaustive runtime path instead of replacing it.

Page protection has page granularity, so arbitrary offsets cannot all touch a guard page exactly.
Inset zero puts the slice start or end directly against the corresponding guard.
Every small source length has exact adjacency with every destination inset, and every destination has exact adjacency with every source inset.
Both slices use the same placement side in each disjoint case.
Overlap cases place the union against the guard, so neither valid slice crosses an inaccessible page.
Canaries detect writes into accessible padding, but cannot detect reads into that padding.

### Size ceilings

The default ceiling depends on the comptime CPU model.
Each x86 ceiling exceeds the largest active NT threshold and uses a whole MiB.
The threshold evidence is in `docs/research/hosts/README.md` and `src/x86_64/tuning.zig`.
Zen 5 uses 33 MiB to cover its 32 MiB copy and fill thresholds.

| CPU family | Ceiling |
|---|---|
| znver4 | 16 MiB |
| znver5 | 33 MiB |
| sapphirerapids | 67 MiB |
| graniterapids | 302 MiB |
| Graviton and standalone baseline CPUs | 1 MiB |

`--max-size BYTES` overrides the ceiling with a decimal byte count between 1024 and 512 MiB.
`zig build test-guard -- --max-size BYTES` forwards that option.
The fleet adapter passes the target family's ceiling to both CPU variants, including the baseline build.

Above 1 MiB, the suite keeps overlap cases as well as NT-relevant disjoint cases.
A wrong dispatch can send an overlap into an NT loop.
The maximum window is approximately twice the ceiling, and five windows contain data at peak.
The 302 MiB ceiling therefore needs approximately 3 GiB of memory.

### Result protocol

The binary emits one JSON line on stdout and exits nonzero on failure.
The summary contains:

- `schema: 2`, `matrix: "g1-v2"`, and `status: "pass"` or `"fail"`.
- `cases`, per-entry `path_cases`, `elapsed_ns`, `cpu`, `max_size`, `optimize`, and `link_libc`.
- `set_available` and the three `impl` identifiers.
- `dispatch`: the runtime-dispatch `level` and `kernel` of an x86_64 build without AVX2, or null (`docs/runtime-dispatch.md`).
  `fastmem-tests` links a private copy of the public module with the test hooks (`--x86-level`).
- `detail` and the last case's operation, path, source order, length, offsets, gap, side, and value.
- `fault_address`, `fault_region`, and `fault_access`, which are null outside a signal failure.

The parser independently calculates the matrix count for the ceiling and set availability.
A pass requires exact runtime, ABI, and constant-size counts.
A failure can report a partial count, but the total must equal the sum of the path counts.

SIGSEGV and SIGBUS handlers use `SA_SIGINFO` and report the fault address, mapping region, current case, and elapsed monotonic time.
The handlers identify writes into read-only sources.
Other faults report access type `unknown` because the portable signal data does not identify reads versus writes.
A fixed buffer and raw write keep the fault path independent of allocation and buffered output.
Offsets in failure records are relative to the accessible window, not the selected slice.

### Differential fuzzers

`src/tests/fuzz.zig` contains the copy, move, and gated set fuzzers.
All three use byte-loop references and full-buffer comparisons with canaries.
Lengths reach 64 KiB, and copy and move use independent source and destination offsets 0..63.
Move executes both directions with displacements through 16 KiB.
The maximum-displacement clamp can constrain one offset at that boundary.
The old compiler-rt-oracle fuzzers no longer exist in `src/root.zig`.

`just fuzz 1K` runs the fuzz infrastructure with the ReleaseSafe workaround for Zig issue 30655.
A short global budget can exercise only one fuzzer.
Separate filtered test builds give each operation its own budget.

### Fleet adapter

`just b test` tests every active target.
Repeated `--target` options select specific targets.
`--up` requests fleet startup through `ec2bench`.
Without `--up`, the command neither launches nor terminates instances.

The adapter builds two ReleaseFast binaries per target:

- The `zig_target` and `zig_cpu` from `bench.toml`.
- The same target with `baseline_cpu`: `x86_64` on x86 and `generic` on aarch64.

The x86 baseline binary selects its kernels at run time.
The adapter fails the baseline variant when `dispatch.level` differs from the target `zig_cpu`.
`fastmem-tests --x86-level LEVEL` tests one level instead of the detected level.

Targets run in parallel without CPU isolation.
Each target runs its two variants sequentially.
A failed variant does not prevent the other variant from execution.
The table reports both statuses and set availability.
Any failed build, transport, summary, or suite causes a nonzero exit.
JSON-less deaths retain their exit status in the error message, including exits 132 and 137.

Each `bench-results/<timestamp>-test/` directory contains:

- `manifest.json`, with source hash, Git state, Zig version, target configuration, and instance IDs.
- `summary.json`, with results and kernel identifiers for each target and variant.
- `<target>/<variant>/build/`, with the binary, build command, and build log.
- `<target>/<variant>/raw/`, with stdout JSON, stderr, exit status, and the remote binary.

The adapter preserves raw files after test failures and attempts their retrieval after transport failures.
`bench/tests/test_correctness.py` covers the adapter with fake builds, boxes, and fleet responses.

### Native validation of the framework

These correctness-suite runtimes came from Neoverse V3, not the named x86 hardware.
The native kernels passed each ceiling through `--max-size`.
The public set function was absent.

| Ceiling | Mode | Cases | Seconds |
|---|---|---|---|
| 1 MiB | ReleaseFast | 27,620,876 | 66.114 |
| 1 MiB | ReleaseSafe | 27,620,876 | 70.058 |
| 16 MiB | ReleaseFast | 27,620,964 | 70.590 |
| 67 MiB | ReleaseFast | 27,620,964 | 75.027 |
| 302 MiB | ReleaseFast | 27,620,964 | 116.574 |

A temporary builtin-set fixture passed 28,047,836 cases at 1 MiB, including ABI and constant-size paths.
The exact-count parser accepted its summary.
The copy and move fuzzers passed separate 10K budgets.
The set fixture also passed a separate 10K budget.

Fault injection now detects all three reviewed blind spots:

- A repeated 64 KiB source block fails at length 65537.
- The wrong 4K-alias dispatch fails at length 4095 and gap 3841.
- A disjoint move with the destination above the source faults on a one-byte source over-read.

All seven configured CPU builds and both baseline builds compile with only glibc dependencies.
Target-hardware execution remains the fleet acceptance gate.

### Correctness optimization modes

`bench test` defaults to `ReleaseFast`. The repeatable `--optimize` option also accepts `Debug` and `ReleaseSafe`.
Each mode runs both CPU variants. The manifest records the modes, and each variant retains separate build and execution files.
Non-default variant names include the mode, for example `target-Debug`.
Debug execution allows 3600 seconds per variant. Other modes retain the 600-second limit.
The summary parser rejects a binary whose optimization mode differs from the requested mode.

```sh
just b test --target c7i --target c8i --target c7a --target c8a --optimize ReleaseFast --optimize Debug --optimize ReleaseSafe
```
