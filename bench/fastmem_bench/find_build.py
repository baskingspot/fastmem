"""Search-only builds, retaining commands, exact executable bytes and transitive audits."""

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from fastmem_bench.build import Source
from fastmem_bench.find_codegen import FORBIDDEN, inspect
from fastmem_bench.find_jsonl import unique_object


class SearchCodegen(BaseModel):
    """Retained audit structure, not a substitute for executable/manual review."""

    model_config = ConfigDict(strict=True, extra="forbid")
    binary_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    status: Literal["pending-kernel", "pending-review"]
    kernel_pending: bool
    anti_hoist_status: Literal["manual-review-required"]
    checked_roots: list[str] = Field(min_length=1)
    followed_callees: list[str] = Field(min_length=1)
    followed_functions: list[dict[str, str]] = Field(min_length=1)
    delegations: list[dict[str, Any]]
    unresolved: list[dict[str, Any]]
    wrapper_symbol: Literal["bench_find_fastmem"]
    wrapper_disassembly: str = Field(min_length=1)
    wrapper_address: str = Field(pattern=r"^0x[0-9a-f]+$")
    timed_roots: list[str] = Field(min_length=1)
    dispatch_proof: dict[str, Any] | None
    dispatch_calls: list[dict[str, Any]]
    clock_calls_for_manual_review: list[dict[str, Any]]
    integration_hook: str = Field(min_length=1)


def validate_codegen(value: dict[str, Any]) -> None:
    evidence = SearchCodegen.model_validate(value)
    if (
        evidence.delegations
        or evidence.unresolved
        or any(name.split("@")[0] in FORBIDDEN for name in evidence.followed_callees)
        or evidence.kernel_pending != (evidence.status == "pending-kernel")
        or any(not name for name in evidence.checked_roots + evidence.timed_roots)
    ):
        raise ValueError("Invalid search codegen/delegation evidence")
    for function in evidence.followed_functions:
        if (
            set(function) != {"address", "symbol"}
            or not re.fullmatch(r"0x[0-9a-f]+", function["address"])
            or function["symbol"] not in evidence.followed_callees
        ):
            raise ValueError("Malformed followed search function evidence")


def read_evidence(path: Path) -> Any:
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def build_command(*, target: str, cpu: str, revision: str, prefix: Path) -> list[str]:
    return [
        "zig",
        "build",
        "bench-find-bin",
        f"-Dtarget={target}",
        f"-Dcpu={cpu}",
        "-Doptimize=ReleaseFast",
        f"-Drev={revision}",
        "--prefix",
        str(prefix.resolve()),
    ]


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
    destination = destination.resolve()
    command = build_command(target=target, cpu=cpu, revision=source.revision, prefix=destination)
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
    validate_codegen(evidence)
    return Build(source, binary, cpu, target, zig, command, evidence, dispatch_level)
