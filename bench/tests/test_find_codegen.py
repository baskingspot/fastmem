"""Mutation fixtures prove the delegation audit follows callees, including tail calls."""

import pytest

from fastmem_bench.find_codegen import scan


@pytest.mark.parametrize("instruction", ["callq", "jmp", "bl", "b"])
def test_transitive_delegation(instruction: str) -> None:
    assembly = f"""00001000 <root>:
 1000: {instruction} 0x2000 <helper>
00002000 <helper>:
 2000: {instruction} 0x3000 <memcmp@plt>
"""
    evidence = scan(assembly, ["root"])
    assert evidence["followed_callees"] == ["helper", "root"]
    assert evidence["delegations"] == [
        {"caller": "helper", "symbol": "memcmp", "address": "0x2000"}
    ]


@pytest.mark.parametrize(
    "symbol", ["memmem", "memchr", "memcmp", "bcmp", "memcpy", "memmove", "memset"]
)
def test_forbidden_search_and_memory_names(symbol: str) -> None:
    assert scan(f"00001000 <root>:\n 1000: bl 0x2000 <{symbol}>\n", ["root"])["delegations"]


def test_local_loop_and_missing_root() -> None:
    assert not scan("00001000 <root>:\n 1000: b.ne 0x1000 <root+0x4>\n", ["root"])["delegations"]
    with pytest.raises(ValueError, match="Missing"):
        scan("", ["root"])


def test_unknown_indirect_fails_closed() -> None:
    evidence = scan("00001000 <root>:\n 1000: blr x9\n", ["root"])
    assert evidence["unresolved"] == [{"caller": "root", "address": "0x1000"}]
