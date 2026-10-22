"""
SO-67635227: "Private docker.io registry in microk8s" (2021; MicroK8s hits the Docker Hub pull rate limit, `ctr` fails with 429 toomanyrequests; the asker edited
args/containerd-template.toml: a `mirrors."docker.io"` entry and a `configs."docker.io".auth` block with empty username/password/auth/email, "not working"; he wants a solution for the whole cluster,
not an imagePullSecret in every namespace. The thread has no answer: its one comment says the limit is Docker's and anything else is a hack.)

What is measured, and what is NOT: real Docker Hub quota, its 429 threshold and its token service cannot be reproduced or reached here, so the case is a controlled adaptation: a stand-in for Docker Hub
(hub.py: registry :5000 and token service :5001 on 127.67.63.52, anonymous token -> HEAD of a manifest works, GET of a manifest or blob answers 429 toomanyrequests; Basic credentials at the token endpoint ->
account token -> everything is served; one JSON line per request) reached through the engineer's `mirrors."docker.io"` entry. The reference solution is the case author's: the thread has none. The kubelet's
imagePullSecrets path is not exercised: the check creates Pods with `crictl run`, whose image pull is the CRI PullImage call without any credentials (namespace = the namespace of the pod sandbox).
`ctr` does not read the CRI plugin's registry settings at all (a `ctr` pull needs `--user`), so the check pulls through the CRI.

Measured (containerd 2.3.6 and 2.2.x, config version 3 and 4): with a mirror endpoint the credentials of `registry.configs.<key>.auth` are looked up by the HOST:PORT OF THE ENDPOINT that is pulled from
(`'127.67.63.52:5000'`), not by the name `docker.io` of the image: the account under `configs.'docker.io'` is never sent (the requests stay anonymous, 429), under `'127.67.63.52'` (no port) neither. With
the right key `username`/`password` and `auth` (base64 user:password) both work: containerd POSTs to the token endpoint first (405 here), then falls back to GET with Basic. `config_path` +
hosts.toml with a Basic `authorization` header also works (containerd >= 2.1 sends the host's headers to the token endpoint), but only when the `mirrors` entry is gone (both together do not load).
containerd.toml is generated from the template at every start (as MicroK8s does), so an edit of it is lost at the restart.

Adaptation (stated in task.txt): a private containerd of the host (2.x) started by mk8sctl through a launcher that renders the template (copied from q66642654), CRI only, no kubelet, host-network Pods.

precondition.sh: the lab is as its record says (hashes of hub.py, launcher, mk8sctl, account; the hub process; the sandbox image); the registry block is the engineer's (mirror to the hub, empty auth, no
config_path); the node's pull fails with toomanyrequests and the hub saw an anonymous GET answered 429; control 1: a throw-away containerd with the same template and the account filled in under
`docker.io` is still refused (requests anonymous); control 2: the account under the endpoint's key pulls the image as the account.
The oracle (oracle.sh): the lab unchanged, the hub still limits an anonymous reader; phase A (node as left) and phase B (after `mk8sctl restart`): for a Pod in namespace team-a and one in team-b, the
node's images of the account are removed, a NEW build is published (new tag, new digests), `crictl run` creates the Pod, the image id is the new build, the hub log shows the token service asked with the
account's Basic credentials (200), manifest and both blobs served to the account, every request from containerd, no 429, and the container prints the nonce and the salt of the new build. The node is the
containerd of mk8sctl, and containerd.toml equals the rendering of the template.

Where the samples fail: nothing done; the account under `docker.io`; the endpoint key without the port; the template fixed but no restart; containerd.toml edited then restart (regenerated); a wrong password;
`config_path` + hosts.toml while the mirror stays (the node does not load the configuration); a `ctr` pre-pull with the account (the check removes the image); the hub changed to remove the rate limit.
Valid: the account under the endpoint's key in the template + restart (reference); `auth` as base64; a second auth block next to the empty one; hosts.toml header + `config_path` with the mirror removed.

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/configuration/q67635227/ and converts their exit codes
into the structured `cases` dict.

Taxonomy category: Runtime Configuration
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/configuration/q67635227/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "configuration" / "q67635227"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q67635227",
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
    cleanup_timeout = max(timeout, 120)      # containerd, its shims, the hub
    setup_timeout = max(timeout, 300)        # two static programs are compiled, the node starts
    pre_timeout = max(timeout, 240)          # two control containerds are started
    solution_timeout = max(timeout, 150)     # a solution may restart the node
    oracle_timeout = max(timeout, 300)       # four pods, one restart

    # 1. reset to a known clean state before every sample
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 2. precondition oracle: the node is refused (429) as an anonymous reader; the account under the endpoint's key would work
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

    # 4. postcondition oracle: new Pods in two namespaces pull with the account, as left and after a restart of the node
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
