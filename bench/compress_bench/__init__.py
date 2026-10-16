"""Adapter registration."""

import click


def register(group: click.Group) -> None:
    from compress_bench.correctness import test_fleet
    from compress_bench.runner import analyze_run, run

    group.add_command(test_fleet)
    group.add_command(run)
    group.add_command(analyze_run)
