"""Adapter registration."""

import click


def register(group: click.Group) -> None:
    from fastmem_bench.correctness import test_fleet
    from fastmem_bench.find import find, find_analyze
    from fastmem_bench.runner import analyze_run, run
    from fastmem_bench.search_correctness import test_fleet as test_find_fleet

    group.add_command(find)
    group.add_command(find_analyze)
    group.add_command(test_find_fleet)
    group.add_command(test_fleet)
    group.add_command(run)
    group.add_command(analyze_run)
