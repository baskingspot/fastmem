"""Source resolution and content-addressed cross builds."""

import errno
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ec2bench.config import Config
from ec2bench.parallel import Outcome, parallel
from ec2bench.runs import git
from fastmem_bench.codegen import inspect as inspect_codegen
from fastmem_bench.jsonl import Codegen


@dataclass(frozen=True)
class Source:
    variant: str
    revision: str
    path: Path
    source_hash: str
    # -Dx86-experiment for this source; "auto" is the per-model default.
    experiment: str = "auto"


@dataclass(frozen=True)
class Build:
    source: Source
    target: str
    prefix: Path
    cache_key: str
    codegen: dict[str, Any] | None = None


def source_hash(root: Path) -> str:
    digest = hashlib.sha256()
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root,
        check=True,
        capture_output=True,
        timeout=60,
    ).stdout.split(b"\0")
    for name in sorted(set(files)):
        if not name:
            continue
        path = root / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link:" + os.fsencode(path.readlink()))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode() + b"\0" + path.read_bytes())
        else:
            digest.update(b"missing")
    return digest.hexdigest()


def resolve(config: Config, revisions: tuple[str, ...], experiment: str = "auto") -> list[Source]:
    sources = []
    for index, revision in enumerate(revisions):
        if revision == "WORKTREE":
            path = config.root
            digest = source_hash(path)
        else:
            sha = git(config.root, "rev-parse", "--verify", f"{revision}^{{commit}}")
            path = config.cache_dir / "src" / sha
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                git(config.root, "worktree", "add", "--detach", str(path), sha)
            if git(path, "status", "--porcelain"):
                raise ValueError(f"Cached source worktree is dirty: {path}")
            digest = sha
        # Experiments are branch-local: a revision that predates the
        # experiment builds its own default, and the manifest shows it.
        effective = experiment if declares_experiment(path, experiment) else "auto"
        sources.append(Source(f"v{index}", revision, path, digest, effective))
    return sources


CPU_MODES = ("target", "baseline")


def baseline_cpu(settings: dict[str, Any]) -> str:
    """The G6 portable CPU: bench.toml baseline_cpu, or the plan default for the arch."""
    arch = settings.get("zig_target", "").split("-")[0] or settings.get("arch")
    cpu = settings.get("baseline_cpu") or ("x86_64" if arch == "x86_64" else "generic")
    if not isinstance(cpu, str) or cpu == "native":
        raise ValueError(f"Invalid baseline_cpu: {cpu!r}")
    return cpu


DISPATCH_LEVELS = ("sapphirerapids", "graniterapids", "znver4", "znver5")


def expected_dispatch(settings: dict[str, Any], mode: str) -> str | None:
    """The runtime-dispatch level of a G6 x86_64 build: the kernel of zig_cpu.

    A baseline x86_64 build without AVX2 selects its kernels at run time
    (docs/slop/runtime-dispatch.md). On a fleet box the selection must equal the
    comptime kernel of the target model. Other builds do not dispatch.
    """
    cpu = build_cpu(settings, mode)
    arch = settings.get("zig_target", "").split("-")[0] or settings.get("arch")
    if mode != "baseline" or arch != "x86_64":
        return None
    if cpu not in ("x86_64", "baseline", "x86_64_v2"):
        return None
    zig_cpu = settings["zig_cpu"]
    return zig_cpu if zig_cpu in DISPATCH_LEVELS else None


# A dispatching binary exports these resolvers (src/x86_64/dispatch.zig).
DISPATCH_RESOLVER = re.compile(r"fastmem_x86_[0-9a-f]{16}_resolve_memcpy")


def dispatches(codegen: dict[str, Any] | None) -> bool:
    """The binary selects its kernels at run time: its codegen roots name the resolvers."""
    return codegen is not None and any(
        DISPATCH_RESOLVER.fullmatch(root) for root in codegen["checked_roots"]
    )


def supports_dispatch(source: Path) -> bool:
    """The revision has runtime dispatch: its build declares the x86-dispatch option."""
    build = source / "build.zig"
    return build.is_file() and '"x86-dispatch"' in build.read_text()


def declares_experiment(source: Path, experiment: str) -> bool:
    """The revision's build declares this x86-experiment enum value.

    Experiments are branch-local: a baseline revision that predates the
    experiment must build with its own default instead of failing.
    """
    if experiment == "auto":
        return True
    build = source / "build.zig"
    # Zig enum fields are bare identifiers: x86i_chunks, not "x86i_chunks".
    return (
        build.is_file()
        and re.search(rf"\b{re.escape(experiment)}\b", build.read_text()) is not None
    )


def check_dispatch_build(
    settings: dict[str, Any], mode: str, source: Path, codegen: dict[str, Any] | None
) -> None:
    """A revision with runtime dispatch must dispatch in its G6 x86_64 build.

    Analysis then requires the expected level from every binary that
    dispatches (analysis.record_dispatch). A revision without the feature
    builds a binary without resolvers, and no level applies to it.
    """
    if expected_dispatch(settings, mode) is None or not supports_dispatch(source):
        return
    if not dispatches(codegen):
        raise RuntimeError(
            f"{source}: the revision has runtime dispatch, but its {mode} build has no"
            " dispatch resolvers"
        )


def build_cpu(settings: dict[str, Any], mode: str) -> str:
    """The -Dcpu of a build: zig_cpu for target builds, baseline_cpu for G6 builds."""
    if mode not in CPU_MODES:
        raise ValueError(f"Unknown CPU mode: {mode}")
    cpu = settings["zig_cpu"] if mode == "target" else baseline_cpu(settings)
    if cpu == "native":
        raise ValueError("Cross builds require an explicit CPU model")
    return cpu


def build_all(
    config: Config, sources: list[Source], targets: list[str], *, cpu_mode: str = "target"
) -> dict[str, Outcome[Build]]:
    zig_version = subprocess.run(
        ["zig", "version"], check=True, capture_output=True, text=True, timeout=30
    ).stdout.strip()
    pairs = {
        f"{source.variant}/{target}": (source, target) for source in sources for target in targets
    }

    def build(name: str) -> Build:
        source, target = pairs[name]
        settings = config.targets[target]
        cpu = build_cpu(settings, cpu_mode)
        # The key layout is unchanged, so that target-CPU builds keep their cache entries.
        key_data = [
            source.source_hash,
            target,
            settings["zig_target"],
            cpu,
            zig_version,
            source.revision,
            "ReleaseFast",
            True,
            "codegen-v1",
            source.experiment,
        ]
        key = hashlib.sha256(json.dumps(key_data).encode()).hexdigest()
        prefix = config.cache_dir / "build" / key
        if not (prefix / "complete.json").exists():
            prefix.parent.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix="build-", dir=prefix.parent))
            try:
                args = [
                    "zig",
                    "build",
                    "install",
                    f"-Dtarget={settings['zig_target']}",
                    f"-Dcpu={cpu}",
                    "-Doptimize=ReleaseFast",
                    "-Dlink-libc=true",
                    f"-Drev={source.revision}",
                    "--prefix",
                    str(temporary),
                ]
                if source.experiment != "auto":
                    args.append(f"-Dx86-experiment={source.experiment}")
                completed = subprocess.run(
                    args, cwd=source.path, capture_output=True, text=True, timeout=1200, check=False
                )
                (temporary / "build.log").write_text(completed.stdout + completed.stderr)
                if completed.returncode:
                    log = prefix.parent / f"{key}.failed.log"
                    (temporary / "build.log").replace(log)
                    raise RuntimeError(
                        f"Cross build failed. Read {log}: {completed.stderr[-2000:]}"
                    )
                for binary in ("bench-fastmem", "libc-probe"):
                    if not (temporary / "bin" / binary).is_file():
                        raise FileNotFoundError(f"Build did not install {binary}")
                verify_builtin_calls(temporary / "bin/bench-fastmem")
                evidence = inspect_codegen(temporary / "bin/bench-fastmem")
                (temporary / "bin/codegen.json").write_text(json.dumps(evidence, indent=2) + "\n")
                (temporary / "complete.json").write_text(
                    json.dumps({"key": key_data, "command": args})
                )
                try:
                    temporary.rename(prefix)
                except OSError as error:
                    if (
                        error.errno not in {errno.EEXIST, errno.ENOTEMPTY}
                        or not (prefix / "complete.json").exists()
                    ):
                        raise
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        codegen = load_codegen(prefix)
        check_dispatch_build(settings, cpu_mode, source.path, codegen)
        return Build(source, target, prefix, key, codegen)

    return parallel(pairs, build, workers=os.cpu_count() or 1)


def load_codegen(prefix: Path) -> dict[str, Any]:
    evidence = Codegen.model_validate(json.loads((prefix / "bin/codegen.json").read_text()))
    digest = hashlib.sha256((prefix / "bin/bench-fastmem").read_bytes()).hexdigest()
    if evidence.binary_sha256 != digest:
        raise ValueError(f"Cached codegen evidence disagrees with {prefix}")
    return evidence.model_dump()


def verify_builtin_calls(binary: Path) -> None:
    """Prove that startup @extern evidence names the actual wrapper callees."""
    symbols = subprocess.run(
        ["llvm-nm", str(binary)],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout
    for name in ("memcpy", "memmove", "memset"):
        if not re.search(rf"^[0-9a-f]+ t {name}$", symbols, re.MULTILINE):
            raise ValueError(f"{binary}: {name} is not local executable text")
        assembly = subprocess.run(
            ["llvm-objdump", "-d", f"--disassemble-symbols=builtin_{name}", str(binary)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        ).stdout
        if f"<{name}>" not in assembly or f"<{name}@plt>" in assembly:
            raise ValueError(f"{binary}: builtin_{name} does not call the local {name}")


def disassemble(build: Build, destination: Path) -> str | None:
    binary = build.prefix / "bin/bench-fastmem"
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = {
        "fastmem_copy",
        "fastmem_move",
        "builtin_memcpy",
        "builtin_memmove",
        "builtin_memset",
    }
    try:
        symbols = subprocess.run(
            ["llvm-objdump", "--syms", str(binary)],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        ).stdout
        names = sorted(
            {
                line.split()[-1]
                for line in symbols.splitlines()
                if line.split()
                and line.split()[-1].startswith(
                    (
                        "fastmem_",
                        "builtin_",
                        "bench_fastmem.runLoop",
                        "bench_fastmem.runFastmemInline",
                    )
                )
            }
        )
        missing = expected - set(names)
        warning = (
            f"{binary}: missing disassembly symbols: {', '.join(sorted(missing))}"
            if missing
            else None
        )
        if names:
            result = subprocess.run(
                ["llvm-objdump", "-d", "--disassemble-symbols=" + ",".join(names), str(binary)],
                check=True,
                capture_output=True,
                text=True,
                timeout=120,
            )
            destination.write_text(result.stdout)
    except (OSError, subprocess.SubprocessError) as error:
        warning = f"{binary}: disassembly failed: {error}"
    if warning:
        logging.getLogger(__name__).warning("%s", warning)
        destination.with_suffix(".warning.txt").write_text(warning + "\n")
    return warning


def provenance(sources: list[Source], results: dict[str, Outcome[Build]]) -> dict[str, Any]:
    return {
        "sources": [
            {
                "variant": source.variant,
                "revision": source.revision,
                "hash": source.source_hash,
                "path": str(source.path),
                "experiment": source.experiment,
            }
            for source in sources
        ],
        "builds": {
            key: {
                "cache_key": result.value.cache_key,
                "prefix": str(result.value.prefix),
                "codegen": result.value.codegen,
            }
            if result.value
            else {"error": str(result.error)}
            for key, result in results.items()
        },
    }
