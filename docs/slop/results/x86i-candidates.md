# x86i candidate report

Branch: `x86i`.
Base after rebase: `4a9199e88c2e1d161ed11c2c4e1bdbb5ba5c8d86`.
Rework code commit: `7837838`.
Worktree: `/Users/matt/code/worktrees/fastmem-zig/x86i`.
Date: 2026-09-29.

These candidates remain opt-in. The default experiment remains `auto`.
No fleet measurement ran in this lane. This report makes no performance claim.

## Candidates

| Experiment | CPU and operation scope | Hypothesis |
|---|---|---|
| `-Dx86-experiment=x86i_chunks` | Intel copy/move/set through 1 KiB. Zen 4 and Zen 5 set at 129–192 B. | Fewer redundant vector transfers offset the cost of another size comparison. |
| `-Dx86-experiment=x86i_endpairs` | Intel copy/move and all four fleet models for set, at 64–256 B. | Shared endpoints before the inner-pair comparison improve scheduling and reduce duplicated instruction bytes. |
| `-Dx86-experiment=x86i_mask16` | Zen 4 C-ABI move at 0–16 B. | One masked XMM snapshot replaces the scalar size ladder and its duplicate endpoint transfers. |

Each candidate preserves the measured selections outside its named experiment.
The inline classes and dispatch stub limit remain unchanged.
The Zen 5 temporal fill loop remains the measured 256-byte loop.
The candidates do not change the default REP or NT thresholds.

### `x86i_chunks`

The existing medium path already uses overlapping head and tail vectors.
This experiment subdivides its classes rather than repeat the rejected YMM or medium-entry candidates.
All source loads precede every destination store.

| Byte range | Existing vector count | Candidate count | Scope |
|---|---:|---:|---|
| 129–192 | 4 | 3 | Intel copy/move/set and AMD set |
| 257–320 | 6 | 5 | Intel copy/move/set |
| 385–448 | 8 | 7 | Intel copy/move/set |
| 513–640 | 12 | 10 | Intel copy/move/set |
| 769–896 | 16 | 14 | Intel copy/move/set |

The 64–128 B class retains its existing two vectors.
The other medium sizes retain their existing vector counts.

### `x86i_endpairs`

A shared fragment serves 64–256 B after an outer size bound.
Copy and move load the first and last ZMM vectors before the 128-byte comparison.
The 129–256 B class adds the inner pair, then stores all four snapshots.
Set broadcasts once and stores the endpoints before the inner-pair comparison.

This experiment changes pair scheduling, not vector width or entry fallthrough.
The earlier `x86f_pairs` experiment changed the short scalar classes instead.
The bounded dispatch entry omits the inner comparison because its caller already excludes lengths through 128 B.

### `x86i_mask16`

The Zen 4 move entry selects one masked XMM load and store for lengths through 16 B.
The mask contains exactly the lowest `n` bits.
The zero mask permits null pointers for the zero-length C-ABI operation.
The fragment uses `xmm16` and an input operand in `k1`, without `vzeroupper`.

The codegen trace contains ten instructions, including one entry branch, for each length from zero through sixteen.
The selected fragment contains no branch.
The public inline move path and copy entry retain their existing implementations.
Baseline dispatch handles these lengths in its existing stub, so this candidate targets the explicit Zen 4 build.

## Initial local results

The host is aarch64 Linux. The toolchain is Zig 0.16.0 from the repository flake.

| Gate | `x86i_chunks` | `x86i_endpairs` | `x86i_mask16` |
|---|---|---|---|
| Native `zig build test`, Debug | 333/333 steps, 39/39 tests | 333/333 steps, 39/39 tests | 333/333 steps, 39/39 tests |
| Native `zig build` | 10/10 steps | 10/10 steps | 10/10 steps |
| `just codegen-x86` with experiment | 24/24 steps | 24/24 steps | 24/24 steps |
| ReleaseFast unit and guard cross-builds | Four fleet CPUs passed | Four fleet CPUs passed | Four fleet CPUs passed |
| Lint of `/Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/` | Passed | Passed | Passed |
| Full-tree lint | 20 baseline warnings | 20 baseline warnings | 20 baseline warnings |

The default `just test` and default codegen gate also passed.
The export gate matched the aarch64 GOLDEN bytes for generic and all three Neoverse models.
No aarch64 file changed.

Each codegen run covers six CPU models and 4,224 fixed-size consumers.
The gate checks bounds, complete byte coverage, and source snapshots for every medium length.
New checks pin reduced vector counts, endpoint order, mask arithmetic, and masked accesses.
Mutation tests reject changes to those properties.

The native test graph also runs baseline x86 tests under QEMU.
Its emulated Sapphire Rapids and Genoa configurations select AVX2, not AVX-512.
These results do not establish hardware correctness for the new AVX-512 fragments.

The focused unit suite adds zero-length move calls with null pointers and every medium fill length through 1 KiB.
The cross-builds compile those tests for each fleet CPU.

### Commands

The following procedure reproduces the candidate gates.

```sh
cd /Users/matt/code/fastmem-zig
eval "$(nix print-dev-env)"
cd /Users/matt/code/worktrees/fastmem-zig/x86i
for experiment in x86i_chunks x86i_endpairs x86i_mask16; do
  zig build test -Dx86-experiment="$experiment" --summary all
  zig build -Dx86-experiment="$experiment" --summary all
  just --justfile /Users/matt/code/worktrees/fastmem-zig/x86i/Justfile codegen-x86 \
    -Dx86-experiment="$experiment" --summary all
  for cpu in sapphirerapids graniterapids znver4 znver5; do
    zig build test-unit-bin test-bin -Dtarget=x86_64-linux-gnu \
      -Dcpu="$cpu" -Doptimize=ReleaseFast -Dx86-experiment="$experiment" \
      --prefix "/Users/matt/code/worktrees/fastmem-zig/x86i/zig-out/$experiment/$cpu" \
      --summary all
  done
done
ziglint /Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/
ziglint /Users/matt/code/worktrees/fastmem-zig/x86i/src/
just --justfile /Users/matt/code/worktrees/fastmem-zig/x86i/Justfile test
```

Local logs reside in `/Users/matt/code/worktrees/fastmem-zig/x86i/.zig-cache/x86i-evidence/`.
The directory is ignored and is not part of the commit.

## Review correction and re-proof

The Opus review rejected the initial commit for default codegen drift.
The inner `finer_*_chunks` branches changed register allocation in `x86_64.move.kernel` and `x86_64.set.kernel` despite their false default flags.
The return-register move shifted to individual returns, and the set kernel grew approximately 27 bytes.
The drift affected all five AVX-512 models in the gate.
The endpoint block did not cause the drift.

Each operation now selects a separate inline `finerChunks` function through a top-level comptime return in `mediumReordered`.
The original `mediumChunks` bodies match main again.
The default `mediumReordered` classes contain no finer-class branches.
The dead `finer_move_chunks and n <= 192` condition is absent.
The candidate retains its nested class tree and vector counts.

The lane rebased onto main `4a9199e88c2e1d161ed11c2c4e1bdbb5ba5c8d86`.
The conflict resolution retains main's NT policy and removal of stale `streamGrouped` requirements.
The stricter Zen 5 check also covers `auto`: four aligned stores advance 256 bytes in seven instructions.
Its three mutations pin that loop shape.

The endpoint comparison lookup now reports `missing endpoint inner-pair comparison` instead of an uncaught `StopIteration`.
A new mutation replaces `cmpq $0x80` with `cmpq $0x81` in the set kernel.
That mutation reproduced the crash before the fix and passes after it on all four fleet models.
The `endpoint_move` check still lacks a dedicated mutation test.
Existing byte-coverage checks still exercise every medium length and verify each source snapshot.

### Default byte identity

Fresh `git archive` trees of main and the reworked lane supplied the default probes.
Both source paths have equal lengths: `/tmp/x86i-reproof.i6UtAM/main` and `/tmp/x86i-reproof.i6UtAM/head`.
Each tree ran `zig build codegen-x86 --summary all` with the flake toolchain and default options.
Both archive builds passed all 24 steps.

The comparison uses complete `llvm-objdump -dr` output, including instruction bytes and relocations.
Normalization replaces only the object pathname with `PROBE`.
The comparison retains every instruction detail and symbol address.
A separate comparison checks each entire raw `.text` section from `llvm-objcopy --dump-section`.
All six models have empty disassembly diffs and identical `.text` bytes.

| CPU model | Normalized disassembly diff | Raw `.text` comparison | `.text` bytes |
|---|---|---|---:|
| `x86_64_v3` | Empty | Identical | 22,145 |
| `x86_64_v4` | Empty | Identical | 41,744 |
| `sapphirerapids` | Empty | Identical | 44,240 |
| `graniterapids` | Empty | Identical | 43,584 |
| `znver4` | Empty | Identical | 42,656 |
| `znver5` | Empty | Identical | 42,704 |

The proof covers every function in each probe, not only the two kernels from the review.
Debug metadata can differ because source locations differ.
The temporary proof directory contains these artifacts:

- Archive SHAs
- Build logs
- Disassembly files
- Raw sections
- Per-model diffs

### Gates after rework

| Gate | Result |
|---|---|
| Default `zig build test --summary all` | 333/333 steps, 39/39 tests |
| Default `zig build --summary all` | 10/10 steps |
| `just codegen-x86`, `auto` | 24/24 steps, all six models |
| `just codegen-x86`, `x86i_chunks` | 24/24 steps, all six models |
| `just codegen-x86`, `x86i_endpairs` | 24/24 steps, all six models |
| `just codegen-x86`, `x86i_mask16` | 24/24 steps, all six models |
| `ziglint /Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/` | Passed |
| `git diff --check` | Passed |

The first default test invocation exceeded its 120-second tool timeout.
The repeat invocation used a 600-second timeout and passed.
Rework logs use the `rework-` prefix in `/Users/matt/code/worktrees/fastmem-zig/x86i/.zig-cache/x86i-evidence/`.

### Reproduction

The following procedure reproduces the rework gates and archive inputs.

```sh
cd /Users/matt/code/fastmem-zig
eval "$(nix print-dev-env)"
cd /Users/matt/code/worktrees/fastmem-zig/x86i
zig build test --summary all
zig build --summary all
for experiment in auto x86i_chunks x86i_endpairs x86i_mask16; do
  just --justfile /Users/matt/code/worktrees/fastmem-zig/x86i/Justfile codegen-x86 \
    -Dx86-experiment="$experiment" --summary all
done
ziglint /Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/
root=$(mktemp -d /tmp/x86i-reproof.XXXXXX)
mkdir "$root/main" "$root/head"
git -C /Users/matt/code/fastmem-zig archive 4a9199e88c2e1d161ed11c2c4e1bdbb5ba5c8d86 | tar -x -C "$root/main"
git -C /Users/matt/code/worktrees/fastmem-zig/x86i archive HEAD | tar -x -C "$root/head"
for tree in main head; do
  (cd "$root/$tree" && zig build codegen-x86 --summary all)
done
python3 - "$root" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
for cpu in ("x86_64_v3", "x86_64_v4", "sapphirerapids", "graniterapids", "znver4", "znver5"):
    disassembly, sections = [], []
    for tree in ("main", "head"):
        obj = root / tree / "zig-out/codegen" / f"{cpu}.o"
        text = subprocess.check_output(["llvm-objdump", "-dr", str(obj)], text=True)
        disassembly.append(text.replace(str(obj), "PROBE"))
        section = root / f"{tree}-{cpu}.text"
        subprocess.run(["llvm-objcopy", f"--dump-section=.text={section}", str(obj)], check=True)
        sections.append(section.read_bytes())
    assert disassembly[0] == disassembly[1], f"{cpu}: disassembly drift"
    assert sections[0] == sections[1], f"{cpu}: instruction byte drift"
    print(f"{cpu}: identical disassembly and {len(sections[0])} instruction bytes")
PY
```

## Lint exception

The initial full-tree lint returned exit status 1 for 20 unchanged warnings outside `/Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/`.
The supervisor directed this lane to document those warnings and leave the unrelated files unchanged.
The rework passes lint for `/Users/matt/code/worktrees/fastmem-zig/x86i/src/x86_64/`.

## Residual risks

- AVX-512 hardware correctness and fleet performance remain untested.
- Extra size comparisons can outweigh the reduced transfer count.
- Shared endpoint fragments add an outer bound and change instruction layout.
- Masked accesses near guard pages can incur assists despite architectural fault suppression.
- Dependent reads after masked stores can expose forwarding costs.
- The Zen 4 A/A noise from the scorecard still requires careful fleet interpretation.
- The byte-identity proof covers default codegen probes, not every possible consumer or explicit override.
- The `endpoint_move` check lacks a dedicated mutation test.
- Full-tree lint remains red on the documented baseline warnings.

The parent must run hardware correctness and review before merge.
Fleet acceptance still requires measurements against the rebased main and the scorecard baselines.
