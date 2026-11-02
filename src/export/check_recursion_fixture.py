"""Require rejection of the compiled std.mem.replace recursion fixture."""

import subprocess
import sys
from pathlib import Path

result = subprocess.run(
    [sys.executable, str(Path(__file__).with_name("check.py")),
     "--arch", "x86_64", "--ecosystem", sys.argv[1]],
    capture_output=True, text=True,
)
assert result.returncode != 0, "the recursive fixture passed the audit"
assert "branch to memory entry:" in result.stderr, result.stderr
# 0.16 names it mem.replace__anon_N; 0.17 names it mem.replace__func_N.
assert "mem.replace__" in result.stderr, result.stderr
print("PASS compiled recursion fixture: std.mem.replace reaches a memory entry")
