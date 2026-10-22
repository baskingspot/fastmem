"""Link two fastmem package copies into one Linux executable.

Each copy is a separate package instance. Its symbol names carry a
different instance id (build.zig `instanceId`), so the link succeeds. On
x86_64 baseline the dispatch symbols differ; on aarch64 the kernel entry
exports stay off in a consumer copy, and the inline-assembly labels carry
the instance id. The check copies the package twice, builds
src/export/two_packages/ against the copies, inspects the symbols, and runs
the executable when a runner exists.
"""

import argparse
import re
import resource
import shutil
import subprocess
import zlib
from pathlib import Path

from runtime import linux_runner

# A Zig 0.16 fingerprint is the CRC-32 of the package name (high half) and a
# nonzero id (low half).
FINGERPRINT = hex(zlib.crc32(b"two_packages") << 32 | 0x7F0E5A11)
ZON = """.{{
    .name = .two_packages,
    .version = "0.0.0",
    .fingerprint = {fingerprint},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{{
        .fastmem_a = .{{ .path = "../a" }},
        .fastmem_b = .{{ .path = "../b" }},
    }},
    .paths = .{{""}},
}}
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("zig")
    parser.add_argument("root")
    parser.add_argument("work")
    parser.add_argument("--target", default="x86_64-linux-musl")
    parser.add_argument("--cpu", default="baseline")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    work = Path(args.work).resolve()
    arch = args.target.split("-", 1)[0]
    for copy in ("a", "b"):
        target = work / copy
        shutil.rmtree(target, ignore_errors=True)
        target.mkdir(parents=True)
        for name in ("build.zig", "build.zig.zon"):
            shutil.copy2(root / name, target / name)
        shutil.copytree(root / "src", target / "src")
    consumer = work / "consumer"
    shutil.rmtree(consumer / "src", ignore_errors=True)
    shutil.copytree(root / "src/export/two_packages", consumer, dirs_exist_ok=True)
    (consumer / "build.zig.zon").write_text(ZON.format(fingerprint=FINGERPRINT))
    subprocess.run(
        [
            args.zig,
            "build",
            f"-Dtarget={args.target}",
            f"-Dcpu={args.cpu}",
            "-Doptimize=ReleaseFast",
        ],
        cwd=consumer,
        check=True,
        timeout=1200,
    )
    binary = consumer / "zig-out/bin/two-packages"
    symbols = subprocess.check_output(["llvm-nm", "--defined-only", str(binary)], text=True)
    if arch == "x86_64":
        instances = set(re.findall(r"\bfastmem_x86_([0-9a-f]{16})_resolve_memcpy$", symbols, re.M))
        assert len(instances) == 2, ("expected two dispatch instances", instances)
        for instance in instances:
            levels = re.findall(rf"\bfastmem_x86_{instance}_(\w+)_memmove$", symbols, re.M)
            assert len(levels) == 8, (instance, levels)  # six levels, resolve, generic
        evidence = f"dispatch instances {sorted(instances)}"
    else:
        # A consumer copy exports no kernel entry. The two local mid-entry
        # labels prove that each copy emitted its own kernel bytes.
        exported = re.findall(r"^[0-9a-f]+ [A-Z] fastmem_(?:sve|advsimd)_\w+$", symbols, re.M)
        assert not exported, ("kernel symbols must stay local", exported)
        labels = re.findall(r"\bfastmem_sve_copy_gt64_[0-9a-f]{16}$", symbols, re.M)
        assert len(labels) == 2, ("expected two mid-entry labels", labels)
        evidence = f"mid-entry labels {sorted(labels)}"
    ran = "static checks only"
    runner = linux_runner(arch)
    if runner is not None:
        result = subprocess.run(
            [*runner, str(binary)],
            capture_output=True,
            text=True,
            timeout=300,
            check=True,
            preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)),
        )
        ran = result.stdout.strip()
    print(f"PASS two fastmem package instances in one link: {evidence}, {ran}")


if __name__ == "__main__":
    main()
