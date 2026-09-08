"""
Thin wrapper around subprocess for running case scripts (setup.sh /
precondition.sh / oracle.sh / cleanup.sh) or LLM-generated shell snippets.

Every test_suite module should go through these two functions instead of
calling subprocess directly, so timeout / capture behavior stays consistent
across all cases.
"""

import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ShellResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def run_script(path: Path, timeout: int = 120) -> ShellResult:
    """Run an existing .sh file under bash and capture its output."""
    proc = subprocess.run(
        ["bash", str(path)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return ShellResult(proc.returncode, proc.stdout, proc.stderr)


def run_shell_snippet(code: str, timeout: int = 120) -> ShellResult:
    """Run an arbitrary shell snippet (e.g. an LLM-generated solution)."""
    proc = subprocess.run(
        ["bash", "-c", code],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return ShellResult(proc.returncode, proc.stdout, proc.stderr)
