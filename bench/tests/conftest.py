"""Schema-v2 and v3 fixtures and project configuration."""

import json
import os
from pathlib import Path
from typing import Any

import pytest
from ec2bench.config import Config


@pytest.fixture(autouse=True)
def aws_profile(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The justfile exports AWS_PROFILE; give the tests a profile that works."""
    profiles = ("unused", "fastmem-bench")
    credentials = tmp_path / "credentials"
    credentials.write_text(
        "\n".join(
            f"[{profile}]\naws_access_key_id = testing\naws_secret_access_key = testing"
            for profile in profiles
        )
        + "\n"
    )
    config = tmp_path / "config"
    config.write_text(
        "\n".join(f"[profile {profile}]\nregion = us-west-2" for profile in profiles) + "\n"
    )
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", str(credentials))
    monkeypatch.setenv("AWS_CONFIG_FILE", str(config))
    monkeypatch.setenv("AWS_PROFILE", os.environ.get("AWS_PROFILE", "unused"))


LIBC_PATH = "/fixture/lib/libc.so.6"
RESOLUTION: dict[str, Any] = {
    name: {
        "glibc": {
            "address": 0x10000 + offset,
            "dli_fname": LIBC_PATH,
            "dli_fbase": 0x10000,
            "offset": offset,
        },
        "builtin": {
            "address": 0x20000 + offset,
            "dli_fname": "/fixture/bench-fastmem",
            "dli_fbase": 0x20000,
            "offset": offset,
        },
    }
    for name, offset in (("memcpy", 16), ("memmove", 32), ("memset", 48))
}
PROBE: dict[str, Any] = {
    "libc_path": LIBC_PATH,
    "symbols": {
        name: {"offset": hex(pair["glibc"]["offset"])} for name, pair in RESOLUTION.items()
    },
}
CODEGEN: dict[str, Any] = {
    "binary_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "checked_roots": ["fastmem_copy", "fastmem_move", "bench_fastmem.runFastmemInline__test"],
    "delegations": [],
}
MEMORY: dict[str, Any] = {
    "layout": "arena",
    "arena_bytes": 6 << 20,
    "region_bytes": 2 << 20,
    "base_align": 1 << 30,
    "src_offset": 0,
    "dst_offset": (2 << 20) + 4096,
    "seq_offset": 4 << 20,
    "hugepage_advice": "SUCCESS",
    "populate": "SUCCESS",
    "collapse": "SUCCESS",
    "thp_enabled": "madvise",
    "thp_defrag": "madvise",
    "thp_pmd_bytes": 2 << 20,
    "anon_huge_bytes_start": 6 << 20,
    "anon_huge_bytes_end": 6 << 20,
}
META_V2 = {
    "codegen": CODEGEN,
    "resolution": RESOLUTION,
    "libc_path": LIBC_PATH,
    "libc_base": 0x10000,
    "fastmem_set": False,
    "set_value": 165,
    "dist_file": None,
}


@pytest.fixture
def config(tmp_path: Path) -> Config:
    (tmp_path / "bench.pem").write_text("dummy key")
    (tmp_path / "bench.toml").write_text(f"""
[project]
name = "test-bench"
region = "us-west-2"
profile = "unused"
adapter = "test_adapter"
remote_dir = "/root/bench"
image_version = "1"
extra_key = "ignored"
ssh_key = "{tmp_path / "bench.pem"}"
[fleet]
default_ttl = "4h"
[targets.intel]
instance_type = "c7i.xlarge"
arch = "x86_64"
zig_cpu = "sapphirerapids"
[targets.arm]
instance_type = "c8g.xlarge"
arch = "arm64"
zig_cpu = "neoverse_v2"
""")
    return Config.load(tmp_path)


def measurement(
    path: Path,
    scale: float = 1.0,
    *,
    size: int = 64,
    schema: int = 3,
    memory: dict[str, Any] | None = None,
    cpu: str = "sapphirerapids",
    dispatch: dict[str, Any] | None = None,
    codegen: dict[str, Any] | None = None,
) -> None:
    records: list[dict[str, Any]] = [
        {
            **META_V2,
            **({"memory": memory or MEMORY} if schema == 3 else {}),
            # Only a dispatching binary writes the field.
            **({"dispatch": dispatch} if dispatch is not None else {}),
            **({"codegen": codegen} if codegen is not None else {}),
            "type": "meta",
            "schema": schema,
            "rev": "fixture",
            "zig": "0.16.0",
            "target": "x86_64-linux-gnu",
            "cpu": cpu,
            "optimize": "ReleaseFast",
            "link_libc": True,
            "chunk_bytes": 32,
            "suite": "quick",
            "seed": 1,
            "samples": 2,
            "sample_ms": 20,
            "warmup_ms": 10,
            "impls": ["builtin", "fastmem_abi", "fastmem_inline", "glibc"],
            "perf": {"available": False, "events": ["cycles", "instructions"], "error": "fixture"},
        }
    ]
    for implementation, factor in (
        ("builtin", 2),
        ("fastmem_abi", 1),
        ("fastmem_inline", 0.9),
        ("glibc", 1.25),
    ):
        for index in range(2):
            records.append(  # noqa: PERF401 — fixture records stay explicit
                {
                    "type": "sample",
                    "case": f"copy/aligned/{size}",
                    "op": "copy",
                    "profile": "aligned",
                    "size": size,
                    "src_off": 0,
                    "dst_off": 0,
                    "gap": None,
                    "impl": implementation,
                    "sample": index,
                    "iters": 100000,
                    "ns": round(1000000 * factor * scale),
                    "cycles": None,
                    "instructions": None,
                    "ref_cycles": None,
                    "time_enabled": None,
                    "time_running": None,
                }
            )
    records.append({"type": "end", "cases": 1, "elapsed_ns": 10000})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n")
