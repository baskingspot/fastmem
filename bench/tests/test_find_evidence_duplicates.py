"""Search evidence rejects contradictory JSON keys before statistical analysis."""

import json
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from fastmem_bench.find import analyze_target, find_analyze
from tests.test_find_runner import saved_run


@pytest.mark.parametrize(
    ("artifact", "key", "wrong"),
    [
        ("facts.json", "instance_id", "i-TAMPERED"),
        ("memmem-probe.json", "libc_path", "/TAMPERED/libc.so.6"),
        ("commands.json", "aa/r0", ["WRONG-COMMAND"]),
        ("protocol.json", "instance_id", "i-TAMPERED"),
        ("experiment.json", "rounds", 99),
    ],
)
def test_adjunct_duplicates_fail_before_rows(
    tmp_path: Path, artifact: str, key: str, wrong: object
) -> None:
    target, _ = saved_run(tmp_path)
    path = target / artifact
    original = path.read_text()
    path.write_text("{" + json.dumps(key) + ":" + json.dumps(wrong) + "," + original[1:])
    with patch("fastmem_bench.find.analyze") as analyze:
        with pytest.raises(ValueError, match="Duplicate JSON key"):
            analyze_target(target)
        analyze.assert_not_called()
    (tmp_path / "summary.json").write_text('{"status":"complete"}')
    result = CliRunner().invoke(find_analyze, [str(tmp_path)])
    assert result.exit_code != 0
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["status"] == "failed"
    assert "Duplicate JSON key" in summary["targets"]["local"]["error"]


def test_manifest_duplicate_replaces_stale_success(tmp_path: Path) -> None:
    saved_run(tmp_path)
    path = tmp_path / "manifest.json"
    path.write_text('{"rounds":99,' + path.read_text()[1:])
    (tmp_path / "summary.json").write_text('{"status":"complete"}')
    with patch("fastmem_bench.find.analyze") as analyze:
        result = CliRunner().invoke(find_analyze, [str(tmp_path)])
        analyze.assert_not_called()
    assert result.exit_code != 0
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["status"] == "failed"
    assert "Duplicate JSON key" in summary["error"]
