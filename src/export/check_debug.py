"""Pin Zig 0.17 self-hosted Debug lowering for runtime byte lengths."""

import re
import subprocess
import sys

arch, binary = sys.argv[1:]
text = subprocess.check_output(
    [
        "llvm-objdump",
        "-dr",
        "--no-show-raw-insn",
        "--disassemble-symbols=p6_copy,p6_move,p6_set",
        binary,
    ],
    text=True,
)
for symbol in ("memcpy", "memmove", "memset"):
    called = bool(re.search(r"R_\w+\s+" + symbol + r"(?:-0x4)?$", text, re.M))
    assert called == (arch == "aarch64" or symbol != "memset"), (arch, symbol, text)
if arch == "x86_64":
    assert "stosb" in text, text
print(
    f"PASS Debug {arch}: memcpy/memmove calls, memset "
    + ("call" if arch == "aarch64" else "inline rep stosb")
)
