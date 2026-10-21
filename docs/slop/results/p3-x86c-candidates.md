# P3-x86c: small ABI candidates

## Status

The default remains `high_regs`. Neither candidate has fleet measurements.
The parent and a cross-family reviewer decide acceptance.
The baseline evidence is `bench-results/20260924T101602Z-p3-x86b`, summarized in `docs/slop/results/small-path-ab.md`.

The implementation commits are `f47d58a` and `717eddb`.
The first commit fixes the codegen gate. The second adds two optional candidates.

| Fleet revision | Build selection | Purpose |
|---|---|---|
| `a29a7cc` / `fleet/p3-x86c-control` | `-Dx86-variant=high_regs` | Unchanged baseline |
| `c920df7` / `fleet/p3-x86c-tiered` | `-Dx86-variant=tiered` | Fewer medium branches and shorter 8–16 B dispatch |
| `47ef8f9` / `fleet/p3-x86c-compact` | `-Dx86-variant=compact` | Fewer medium branches and compiler-rt-style short classes |

The two fleet commits change only the build default relative to `717eddb`.
The harness accepts revisions, not per-revision Zig options.
The old `entry` option remains available but is not a candidate for this run.

## Disassembly diagnosis

The reference binaries use Zig 0.16.0, ReleaseFast, and the CPUs from `bench.toml`.
The baseline Intel binary is `/tmp/p3-x86c-control-intel/bin/bench-fastmem`.
The baseline AMD binary is `/tmp/p3-x86c-baseline/bin/bench-fastmem`.
The candidate binaries use `/tmp/p3-x86c-<variant>-<cpu>/bin/bench-fastmem`.
The CPUs in those candidate paths are `sapphirerapids` and `znver4`.

The glibc reference is `/Users/matt/code/fastmem-zig/.bench-cache/glibc/libc-x86_64-linux-gnu.so.6`.
Only behavioral facts appear below. No glibc source or disassembly enters this change.

### 65–256 B copy and set

Baseline Intel `x86_64.move.kernel` starts at `0x108d660`.
Its 65–128 B dispatch visits five conditional branches before the first load at `0x108d71c`.
Its 129–256 B path visits six before the first load at `0x108d745`.
The initial checks for 16, 32, and 512 bytes precede the useful medium checks.

The glibc move entry at `0x196380` takes two conditional branches for 65–128 B.
Its first load at `0x19638d` precedes the second size check.
Its 129–256 B path takes five conditional branches, including the REP threshold check at `0x196480`.
Both implementations use two or four 64-byte loads and stores in ZMM16–19.
Neither path needs `vzeroupper`. Vector splitting does not explain this gap.

Baseline Intel `x86_64.set.kernel` starts at `0x108d510`.
Its 65–128 and 129–256 B paths take five and six conditional branches.
The glibc set entry at `0x196c00` takes two and four, respectively.
Both use one broadcast to ZMM16 and two or four 64-byte stores.
The glibc broadcast precedes dispatch. The baseline broadcast follows dispatch.

These counts include all executed instructions through return, including glibc `endbr64`.
They exclude caller instructions. Each compare and branch counts separately.

| Operation and size | Baseline instructions / branches | glibc instructions / branches | Both candidates instructions / branches |
|---|---:|---:|---:|
| copy/move 65–128 | 16 / 5 | 11 / 2 | 12 / 3 |
| copy/move 129–256 | 22 / 6 | 21 / 5 | 18 / 4 |
| set 65–128 | 15 / 5 | 10 / 2 | 11 / 3 |
| set 129–256 | 19 / 6 | 16 / 4 | 15 / 4 |

The gate checks these branch counts on all four fleet CPU models.
Copy and move share the same ABI kernel. Different fleet tier ratios do not imply different fastmem instruction paths.
Their benchmark cases and the reference implementations differ.

### Compiler-rt small wins

Intel `compiler_rt.memmove.memmoveFast` starts at `0x10a2820` in the baseline Intel binary.
AMD starts at `0x10a5f10` in the baseline AMD binary.
Both use two conditional branches for 4–15 B, then four arithmetic-positioned dword loads and stores.
The baseline fastmem uses four branches for 4–7 B and three for 8–16 B, with two loads and stores.
For 1–3 B, compiler-rt uses three branches and three byte loads and stores.
Fastmem uses five branches, then either one byte or two word loads and stores.

| Move size | Baseline instructions / branches | Tiered instructions / branches | Compact instructions / branches |
|---|---:|---:|---:|
| 0 | 6 / 2 | 10 / 4 | 8 / 3 |
| 1 | 14 / 5 | 18 / 4 | 16 / 3 |
| 4–7 | 14 / 4 | 12 / 3 | 19 / 2 |
| 8–15 | 12 / 3 | 10 / 2 | 19 / 2 |
| 17–32 | 10 / 2 | 12 / 3 | 19 / 2 |
| 33–63 | 14 / 4 | 12 / 3 | 19 / 2 |

Compiler-rt also uses 19 instructions for 4–15 B move.
Its 16–63 B move path adds a stack frame and seven vector accesses to stack slots.
That path takes 37 instructions in the inspected Intel and AMD binaries.
Compact uses XMM0–3 directly, with four loads before four stores and no frame.
Its 16 B case also uses this class. Tiered retains two qword loads and stores at 16 B.

AMD compiler-rt `memcpy` starts at `0x10a6370`.
Its 16–63 B class uses two size branches and four 16-byte loads and stores, without vector spills.
It takes 22 instructions, including the frame setup and teardown.
Baseline fastmem uses XMM0–1 through 32 B, then YMM16–17 through 63 B.
Compact tests the compiler-rt class shape without its frame overhead.

Intel compiler-rt enters a pointer-direction dispatch and a 32-byte vector loop above 63 B, at `0x10a28fc`.
AMD retains a four-block 64-byte class through 255 B, at `0x10a5fef`, with vector spills.
Thus its medium instruction count depends on CPU, length, direction, and alignment.
The fastmem medium classes contain no loops or pointer-direction branches.

### Layout and limits of the diagnosis

The glibc move entry and its 129–256 B dispatch block are 64-byte aligned.
The baseline Intel move entry is only 16-byte aligned, at offset 32 within a 64-byte line.
Its medium comparison blocks start at offsets `+0xb3` and `+0xdc` from entry.
The latter starts at offset 60 within a 64-byte line.
The glibc 65–128 B path fits within its first 64-byte line.

Compact Intel move starts at `0x108d650`.
Its medium comparisons start at `+0xa2` and `+0xc8`, with no explicit block alignment.
The candidates leave block placement to LLVM. They do not prove that layout effects disappear.

Extra dispatch and delayed loads provide concrete hypotheses for the medium gap.
Branch depth, class shape, and layout provide hypotheses for compiler-rt's short-size wins.
Static instruction counts do not establish cycle attribution, especially when compiler-rt executes more instructions.
The fleet run must decide whether either tradeoff helps.

## Implementation and local evidence

`tiered` moves the large-size check after the medium classes.
Its short move path omits the zero check before the 8-byte and 4-byte classes.
`compact` uses the same medium classes and arithmetic-positioned four-block short copies.
Both preserve the existing scalar set path, inline classes, vector widths, and REP/NT thresholds.
The LLVM AVX-512 path selects the new dispatch. AVX2 and self-hosted Debug retain the existing fallback.

`src/x86_64/compact.zig` adapts Zig compiler-rt, under MIT.
`THIRD_PARTY.md` records the source commit and full permission notice.
The upstream file matches the pinned Nix toolchain byte-for-byte.

| Local check | Result |
|---|---|
| Native `zig build test`, Debug and ReleaseFast | 27 tests passed in each mode |
| Native ReleaseFast install build | Passed |
| Codegen gate, control and both candidates | Five CPUs passed for each selection |
| Codegen gate, legacy `entry` | Five CPUs passed |
| Gate mutation tests | Nine passed for each selection |
| QEMU v3 unit suite, Fast/Safe/Debug | 26 tests passed in each mode before the page-edge test |
| Final QEMU v3 ReleaseFast unit suite | 27 tests passed |
| Direct compact overlap test | 258,048 cases, all lengths 1–63 and every source/destination offset 0–63 |
| Direct compact page-edge test | 252 cases, read-only source, independent start/end boundaries |
| QEMU v3 ReleaseFast guard suite, maximum 1024 B | 27,904,572 cases passed, exit 0 |
| Candidate Intel and AMD ReleaseFast install builds | Both candidates passed on Sapphire Rapids and Zen 4 |
| Candidate Sapphire Rapids Safe/Debug guard builds | Both candidates compiled |
| `ziglint src/x86_64/` | Passed |
| `ziglint src/` | Existing warnings outside this lane only |
| `asm-all` | Both candidates match baseline aarch64 `.text` contents on GNU, musl, and macOS |

The full local guard matrix ran once. The focused page-edge test ran twice, including the final import-only cleanup.
No AWS command or fleet launch ran in this lane.
Local evidence does not cover AVX-512 execution. The parent must run the hardware guards.
The saved local summaries are in `docs/slop/results/p3-x86c-local.json`.

The gate now requires the requested variant as an argument.
It rejects the wrong register bank or branch fingerprint. It does not infer the variant from the object.
It checks `copyLarge`, `move.largeKernel`, and `set.largeKernel` separately for width, REP, NT stores, and fences.
Mutation tests remove each copyLarge feature and require rejection.

## Fleet procedure

Create clean candidate worktrees:

```sh
git -C /Users/matt/code/fastmem-zig worktree add --detach /tmp/p3-x86c-fleet-tiered c920df7
git -C /Users/matt/code/fastmem-zig worktree add --detach /tmp/p3-x86c-fleet-compact 47ef8f9
```

Link the ignored fleet state and key from the parent checkout:

```sh
for variant in tiered compact; do
  for name in .terraform terraform.tfstate bench.pem; do
    ln -s "/Users/matt/code/fastmem-zig/infra/base/$name" "/tmp/p3-x86c-fleet-$variant/infra/base/$name"
  done
done
```

Run both hardware guard matrices without launches:

```sh
for variant in tiered compact; do
  nix develop "/tmp/p3-x86c-fleet-$variant" -c just --justfile "/tmp/p3-x86c-fleet-$variant/Justfile" b test \
    --target c7i --target c8i --target c7a --target c8a \
    --optimize ReleaseFast --optimize ReleaseSafe --optimize Debug || exit
done
```

After both matrices pass, run the interleaved three-revision A/B with the default A/A control:

```sh
nix develop /Users/matt/code/fastmem-zig -c just --justfile /Users/matt/code/fastmem-zig/Justfile b run \
  --rev a29a7cc --rev c920df7 --rev 47ef8f9 \
  --target c7i --target c8i --target c7a --target c8a \
  --suite standard --rounds 5 --label p3-x86c-small
```

Run the large suite for additional regression evidence:

```sh
nix develop /Users/matt/code/fastmem-zig -c just --justfile /Users/matt/code/fastmem-zig/Justfile b run \
  --rev a29a7cc --rev c920df7 --rev 47ef8f9 \
  --target c7i --target c8i --target c7a --target c8a \
  --suite large --rounds 5 --label p3-x86c-large
```

## Residual risks

- Tiered adds work at zero and 1–3 B. Its 17–32 B path adds one size comparison.
- Compact trades more loads and stores for fewer branches, particularly at 4–15 and 17–32 B.
- Both candidates add one comparison to 17–32 B set.
- Both candidates add two comparisons to ABI entries above 512 B. The large kernels themselves remain unchanged.
- LLVM still controls hot-block alignment. Address changes can affect measurements independently of instruction counts.
- AVX-512 execution and fleet performance remain untested here. No G2 or G3 success claim follows from the local results.
- The existing large benchmark stops below the Granite Rapids NT threshold. Hardware guards cover that threshold instead.
