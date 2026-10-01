"""
Thin wrapper around subprocess for running case scripts (setup.sh /
precondition.sh / oracle.sh / cleanup.sh) or LLM-generated shell snippets.

Every test_suite module should go through these two functions instead of
calling subprocess directly, so timeout / capture behavior stays consistent
across all cases.

Timeouts: if a command runs longer than `timeout` seconds it is killed and
the call RETURNS a ShellResult with `timed_out=True` and `returncode=124`
(the same code GNU `timeout` uses), instead of raising
subprocess.TimeoutExpired. That matters because an LLM-generated solution
can easily hang (an interactive editor, `wait` on a background job that
never ends, ...), and the caller still needs to go on to run the oracle and
the final cleanup.sh instead of crashing with a traceback halfway through
the lifecycle. A timed-out result is never `.ok`.
"""

import subprocess
from dataclasses import dataclass
from pathlib import Path

# GNU coreutils `timeout` exits with 124 when the command timed out
TIMEOUT_RETURNCODE = 124


@dataclass
class ShellResult:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out


def _to_text(data) -> str:
    """TimeoutExpired carries whatever output was captured so far. Depending
    on the Python version that is bytes, str or None, even in text mode."""
    if data is None:
        return ""
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return data


def _run(cmd: list[str], timeout: int) -> ShellResult:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        # subprocess.run() has already killed the direct child (bash) here.
        # Anything bash spawned in the background may still be alive; each
        # case's cleanup.sh is responsible for removing those.
        note = (
            f"[TIMEOUT] killed after {timeout}s without finishing "
            f"(solution/script hung or was too slow)"
        )
        stderr = _to_text(exc.stderr)
        stderr = f"{stderr.rstrip()}\n{note}\n" if stderr.strip() else f"{note}\n"
        return ShellResult(TIMEOUT_RETURNCODE, _to_text(exc.stdout), stderr, timed_out=True)
    return ShellResult(proc.returncode, proc.stdout, proc.stderr)


def run_script(path: Path, timeout: int = 120) -> ShellResult:
    """Run an existing .sh file under bash and capture its output."""
    return _run(["bash", str(path)], timeout)


def run_shell_snippet(code: str, timeout: int = 120) -> ShellResult:
    """Run an arbitrary shell snippet (e.g. an LLM-generated solution)."""
    return _run(["bash", "-c", code], timeout)
