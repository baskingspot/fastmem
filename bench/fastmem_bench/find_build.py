"""Search-only builds, retaining commands, exact executable bytes and transitive audits."""

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastmem_bench.build import Source
from fastmem_bench.find_codegen import inspect


@dataclass(frozen=True)
class Build:
    source: Source
    binary: Path
    cpu: str
    target: str
    zig: str
    command: list[str]
    codegen: dict[str, Any]
    dispatch_level: str | None = None

    def expected(
        self,
        *,
        suite: str,
        seed: int,
        samples: int,
        sample_ms: int,
        case_filter: str,
        warmup_ms: int = 1,
    ) -> dict[str, Any]:
        return {
            "rev": self.source.revision,
            "cpu": self.cpu,
            "dispatch_level": self.dispatch_level,
            "target": self.target,
            "zig": self.zig,
            "binary_sha256": self.codegen["binary_sha256"],
            "suite": suite,
            "seed": seed,
            "samples": samples,
            "sample_ms": sample_ms,
            "warmup_ms": warmup_ms,
            "filter": case_filter,
        }


def build(
    source: Source, destination: Path, *, target: str, cpu: str, dispatch_level: str | None = None
) -> Build:
    if len(source.revision.encode()) > 64:
        raise ValueError("Revision labels must fit the fixed 64-byte build label")
    destination.mkdir(parents=True, exist_ok=True)
    command = [
        "zig",
        "build",
        "bench-find-bin",
        f"-Dtarget={target}",
        f"-Dcpu={cpu}",
        "-Doptimize=ReleaseFast",
        f"-Drev={source.revision}",
        "--prefix",
        str(destination.resolve()),
    ]
    completed = subprocess.run(
        command, cwd=source.path, capture_output=True, text=True, timeout=1200, check=False
    )
    (destination / "build.log").write_text(completed.stdout + completed.stderr)
    (destination / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    if completed.returncode:
        raise RuntimeError(f"Search build failed; read {destination / 'build.log'}")
    binary = destination / "bin/bench-find"
    zig = subprocess.run(
        ["zig", "version"], capture_output=True, text=True, check=True, timeout=30
    ).stdout.strip()
    # This hook is deliberately pending until the kernel owner replaces the forwarding API.
    root = (source.path / "src/root.zig").read_text()
    pending = (
        re.search(
            r"pub (?:inline )?fn find\([^)]*\) \?usize \{\s*"
            r"return std\.mem\.find\(T, haystack, needle\);\s*\}",
            root,
        )
        is not None
    )
    evidence = inspect(binary, destination / "executable.asm", kernel_pending=pending)
    if evidence["binary_sha256"] != hashlib.sha256(binary.read_bytes()).hexdigest():
        raise ValueError("Search executable changed during inspection")
    (destination / "codegen.json").write_text(json.dumps(evidence, indent=2) + "\n")
    if evidence["status"] == "invalid":
        raise ValueError(f"Search delegation audit failed; read {destination / 'codegen.json'}")
    return Build(source, binary, cpu, target, zig, command, evidence, dispatch_level)
