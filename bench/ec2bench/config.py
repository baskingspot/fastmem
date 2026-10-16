"""Project discovery and generic configuration."""

import os
import re
import stat
import tomllib
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Any

GIB = 1024**3


def _walk_error(error: OSError) -> None:
    if not isinstance(error, FileNotFoundError):
        raise error


def duration(value: str) -> timedelta:
    match = re.fullmatch(r"([1-9][0-9]*)(m|h|d)", value)
    if not match:
        raise ValueError(f"Invalid TTL {value!r}: use a positive integer and m, h, or d")
    return timedelta(seconds=int(match[1]) * {"m": 60, "h": 3600, "d": 86400}[match[2]])


def find_root(start: Path | None = None) -> Path:
    path = (start or Path.cwd()).resolve()
    for parent in (path, *path.parents):
        if (parent / "bench.toml").is_file():
            return parent
    raise FileNotFoundError("No bench.toml in this directory or its parents")


@dataclass(frozen=True)
class Config:
    root: Path
    project: dict[str, Any]
    fleet: dict[str, Any]
    targets: dict[str, dict[str, Any]]

    @classmethod
    def load(cls, root: Path | None = None) -> Config:
        root = find_root(root)
        raw = tomllib.loads((root / "bench.toml").read_text())
        project = raw["project"]
        for key in ("name", "region", "profile", "image_version"):
            if not isinstance(project.get(key), str) or not project[key]:
                raise ValueError(f"project.{key} must be a nonempty string")
        fleet = {
            "default_ttl": "4h",
            "max_ttl": "12h",
            "default_owner": "agent",
            **raw.get("fleet", {}),
        }
        if duration(fleet["default_ttl"]) > duration(fleet["max_ttl"]):
            raise ValueError("fleet.default_ttl exceeds fleet.max_ttl")
        targets = raw.get("targets", {})
        for name, target in targets.items():
            if not re.fullmatch(r"[a-zA-Z0-9_-]+", name):
                raise ValueError(f"Invalid target name: {name}")
            if not target.get("instance_type") or target.get("arch") not in {"x86_64", "arm64"}:
                raise ValueError(f"Invalid instance_type or arch for {name}")
        return cls(root, project, fleet, targets)

    @property
    def results_dir(self) -> Path:
        return self.root / self.project.get("results_dir", "bench-results")

    @property
    def cache_dir(self) -> Path:
        return self.root / self.project.get("cache_dir", ".bench-cache")

    def check_storage(self) -> None:
        """Reject new work above the local artifact budget. Preserve all files."""
        gib = self.project.get("artifact_budget_gib", 4)
        if type(gib) is not int or gib < 1:
            raise ValueError("project.artifact_budget_gib must be a positive integer")
        limit = gib * GIB
        used = 0
        seen: set[tuple[int, int]] = set()
        for directory in (self.cache_dir, self.results_dir):
            for parent, _directories, files in os.walk(directory, onerror=_walk_error):
                for name in files:
                    try:
                        info = (Path(parent) / name).stat(follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    identity = (info.st_dev, info.st_ino)
                    if not stat.S_ISREG(info.st_mode) or identity in seen:
                        continue
                    seen.add(identity)
                    used += info.st_size
                    if used > limit:
                        raise ValueError(
                            f"Local benchmark artifacts exceed the {gib} GiB budget. "
                            f"Remove completed artifacts from {self.cache_dir} and "
                            f"{self.results_dir} before new work."
                        )

    @property
    def tofu_dir(self) -> Path:
        return self.root / self.project.get("tofu_dir", "infra/base")

    def ttl(self, value: str) -> timedelta:
        requested = duration(value)
        if requested > duration(self.fleet.get("max_ttl", "12h")):
            raise ValueError(
                f"TTL {value} exceeds fleet.max_ttl ({self.fleet.get('max_ttl', '12h')})"
            )
        return requested

    def select(self, names: tuple[str, ...] | list[str]) -> list[str]:
        selected = list(dict.fromkeys(names))
        unknown = set(selected) - self.targets.keys()
        if unknown:
            raise ValueError(f"Unknown targets: {', '.join(sorted(unknown))}")
        return selected
