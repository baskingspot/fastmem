"""Offline search failures must overwrite summaries with an explicit failed status."""

import json
from pathlib import Path

from click.testing import CliRunner

from fastmem_bench.find import find_analyze
from fastmem_bench.find_analysis import EXPECTED_FIELDS
from tests.test_find_jsonl import PROBE, records, save


def test_reanalysis_bad_raw_never_looks_successful(tmp_path: Path) -> None:
    values = records()
    expected = {key: values[0][key] for key in EXPECTED_FIELDS}
    target = tmp_path / "local"
    target.mkdir()
    (tmp_path / "manifest.json").write_text(
        json.dumps({"dialect": "fastmem-find", "schema": 1, "targets": ["local"]})
    )
    (tmp_path / "summary.json").write_text('{"status":"complete"}')
    (target / "experiment.json").write_text(
        json.dumps({"rounds": 1, "expected": {"v0": expected, "aa": expected}, "builds": {}})
    )
    (target / "memmem-probe.json").write_text(json.dumps(PROBE))
    values[2]["checksum"] += 1
    save(target / "raw/v0/r0.jsonl", values)
    result = CliRunner().invoke(find_analyze, [str(tmp_path)])
    assert result.exit_code != 0
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["status"] == "failed"
    assert summary["targets"]["local"]["status"] == "failed"
    assert "checksum" in summary["targets"]["local"]["error"]
