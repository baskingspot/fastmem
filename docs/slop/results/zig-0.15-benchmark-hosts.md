> Historical. This file records the Zig 0.15.2 era, before the rewrite.
> It describes the old nushell harness and the old kernels, and its
> numbers predate the current measurement binary. Current results are in
> the other files of `docs/slop/results/`.

# Benchmark Hosts

This file is the human notebook for benchmark environments.
Raw evidence is collected automatically under `bench-results/`; this doc is where we summarize what each host has taught us.

## Targets

- `local`: Apple Silicon macOS development machine. Good for smoke checks and codegen iteration, not for final performance claims.
- `orb-arm64`: OrbStack NixOS VM on Apple Silicon. Good for Linux/aarch64 validation without AWS in the loop.
- `c7i`: AWS `c7i.large` (Intel Sapphire Rapids).
- `c7a`: AWS `c7a.large` (AMD Genoa).
- `c8g`: AWS `c8g.large` (Graviton4).

## Evidence Collected Per Run

Running `just bench-trial <target> --baseline-ref <ref> --label <label>` now saves:

- `comparison.txt`: benchmark deltas for baseline vs candidate
- `comparison.txt` now also includes candidate-side category geomeans for `copy/*` and `move/*` buckets, plus category-size geomeans so each size tier can be reviewed without collapsing everything into one ISA-wide rollup
- `trial.json`: top-level provenance for the trial
- `baseline/artifacts/<target>/host/summary.json`: structured host facts
- `baseline/artifacts/<target>/host/report.txt`: raw host/toolchain report
- `baseline/artifacts/<target>/asm/raw/*`: native assembly and LLVM IR emitted for that host
- `baseline/artifacts/<target>/asm/glibc-probe.json`: resolved libc path, base address, and runtime `memcpy` / `memmove` entry points on GNU/Linux hosts
- `baseline/artifacts/<target>/asm/raw/glibc-*.s`: host libc disassembly windows for `memcpy` / `memmove` on GNU/Linux hosts
- `baseline/artifacts/<target>/asm/symbols/raw/*`: symbol-level assembly slices
- `baseline/artifacts/<target>/asm/symbols/normalized/*`: normalized symbol slices for diffing
- `baseline/artifacts/<target>/asm/reference.md`: generated host-local asm reference for `fastmem_copy` / `fastmem_move` against glibc when available
- `asm-diffs/<target>/*.diff`: baseline vs candidate normalized assembly diffs
- `bench-results/asm-baselines/<target>.md`: latest stable asm baseline snapshot for that host, updated on each run

Candidate artifacts live in the matching `candidate/` tree.

## Suggested Review Loop

1. Run a saved trial on the host you care about.
2. Read `comparison.txt` to see whether the benchmark moved, then use the category geomeans to separate `copy` and `move` behavior and the category-size geomeans to see which size tiers actually shifted before drilling into row-level deltas.
3. Read `artifacts/<target>/host/summary.json` to confirm the exact environment.
4. Read `asm-diffs/<target>/*.diff` to see whether codegen changed for `fastmem_copy`, `fastmem_move`, `builtin_memcpy`, `builtin_memmove`, `glibc_memcpy`, or `glibc_memmove`.
5. Read `artifacts/<target>/asm/reference.md` for the current host-local asm baseline, then compare `artifacts/<target>/asm/symbols/raw/glibc-*.s` against the matching `fastmem_*` slices to see what libc is doing differently.
6. If you want the latest standing reference outside a specific trial directory, read `bench-results/asm-baselines/<target>.md`.
7. Add a short note in this file describing the result and any follow-up question.

## Learnings

### local

- Local Apple Silicon runs are useful for fast feedback, but they are too noisy for strong performance claims.
- Host facts and native `aarch64-macos-none` assembly are still worth capturing because they make local regressions and codegen changes easier to explain.

### orb-arm64

- No recorded learnings yet.

### c7i

- Verified with a full remote trial on March 6, 2026 using `c7i.large`.
- Host facts from the saved run:
  - CPU: `Intel(R) Xeon(R) Platinum 8488C`
  - OS: `NixOS 25.11`
  - Kernel: `6.12.74`
  - Toolchain: `zig 0.15.2`, `just 1.46.0`, `nix 2.31.2`
- Same-code repeatability looks good enough to trust the remote path:
  - Baseline vs candidate geomean delta on the no-libc run was about `+0.04%` for builtin and `+0.03%` for fastmem.
  - Baseline vs candidate geomean delta on the libc-linked run was about `-0.02%` for libc and `+0.03%` for fastmem.
- Implementation-level result on this host:
  - In the non-libc run, `fastmem` beat builtin by about `12.54%` geomean.
  - In the libc-linked run, `fastmem` beat builtin by about `6.60%` geomean, while libc was essentially tied with builtin on geomean.
- Native x86_64 assembly diffs were clean for the script-only worktree change:
  - `fastmem_copy`, `fastmem_move`, `builtin_memcpy`, and `builtin_memmove` all had no normalized asm differences.
- Operational note:
  - The first cold remote run paid noticeable Nix bootstrap time while fetching dependencies into the host store.
  - A fresh `c7i` trial on March 8, 2026 validated the refactored memcpy/memmove split and the richer report format end to end. The run was saved at `bench-results/trials/20260308-145300-c7i-split-size-report/`.
  - The new category-size tables made the current Intel shape much easier to read: `fastmem` is still strongest in `256B` to `1024B` copy tiers and in most forward-move tiers, while the remaining copy misses are now clearly concentrated at `64B` and some `4096B` copy rows rather than being hidden inside the full-suite geomean.
  - The autonomous loop also handled a low-disk condition on the long-lived host during the trial, ran the configured cleanup, and resumed successfully without manual intervention.
  - Follow-up exact-tier experiments on March 8, 2026 confirmed that `c7i` is sensitive to extra AVX2 medium-tier special cases. A generic exact `2 * stride` forward fast path improved `c8g`, but it regressed Intel `256B` misaligned and cross-lane copy rows enough to move the no-libc geomean in the wrong direction.
  - Narrowing that fast path back to the single-stride exact tier restored the healthy Intel shape. The latest `c7i` candidate at `bench-results/trials/20260308-155241-c7i-exact-stride-single/` is back to about `-8.48%` on `copy/all`, with `copy/all/256B` around `-10.69%` and `copy/cross-lane/256B` around `-9.72%`.

### c7a

- Verified with repeated full remote trials on March 6, 2026 using `c7a.large`.
- Host facts from the saved runs:
  - CPU: `AMD EPYC 9R14`
  - OS: `NixOS 25.11`
  - Kernel: `6.12.74`
  - Toolchain: `zig 0.15.2`, `just 1.46.0`, `nix 2.31.2`
- Implementation-level result on this host:
  - In the non-libc run, `fastmem` beat builtin by about `16.89%` geomean in one trial and `18.80%` geomean in a repeat run.
  - In the libc-linked run, `fastmem` beat builtin by about `7.43%` to `9.49%` geomean, while libc was roughly tied with builtin.
- Same-code repeatability is materially noisier here than on `c7i` or `c8g`:
  - One same-code trial moved builtin by `+8.16%` geomean and libc by `-2.80%`, while fastmem stayed near flat at `-0.18%`.
  - A second same-code trial moved builtin by `-1.82%` geomean and fastmem by `+5.03%`, while libc-linked builtin, fastmem, and libc all stayed within about `0.16%`.
  - The biggest swings clustered in the non-libc `16384B` copy rows rather than across the whole suite.
- After hardening the harness to align measured windows to a fixed `16 KiB` boundary, a same-worktree rerun pair tightened the non-libc geomean drift to about `+0.66%` for builtin and `+0.15%` for fastmem.
- The alignment change helped, but it did not remove all noise:
  - libc-linked same-worktree reruns still moved by about `+3.67%` for builtin, `+2.38%` for fastmem, and `+3.65%` for libc.
  - A few `16384B` misaligned copy rows still move by several percent even when normalized asm is identical.
- Native x86_64 assembly diffs were clean across the script-only comparisons:
  - `fastmem_copy`, `fastmem_move`, `builtin_memcpy`, and `builtin_memmove` all had no normalized asm differences.
- Operational note:
  - The remote path itself looks sound on `c7a`, but the remaining large-copy drift still needs either repeated-trial policy or further benchmark-harness hardening before we trust sub-5% changes.
  - On March 8, 2026 the long-lived `c7a` host hit `0 KiB` free during a remote asm/glibc-capture run. After adding an extra free-space preflight and cleanup before remote asm collection, the rerun at `bench-results/trials/20260308-152938-c7a-exact-stride-forward/` completed successfully and saved the expected asm artifacts without another manual recovery step.

### c8g

- Verified with a full remote trial on March 6, 2026 using `c8g.large`.
- Host facts from the saved run:
  - CPU: `Neoverse-V2`
  - OS: `NixOS 25.11`
  - Kernel: `6.12.74`
  - Toolchain: `zig 0.15.2`, `just 1.46.0`, `nix 2.31.2`
- Same-code repeatability looks excellent on this host:
  - Baseline vs candidate geomean delta on the no-libc run was about `-0.01%` for builtin and `+0.07%` for fastmem.
  - Baseline vs candidate geomean delta on the libc-linked run was about `-0.01%` for builtin, `-0.01%` for fastmem, and `-0.01%` for libc.
- Implementation-level result on this host:
  - In the non-libc run, `fastmem` trailed builtin by about `5.96%` geomean.
  - In the libc-linked run, `fastmem` trailed builtin by about `21.85%` geomean, while libc was essentially tied with builtin on geomean.
- Follow-up libc-floor trials on March 6, 2026 showed that `c8g` needs an explicit glibc floor, not just a Zig builtin fallback:
  - Delegating large linked-libc copies at `1024B+`, large moves at `1024B+`, and `dest > src` moves at `256B+` brought the libc-linked `fastmem` geomean to about `-0.47%` vs builtin, with libc itself at about `-0.01%`.
  - The useful implementation lesson was that calling explicit `memcpy` / `memmove` symbols worked better than relying on `@memcpy` / `@memmove` lowering for the floor path.
  - The remaining misses are narrow backward-overlap rows rather than whole-path failures: `256B` still trails by about `1%` to `3%`, while `64B` backward rows are within about `0.6%`.
  - At this point, libc-linked `c8g` is good enough to use for real issue-finding because the large-copy and large-move regressions are gone and the remaining gap is small and well localized.
- Two more implementation-focused trials on March 6, 2026 turned the raw asm comparison into a concrete codegen win:
  - Capturing live glibc slices identified the actual targets as `__memcpy_sve` and `__memmove_sve`, and both large bodies align the hot loop around source loads instead of destination stores.
  - Matching that source-oriented alignment in `fastmem` fixed the worst non-libc `c8g` regressions. The no-libc geomean moved from about `+6.13%` slower than builtin to about `-8.33%`, and then to about `-9.40%` after also lowering the forward-move peel floor for Neoverse-V2.
  - The biggest concrete wins were the rows we originally flagged as "bad": misaligned `4096B` copy went from about `+59%` slower to about `-10%` faster than builtin, `gap=17` backward `4096B` move went from about `+9%` slower to about `-24%`, and `gap=17` forward `1024B` move went from about `+16%` slower to about `-6%`.
  - After the source-alignment work, libc-linked `c8g` stayed essentially on the floor at the geomean level, around `+0.18%` vs builtin and `+0.01%` vs libc in the latest rerun.
  - The remaining no-libc gaps on `c8g` are now much narrower and more specific: large aligned copy (`4096B` and `16384B`), plus small `64B` and cross-lane `256B` copy tiers.
  - An exact-tier follow-up on March 8, 2026 fixed the worst remaining small-copy issue without disturbing the large-copy picture. Adding a single-stride exact fast path moved `copy/all/64B` from about `+12.62%` slower than builtin to about `+0.49%`, and moved aligned `64B` copy to near parity, while keeping the large aligned `4096B` and `16384B` misses as the main remaining `memcpy` problem.
  - A broader exact `2 * stride` fast path also helped `c8g`, but it hurt Intel badly enough that we kept only the single-stride version. The latest stable `c8g` reference remains `bench-results/trials/20260308-155235-c8g-exact-stride-single/`: `move/fwd/all` is about `-12.56%`, `move/bwd/all` is about `-18.13%`, `copy/all/64B` is effectively fixed, and the remaining copy gap is concentrated in large aligned `16384B` plus some `256B` cross-lane rows.
- GNU/Linux asm capture now also saves live glibc `memcpy` / `memmove` disassembly for this host:
  - The first `c8g` smoke run captured `glibc_memcpy` and `glibc_memmove` slices successfully from resolved address windows in `libc.so.6`.
  - The follow-up symbol-recovery pass now resolves those windows to `__memcpy_sve` and `__memmove_sve`, so we can compare the actual glibc implementations directly against `fastmem_*`.
- Native aarch64 assembly diffs were clean for the script-only worktree change:
  - `fastmem_copy`, `fastmem_move`, `builtin_memcpy`, and `builtin_memmove` all had no normalized asm differences.

## Operational Gaps

- A fresh remote host still pays wall-clock warm-up cost while `nix develop` hydrates the toolchain and dependencies, but that setup time is outside the recorded benchmark outputs.
- Long-lived `20G` AWS roots can fill with Nix/store state over repeated trials. The runner now does a remote preflight cleanup (`.zig-cache`, `zig-out`, `bench-results`, `nix-collect-garbage -d`) before syncing when free space drops below `4 GiB`, but host disk size is still a real capacity constraint.
- `trial` assumes the target already exists and is reachable; it does not yet provision, warm, or tear down infrastructure itself.
- Failed trials are informative but not resumable yet. The first `c7i` attempt produced usable benchmark outputs and host summaries, but we still had to rerun the full trial after fixing asm collection.
- The asm capture path currently relies on a small native-target naming heuristic (`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`). It works for our current hosts, but it is still a heuristic.
- We collect raw evidence automatically, but the human learnings file is not auto-updated by the benchmark runner yet.
- We still need repeated remote trials per host to establish the real noise floor before trusting very small changes, especially on `c7a`.
- The `16 KiB` alignment change materially improved `c7a` non-libc repeatability, but libc-linked `c7a` runs and a few large misaligned copy rows still drift by a few percent even with identical normalized asm.
