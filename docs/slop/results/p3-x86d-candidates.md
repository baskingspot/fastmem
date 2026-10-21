# P3-x86d: Intel medium-size challengers

## Status

The implementation commit is `8149504`, on top of `be859b1`.
The default remains `auto`. No candidate has fleet measurements.
The parent and a cross-family reviewer decide acceptance.

| Fleet branch | Effective selection | Changed models | Question |
|---|---|---|---|
| `fleet/p3-x86d-medium-first` | `medium_first` | Granite Rapids | Does earlier dispatch within one aligned instruction line remove the small gap? |
| `fleet/p3-x86d-ymm-medium` | `ymm_medium` | Granite Rapids | Does 32-byte memory width help despite twice as many instructions? |
| `fleet/p3-x86d-straight-1k` | `straight_1k` | Both Intel models | Does a straight-line 513–1024 B class beat the loop and its setup? |

The fleet revisions are:

- `56c267a`: `fleet/p3-x86d-medium-first`.
- `e311ed6`: `fleet/p3-x86d-ymm-medium`.
- `2bae565`: `fleet/p3-x86d-straight-1k`.

Each branch changes only the build default relative to the common implementation.
Explicit experiment selections retain the measured defaults on other models.
The tuning table is `src/x86_64/tuning.zig:8–85`.
The corresponding implementation names contain the selected variant, such as `x86-avx512-medium_first-v3`.

## Evidence sources

The input run is `bench-results/20260924T201905Z-p3-x86c/`, compact revision `4d59aeb`, five rounds.
Its raw directory lives in the P3-x86c worktree.
`docs/slop/results/p3-x86d-input-rows.json` preserves the relevant rows, confidence intervals, and outlier flags.
No outlier was removed. The paired confidence level is 93.75%.
The tables below report point estimates, not acceptance verdicts.

The libc object is `/Users/matt/code/fastmem-zig/.bench-cache/glibc/libc-x86_64-linux-gnu.so.6`.
Both Intel hosts resolve move/copy to `0x196380` and set to `0x196c00` in that same libc.
The source is the input run's `summary.json`, under `targets.<target>.protocol.libc_probe`.
Only behavioral observations appear here. No glibc source or disassembly enters this repository.

The local binaries use Zig 0.16.0, ReleaseFast, and each CPU from `bench.toml`.
Their paths are `/tmp/x86d-install-<selection>-<target>/bin/bench-fastmem`.
The selections are `auto`, `medium_first`, `ymm_medium`, and `straight_1k`.
The Intel target names are `c7i` and `c8i`.

## Granite Rapids: 65–256 B

### The gap is a faster libc, not slower fastmem

| Case | c7i fastmem / libc, ns | c8i fastmem / libc, ns | c8i ratio |
|---|---|---|---|
| copy/aligned/128 | 1.620 / 1.625 | 1.543 / 1.035 | 1.490 |
| copy/page-offset/128 | 1.619 / 1.623 | 1.543 / 1.036 | 1.489 |
| copy/misaligned/128 | 1.625 / 1.625 | 1.549 / 1.328 | 1.166 |
| copy/aligned/256 | 2.166 / 2.163 | 1.821 / 1.584 | 1.150 |
| copy/misaligned/256 | 2.449 / 2.456 | 2.326 / 2.326 | 1.000 |
| set/aligned/128 | 2.168 / 2.168 | 2.057 / 1.148 | 1.793 |
| set/misaligned/128 | 2.169 / 2.163 | 2.059 / 1.292 | 1.589 |
| set/aligned/256 | 2.344 / 2.393 | 2.183 / 1.736 | 1.255 |
| set/misaligned/256 | 2.439 / 2.440 | 2.326 / 2.326 | 1.000 |

These rows come from `p3-x86d-input-rows.json`.
Fastmem improves modestly on Granite Rapids. Libc improves substantially more on aligned short classes.
The unaligned 129–256 B cases remain at parity.
This pattern supports an exposed dispatch bottleneck after faster memory execution, but does not prove the mechanism.

### Dispatch and layout

Both local `auto` binaries have identical move and set entry instructions.
Move starts at `0x108d650`, and set starts at `0x108d510`.
Both starts have offset 16 within a 64-byte instruction line.

For 65–128 B, fastmem move visits three size branches before its first load at `0x108d6fb`.
Its first two branches are taken, across separate instruction lines.
The final load/store block crosses a 64-byte boundary.
Libc visits two size branches and loads its first vector at `0x19638d`, before the second branch.
Its entire 65–128 B path fits inside the first aligned 64-byte line.

Fastmem set also visits three size branches before its broadcast at `0x108d56d`.
Libc broadcasts at `0x196c04`, before either size branch.
Its 65–128 B path fits inside one aligned line.
The fastmem return at `0x108d581` lies in the next line after its first store.

At 129–256 B, fastmem move visits four size branches, versus five for libc.
Fastmem set and libc each visit four.
Thus total branch count alone cannot explain that class.
Earlier memory issue and layout remain hypotheses, not established cycle attribution.

The `medium_first` candidate puts the 64–128 B path first and aligns both entries to 64 bytes.
It uses two branches for 64–128 B and three for 129–256 B.
Its Granite move entry starts at `0x108d6c0`, with its first load at `+0x12` and return at `+0x2e`.
Its set entry starts at `0x108d580`, with its broadcast at `+0x12` and return at `+0x26`.
Both 64–128 B paths fit inside one instruction line.

The candidate does not hoist the broadcast above dispatch or preload the first vector.
It tests dispatch and entry layout together, not either factor independently.
The branch hint and alignment originate in independent Zig code, not a translation of libc instructions.

### Store width and alias hypotheses

Libc and fastmem both use two or four 64-byte stores, with ZMM16–19 for copy and ZMM16 for set.
Neither small path needs `vzeroupper`.
Therefore different store width or register cleanup does not explain the existing gap.
The relevant addresses are fastmem `0x108d6fb–0x108d75b` and libc `0x19638d–0x196470`.

Granite-specific ZMM store-port throughput remains unverified.
The `ymm_medium` candidate tests the alternative with four or eight 32-byte loads/stores over 64–256 B.
It retains the compact dispatch and high register bank.
It does not change inline widths or the large loops.
Extra instructions and different instruction placement prevent a clean attribution to a particular port.

`src/bench_fastmem.zig:589–606` sets copy offsets to `(0,0)`, `(1,3)`, `(31,16)`, and `(0,2048)` on Intel.
Separate anonymous mappings start at page boundaries (`src/bench_fastmem.zig:644–677`).
The page-offset profile does not cross a page for these lengths.
Its low-address difference also avoids the zero-residue 4K alias condition.
Yet its 128-byte gap matches the aligned profile almost exactly.
A simple 4K-alias explanation does not fit these small-copy rows.
Set has no source loads, so a source/destination alias cannot explain its larger gap.

## Both Intel models: 257–1024 B copy

### Two different classes

The entire 257–512 B range already uses straight-line code in both implementations.
Fastmem starts its eight-vector class at `0x108d765`.
Libc starts the corresponding behavior at `0x1964a6`, after two earlier vector loads.
Both use eight loads before eight stores. Neither uses a loop or `vzeroupper`.

Aligned 384/512 B copy is about 1.11x libc on c7i and 1.10x on c8i.
Misaligned and cross-lane cases are approximately 1.00x.
The delayed first loads and dispatch layout remain plausible causes.
The Granite medium-first candidate removes one dispatch branch from this class too.
The straight-1k candidate does not specifically repair the 257–512 B class.

Above 512 B, both implementations enter a directional vector loop.
Thus the existing difference is not loop versus straight-line libc.
The candidate introduces that comparison for the first time.

| Case | c7i ratio | c8i ratio |
|---|---|---|
| copy/aligned/768 | 1.396 | 1.244 |
| copy/aligned/1024 | 1.333 | 1.250 |
| copy/page-offset/768 | 1.738 | 1.330 |
| copy/page-offset/1024 | 1.521 | 1.422 |
| copy/misaligned/768 | 1.056 | 1.063 |
| copy/misaligned/1024 | 1.020 | 1.065 |

### Direction, setup, and alignment

Fastmem's page-offset rows select its forward path through the alias test at `0x108dcb8`.
Aligned rows select its backward path because their page offsets match.
The policy is explicit in `src/x86_64/move.zig`, function `large`.
Libc also has direction and alias dispatch above 512 B, at `0x196510–0x196540`.

Fastmem pays the compact entry ladder and a tail transfer before this dispatch.
Its forward path also pays LLVM's loop remainder setup at `0x108ddd0–0x108ddf1`.
The setup supports a fourfold-unrolled loop that these 768/1024-byte cases never reach.
They execute only the remainder loop at `0x108de00`.
Libc uses a simpler four-vector loop at `0x196580`.
Fastmem uses low vector registers and `vzeroupper`. Libc retains high registers without that cleanup.

Both relevant forward loop heads are 64-byte aligned in these binaries.
Both fastmem backward loop heads also have 64-byte alignment.
Loop-head alignment alone therefore does not explain these particular rows.
Entry overhead, remainder setup, and cleanup provide concrete differences before any Granite-specific port hypothesis.

`straight_1k` extends only the Intel ABI move/copy class through 1024 B.
It loads sixteen 64-byte vectors into ZMM16–31 before any store.
The class has no direction test, alias dispatch, loop, or vector cleanup.
The source is `src/x86_64/ops.zig`, function `highMove`, and `src/x86_64/move.zig`, function `mediumReordered`.
All overlapping moves remain safe because every source load precedes every destination store.

## Local checks

`docs/slop/results/p3-x86d-local.json` records the commands and results.

| Check | Result |
|---|---|
| `zig build test -j6 --summary all` | 212/212 steps, 27/27 tests |
| Each fleet revision: `zig build test codegen-x86` | 230/230 steps, 27/27 tests |
| Each fleet revision: default-selection install | All seven targets: 21 additional builds |
| `zig build install` | All seven targets, default and three candidates: 28 builds |
| `codegen-x86` | All eight selections, five CPUs each |
| Gate mutation tests | Both Intel objects reject wrong selections and damaged large paths |
| Candidate Safe/Debug guard and unit builds | Eight model/selection/mode combinations |
| QEMU x86_64_v3 ReleaseFast unit execution | 26/26 tests |
| ABI overlap matrix | Extended from 512 through 1024 B |
| `asm-all` | Default and three candidates pass |
| Aarch64 GNU/musl/macOS instruction bytes | Identical to `be859b1` for all selections |
| Aarch64 exported kernel pins | All four GOLDEN checks pass, without changes |
| Unselected x86 models | Probe `.text` matches `be859b1` exactly |
| `ziglint src/x86_64/` | Pass |
| `ziglint src/` | Existing warnings outside this lane |

No local guard matrix ran. No AWS command or fleet launch ran.
The local host cannot execute the changed AVX-512 paths.
Safe/Debug compilation and static checks do not replace hardware correctness tests.

## Fleet procedure

Create separate candidate worktrees:

```sh
for name in medium-first ymm-medium straight-1k; do
  git -C /Users/matt/code/fastmem-zig worktree add --detach \
    "/tmp/p3-x86d-fleet-$name" "fleet/p3-x86d-$name" || exit
  for state in .terraform terraform.tfstate bench.pem; do
    ln -s "/Users/matt/code/fastmem-zig/infra/base/$state" \
      "/tmp/p3-x86d-fleet-$name/infra/base/$state" || exit
  done
done
```

Run the hardware guard matrices without launches:

```sh
for name in medium-first ymm-medium straight-1k; do
  nix develop "/tmp/p3-x86d-fleet-$name" -c just \
    --justfile "/tmp/p3-x86d-fleet-$name/Justfile" b test \
    --target c7i --target c8i --target c7a --target c8a \
    --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug || exit
done
```

After all matrices pass, run the interleaved standard suite with the default A/A control:

```sh
nix develop /Users/matt/code/fastmem-zig -c just \
  --justfile /Users/matt/code/fastmem-zig/Justfile b run \
  --rev be859b1 \
  --rev fleet/p3-x86d-medium-first \
  --rev fleet/p3-x86d-ymm-medium \
  --rev fleet/p3-x86d-straight-1k \
  --target c7i --target c8i --target c7a --target c8a \
  --suite standard --rounds 5 --label p3-x86d
```

Run the large suite for regression evidence:

```sh
nix develop /Users/matt/code/fastmem-zig -c just \
  --justfile /Users/matt/code/fastmem-zig/Justfile b run \
  --rev be859b1 \
  --rev fleet/p3-x86d-medium-first \
  --rev fleet/p3-x86d-ymm-medium \
  --rev fleet/p3-x86d-straight-1k \
  --target c7i --target c8i --target c7a --target c8a \
  --suite large --rounds 5 --label p3-x86d-large
```

## Residual risks

- Medium-first adds a branch to scalar copy/move and small set paths. Distribution cases must decide the tradeoff.
- YMM doubles the memory instruction count over 64–256 B. Its wider instruction footprint can outweigh any store-width benefit.
- Straight-1k performs redundant accesses below 1024 B and uses unaligned stores. Misaligned and overlapping cases can regress.
- All candidates move later functions in the executable. Address changes can affect otherwise unchanged large kernels.
- The first candidate combines dispatch order and alignment. The fleet can select it without proving either mechanism independently.
- The straight-1k candidate leaves the c7i 257–512 B gap unresolved except for incidental layout effects.
- AVX-512 hardware correctness and performance remain untested. No G1, G2, or G3 acceptance claim follows from these checks.
