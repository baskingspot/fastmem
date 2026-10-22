"""Pin the aarch64 instruction bytes.

Current pins cover the neon mid blocks (pair for copy/gt64, chunk for
V3 move), the V3 copy head whose 33+ sizes fall through into the mid96
dispatch with a 65..128 tail split at 96 that only it uses (armh), and
the V1 hybrid move head that routes (2*VL, 128] directly to the SVE mid
block.
Update GOLDEN only in a commit that deliberately changes kernel bytes.
"""

import hashlib
import struct
import sys
from pathlib import Path

# These hashes cover the old .text bytes, not disassembly or source text.
# V3's move head includes alignment padding before the shared copy body.
GOLDEN = {
    "generic": {
        "set": (348, "c82b1061bbf1c082a145f8fee446a00d07b6132a463faa7c7d0c8d64cd65f1b4"),
        "copy": (448, "006648e55dd1a1122d97a713fbbe317308f9ae253ddc93a284bca4dfca13da09"),
        "move": (448, "006648e55dd1a1122d97a713fbbe317308f9ae253ddc93a284bca4dfca13da09"),
    },
    "neoverse_v1": {
        "set": (256, "90f42348d31f9f25412aab25f7feeb3acd6652ffbe1772321525fd4bc253e8a0"),
        "copy": (368, "a2dbcc5bb7355421edcd4b9b38dd7103a893ffa36fe11ac567d0b63744997ae7"),
        "move": (192, "3c290a4a2b50176d70332dfb7092ba7e9906bdf180f38ec8138b651ee811875a"),
    },
    "neoverse_v3": {
        "set": (336, "6a38736588879006b6c9ae1bfc52574b34696143e7e3310538f0075b4e8347b0"),
        "copy": (736, "ee99afd1483a5eeba290f4b1f4af4c69eec08b8f1c4beb392f7467c266dd0ff4"),
        "move": (192, "5765bd80e82562e777e81834cae4a95d3aa85afe6d606edf4f1602fb7ad1b3ea"),
    },
}
# Set matches V1. The V2 copy symbol carries the neon mid blocks (the move
# head branches into them). V2 is byte-identical to main: the 65..128
# tail split serves only the V3 copy fall-through (review of 0cb3bf3),
# and V1 emits no neon mid block. The V3 move hash shifted on branch
# targets only (the mid96 block moved the shared body's addresses); its
# head shape is unchanged.
GOLDEN["neoverse_v2"] = {
    **GOLDEN["neoverse_v1"],
    "copy": (480, "3545b39c5d5bab497f8993f2735ea49fa0fdc69d59abe4eef12f1d82d2914bb7"),
    "move": (192, "d83d946a28edb3ee6f8918234a3eb7b05eb9f6e0aad47d05f4f5e045179b1479"),
}


def main():
    cpu, binary = sys.argv[1:]
    raw = Path(binary).read_bytes()
    shoff = struct.unpack_from("<Q", raw, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", raw, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", raw, shoff + i * shsize) for i in range(shnum)]
    prefix = "fastmem_advsimd_" if cpu == "generic" else "fastmem_sve_"
    found = set()
    for sec in sections:
        if sec[1] != 2:
            continue
        strings_sec = sections[sec[6]]
        strings = raw[strings_sec[4]:strings_sec[4] + strings_sec[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            name_off, _, _, index, value, size = struct.unpack_from("<IBBHQQ", raw, off)
            name = strings[name_off:].split(b"\0", 1)[0].decode()
            if not name.startswith(prefix):
                continue
            # fastmem_sve_copy_gt64_<instance> is a size-0 hidden label
            # inside fastmem_sve_copy (the > 64 byte mid entry used by the
            # inline layer). It adds no instruction bytes; the copy/move
            # entries below cover the bytes it points into.
            if name.startswith(prefix + "copy_gt64"):
                continue
            op = name.removeprefix(prefix)
            expected_size, expected_hash = GOLDEN[cpu][op]
            assert size == expected_size, (cpu, name, size, expected_size)
            start = sections[index][4] + value
            actual_hash = hashlib.sha256(raw[start:start + size]).hexdigest()
            assert actual_hash == expected_hash, (cpu, name, actual_hash, expected_hash)
            found.add(op)
    assert found == {"copy", "move", "set"}, found
    print(f"PASS {cpu}: all kernel instruction bytes match GOLDEN")


if __name__ == "__main__":
    main()
