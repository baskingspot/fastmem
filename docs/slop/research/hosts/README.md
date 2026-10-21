# Host ground truth (2026-09-24)

Facts that glibc 2.40 (NixOS 25.11 AMI) reports on each benchmark target.
The harness collected them with `libc-probe` and `ld.so --list-diagnostics`.

This directory holds facts only. The glibc binaries and their disassembly
are LGPL material. They are in `.bench-cache/glibc/` (gitignored), so that
they never enter this MIT repository. Read them to learn behavior. Do not
copy code from them. `docs/slop/fastmem-plan.md` has the clean-room rule.

| Target | CPU | memcpy / memmove variant | memset variant |
|---|---|---|---|
| c7i | Xeon Platinum 8488C (Sapphire Rapids) | `__memmove_avx512_unaligned_erms` | `__memset_avx512_unaligned_erms` |
| c8i | Xeon 6975P-C (Granite Rapids) | `__memmove_avx512_unaligned_erms` | `__memset_avx512_unaligned_erms` |
| c7a | EPYC 9R14 (Genoa, Zen 4) | `__memmove_avx512_unaligned` (no ERMS) | `__memset_avx512_unaligned` |
| c8a | EPYC 9R45 (Turin, Zen 5) | `__memmove_avx512_unaligned_erms` | `__memset_avx512_unaligned_erms` |
| c7g | Neoverse V1 (MIDR 0x411fd401) | `__memcpy_sve` / `__memmove_sve` | `__memset_sve_zva64` |
| c8g | Neoverse V2 (MIDR 0x410fd4f1) | `__memcpy_sve` / `__memmove_sve` | `__memset_sve_zva64` |
| c9g | Neoverse V3 (MIDR 0x410fd841) | `__memcpy_sve` / `__memmove_sve` | `__memset_sve_zva64` |

x86 thresholds (bytes) from `x86.cpu_features.*`:

| Target | rep_movsb | rep_stosb | non_temporal | L3 per `lscpu` |
|---|---|---|---|---|
| c7i | 16 KiB | 2 KiB | 53.5 MiB | see lscpu.txt |
| c8i | 16 KiB | 2 KiB | 241 MiB | see lscpu.txt |
| c7a | 12 MiB | never | 12 MiB | see lscpu.txt |
| c8a | 12 MiB | never | 12 MiB | see lscpu.txt |

No Graviton target has FEAT_MOPS (`mops=0x0`). All report `prefer_sve_ifuncs=1`.
