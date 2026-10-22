"""
SO-63132692: "Unable to fetch cpu pod metrics, k8s- containerd - containerd-shim-runsc-v1 - gvisor" (2020; k8s 1.15.3, containerd 1.3.3, runsc nightly 2019-09-18; after moving from the
v1 shim to containerd-shim-runsc-v1 the metrics API shows CPU and memory for nodes and runc pods but only memory for the gVisor pods; CPU stays 0, the HPA says 0%/50%, metrics-server logs "no metrics
known for pod". The only answer, by a gVisor maintainer: gVisor currently reports only memory and PIDs per container (runsc/boot/events.go), more statistics are tracked in gVisor issue 172.)

What is measured, and what is NOT: a kubeadm cluster with kubelet, metrics-server and an HPA (k8s.gcr.io / registry.k8s.io are refused here, and a current kubelet takes its CPU from other sources than
the 1.15 one, so the zero at the metrics API cannot be promised) is not built. The case is a controlled adaptation at the two layers below it: a private containerd 2.x with the CRI, the runtime handler
runsc (gVisor's shim io.containerd.runsc.v1, one pinned build of the shim, the same for every runsc) and runc; three pods that use the network of the node (there is no CNI): gv-busy and gv-idle in gVisor,
rc-busy in runc as the control, running a busy loop / sleeping. The statistics are read from the CRI (`crictl stats`) and from containerd (`ctr -n k8s.io tasks metrics`), which is where the kubelet and
the metrics-server of the question get them. Four releases of runsc are on the disk, found through node/bin/runsc (a link) by the shim: 20210125.0 (what the node runs: no CPU in `runsc events`, the shim
reports 0), 20210208.0 (reports a CPU counter, but not the pod's own: a pod that uses one CPU grows at 2.5 core/s, the sleeping one at 0, and the counter starts at hundreds of seconds), 20230306.0 and
20260105.0 (the pod's own CPU: about one core for the busy pod, nothing for the sleeping one). The reference solution is the fix that the answer implies: a gVisor release that exports the CPU.

cgroup v1 ONLY: gVisor before 2022 knows only cgroup v1 (it makes /sys/fs/cgroup/cpu/<parent>/<id> and writes cpu.shares; on a cgroup v2 host the file does not exist and the open fails with "permission denied"),
and the releases that run on cgroup v2 (systemd cgroup support of 2022-03-17 and later) all export the CPU, so on a cgroup v2 host (Ubuntu 22.04 boots in it) the symptom cannot exist: setup.sh prints NOT APPLICABLE and
exits 1; run the case on a cgroup v1 (hybrid) host (kernel command line systemd.unified_cgroup_hierarchy=0) and leave it out elsewhere.

Measured (containerd 2.3.6, runc 1.5.1, cgroup v1, x86_64): the first release that reports CPU at all is between 20210201.0 and 20210208.0; releases before that report 0; a newer runsc cannot read the state
files of sandboxes made by an older one (`crictl stopp` fails with "cannot unmarshal number"), so the old pods are removed BEFORE the release is switched; `runsc` with the host network cannot report events
at all in a new release ("/proc/net/dev is not opened for hostinet"), so runsc's file says network = "none"; the shim lowers its OOM score to -999 at its start, which needs CAP_SYS_RESOURCE: where that is
missing (a restricted sandbox) setup patches the node's copy of the shim, elsewhere it does not touch it.

precondition.sh: the lab's files are as recorded; the node runs 20210125.0; the three pods are Ready with their handlers; the runc control grows at about one core at both layers while the gVisor pods
report a CPU of 0 and a working set > 0; and, as a control that the lab can be solved, a fresh gVisor pod under 20260105.0 (switched for the check, restored) grows.
The oracle (oracle.sh): the lab's files unchanged; the runsc that the node finds is a file of one of the lab's releases (no wrapper); exactly the pods gv-busy, gv-idle (handler runsc), rc-busy (the same pod
and container as at setup), each with one running container of the lab's image running its program; the sandbox processes of the gVisor pods run a binary of the lab's releases; over 6 seconds, at both
layers, gv-busy grows like the control (and its counter is possible for its age), gv-idle grows almost nothing, the two layers agree.

Where the samples fail: nothing done; the release switched but the pods not recreated (the old sandboxes cannot report); the pods recreated with the old runsc; the release 20210208.0 (a number that is not the
pod's); the gVisor pods replaced by runc pods; the pods only deleted; a wrapper script as runsc; a pod definition edited; the control pod recreated; an extra pod left running; only one of the two pods recreated.
Valid: the reference; the release 20230306.0; a copy of the release's file in place of the link.

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/diagnostics/q63132692/ and converts their exit codes
into the structured `cases` dict.

Taxonomy category: Runtime Diagnostics
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/diagnostics/q63132692/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "diagnostics" / "q63132692"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q63132692",
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
    cleanup_timeout = max(timeout, 180)      # pods, gVisor sandboxes and shims, containerd
    setup_timeout = max(timeout, 900)        # the first run downloads about 170 MB of gVisor files; later runs take half a minute
    pre_timeout = max(timeout, 240)          # measures twice, then runs a probe pod under a newer runsc
    solution_timeout = max(timeout, 240)     # a solution stops and runs pods
    oracle_timeout = max(timeout, 180)       # reads the processes and measures

    # 1. reset to a known clean state before every sample (setup.sh refuses a cgroup v2 host: NOT APPLICABLE)
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 2. precondition oracle: runc reports its CPU, the gVisor pods (runsc 20210125.0) report memory and a CPU of 0, and a newer runsc fixes it
    pre = run_script(CASE_DIR / "precondition.sh", timeout=pre_timeout)
    cases["precondition_passed"] = pre.ok
    if not pre.ok:
        error_message = f"precondition failed: environment not in expected initial state: {pre.stdout.strip()[-400:]}"
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

    # 4. postcondition oracle: the gVisor pods report their own CPU at both layers, still in gVisor, the control and the lab untouched
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
