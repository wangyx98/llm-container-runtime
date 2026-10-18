"""
SO-73434226: "OCI runtime exec failed: exec failed: unable to start container process: open /dev/pts/0: operation not permitted" (closed; the answers restart Docker, a comment names the cause:
runc 1.1.3, fixed in 1.1.4). A running container refuses every interactive (TTY) exec, a non-interactive one works.
The mechanism, reproduced on a real systemd: runc 1.1.3 with the systemd cgroup driver builds the DeviceAllow list of the container's scope from the container's device rules and drops the
entries that are not paths in /dev, so the pseudo terminal rule (`char-pts`) is missing from the scope (and the `m` rules too). The kernel's device rules are right as long as nothing
touches them; `systemctl daemon-reload` makes systemd apply the scope's own list again, and from then on the exec's `open /dev/pts/N` is refused (EPERM). The list is also short of every device node
when the host has no /dev/char/MAJOR:MINOR links (no udev): a sandbox without them fails at /dev/ptmx instead. runc 1.1.4 keeps the entry (`char-pts`, newer runc names it `char-136`).
A restart with the same runc only helps until the next reload. Measured on runc 1.5.1: its own `exec -t` works on a scope that lost the rule (the pty is made another way), so the oracle
judges with the engineer's runc (whatever it is after the solution) and with an oracle-owned copy of runc 1.1.3: upgrading the binary without making the container's scope right is not a fix.

The case needs a real systemd and runc of the machine that is 1.1.4 or newer. runc 1.1.3 (amd64 and arm64, sha256 pinned) is downloaded once into /var/cache/bench73434226 (kept by cleanup.sh).
No helper files: the workload (a heartbeat with a token) and a probe are two tiny static programs that setup.sh compiles; every stage is one script; the oracle's logic is a python block in oracle.sh.

setup.sh: the root file system (the two programs, sh/id/tty/cat/ls with their libraries, device nodes of a loop device, a disk and a serial port for the isolation check), the bundle (`runc spec`, the systemd
cgroup path `system.slice:bench73434226:web`), the container web started by runc 1.1.3 (`--systemd-cgroup run -d`), and the original steps: a TTY exec works, `systemctl daemon-reload`, the TTY exec fails.
precondition.sh: the machine as recorded; control 1: a non-interactive exec works; control 2: the TTY exec with runc 1.1.3 fails with `open /dev/pts/N: operation not permitted` twice and the scope has no pty rule;
control 3: a container made by the machine's runc keeps its TTY exec (the machine's and 1.1.3's) through two reloads.
The oracle: the machine's runc is unchanged; web is in runc's root, running, in the scope `bench73434226-web.scope`; the original workload (the token) keeps writing its heartbeat; six fresh TTY execs (the engineer's
runc and runc 1.1.3; no reload, one reload, three reloads) each print a fresh nonce on a /dev/pts/N and exit with the code they were given; non-interactive execs work; the isolation is kept (the device nodes of a loop
device, a disk and a serial port are refused by the device rules, /dev/null opens, no CAP_SYS_ADMIN, own pid/mnt/net/ipc/uts namespaces, own tmpfs /dev and devpts).

Where the samples fail: nothing done; a restart with runc 1.1.3 (works until the first reload: the oracle's reload catches it); chmod of the pty nodes (not what refuses); only the engineer's runc upgraded (its own exec works,
runc 1.1.3's does not); the container made again without the systemd cgroup driver (no scope); all devices allowed in a new container's bundle (the isolation is gone). The two valid solutions
replace the engineer's runc by the machine's and create the container again, or give the scope the missing rule with `systemctl set-property --runtime`.

Not a sample: `DeviceAllow=char-* rwm` and `block-* rwm` on the scope. On cgroup v1 it opens every device to the container (a single devices list, rewritten by systemd), but on cgroup v2 runc attaches its own BPF device
program to the container's cgroup next to the one systemd builds from the scope's DeviceAllow, and BOTH must allow: opening everything in the scope makes the TTY exec work and changes nothing for the other devices
(the oracle's probes stay refused; measured on the VM and in a v2 rig: two programs attached, only systemd's is replaced). So it is a valid, if sloppy, answer on v2 and a cheat on v1: not in the fixture.

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/compatibility/q73434226/ and converts their exit codes / output into a
structured `cases` dict.

Taxonomy category: Runtime Compatibility
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/compatibility/q73434226/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "compatibility" / "q73434226"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q73434226",
        "code": "<shell commands generated by the LLM>",
        "model": "optional model name, just for bookkeeping",
    }
    cfg: {"timeout": 60, ...}

    Returns (cases: dict, error_message: str | None), matching the
    run_tests(sample, cfg) convention.
    """
    cases: dict = {}
    error_message = None
    timeout = cfg.get("timeout", 60)
    cleanup_timeout = max(timeout, 120)      # the containers are deleted, their scopes stopped
    setup_timeout = max(timeout, 300)        # may download runc 1.1.3; builds the root file system, starts the container, reproduces the failure
    pre_timeout = max(timeout, 180)          # controls: failing TTY execs, a control container through two reloads
    solution_timeout = max(timeout, 180)     # a solution recreates the container and may test it
    oracle_timeout = max(timeout, 180)       # six TTY execs through three reloads, the isolation probes

    # 1. reset to a known clean state before every sample
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        return cases, error_message

    # 2. precondition oracle: the machine as recorded; the bad state is real (the TTY exec fails, a non-interactive exec works, a container of the fixed runc works)
    pre = run_script(CASE_DIR / "precondition.sh", timeout=pre_timeout)
    cases["precondition_passed"] = pre.ok
    if not pre.ok:
        error_message = "precondition failed: environment not in expected initial state"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 3. run the LLM-generated solution (falls back to no-op if empty,
    #    which is useful for testing that the oracle correctly fails)
    llm_code = sample.get("code", "")
    if llm_code.strip():
        solution = run_shell_snippet(llm_code, timeout=solution_timeout)
        cases["solution_executed"] = solution.ok
        cases["solution_stdout"] = solution.stdout[-2000:]
        cases["solution_stderr"] = solution.stderr[-2000:]
    else:
        cases["solution_executed"] = False
        cases["solution_stdout"] = ""
        cases["solution_stderr"] = "no code provided (no-op sample)"

    # 4. postcondition oracle: fresh TTY execs through systemctl daemon-reload, the workload and the isolation
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
