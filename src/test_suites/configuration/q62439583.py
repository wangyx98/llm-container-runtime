"""
SO-62439583: "Unable to pull some image from jfrog artifactory with my containerd" (2020; containerd with JFrog Container Registry as the mirror of every registry:
`mirrors."*"`, `"docker.io"`, `"k8s.gcr.io"` and, by a typo, `"quai.io"`, all with the endpoint of the virtual repository `docker`; the sandbox image k8s.gcr.io/pause times out until an explicit
k8s.gcr.io entry is added; `quay.io/coreos/flannel:v0.11.0-amd64` ends with `unexpected status code [manifests v0.11.0-amd64]: 403 Forbidden`. The only answer (by the asker) says Artifactory
blocks the image because of a severe vulnerability: a policy of the server, not of the node.)

What is measured, and what is NOT: JFrog (its Xray policy, its remote-repository caches) cannot run here, and the cause the thread names cannot be reproduced; the case is a controlled adaptation
of the node's side of the question. A stand-in (jcr.py) serves two repositories, each on an address of its own (`docker`: virtual, member docker-remote, readable by the account ci only;
`quay-remote`: remote, readable by the account quay-reader only), HTTP Basic (no or wrong credentials 401 with a Basic challenge, valid credentials without permission 403, not in the repository 404),
in front of two stand-ins for Docker Hub and Quay that only the stand-in's caches may read. The 403 of the question is therefore modelled as an AUTHORIZATION failure (the engineer's account ci has no
permission on quay-remote), and the 404 as the routing failure that the typo `quai.io` causes (the Quay image falls to the wildcard and is looked for in `docker`); the reference solution is the case
author's, the thread has none. The kubelet's imagePullSecrets path is not exercised: the check creates Pods with `crictl run`, whose image pull is the CRI PullImage call without any credentials.

Measured (containerd 2.3.6, config version 3): (1) the legacy `mirrors."*"` entry IS honoured as the default route (deprecated, but it works: all registries without an entry of their own go to its
endpoint, an explicit entry such as `docker.io` wins; the same with `_default/hosts.toml` in a hosts directory), so the question's "the wildcard does not route k8s.gcr.io" is not reproducible on
the current engine and is not the case's problem; (2) the credentials of `registry.configs.<key>.auth` are looked up by the HOST:PORT OF THE ENDPOINT, so the two repositories on two addresses can
have two accounts; (3) a mirror endpoint with a PATH (the "repository path method" of Artifactory) is used by the legacy `mirrors` as it is, without `/v2` added, while hosts.toml adds `/v2`: that is why
the lab uses the port method, as the asker's subdomains do; (4) `config_path` and the legacy `mirrors`/`configs` cannot be used together.

precondition.sh: the lab is as its record says (hashes of jcr.py, nodectl, the accounts file; the stand-in process; the sandbox image); the registry block is the engineer's (four mirror entries, all to
`docker`, the name quai.io, ci for both endpoints, no config_path); the stand-in applies its rules (401, 200, 403, 404 by curl); the node pulls the Docker Hub image as docker.io and as k8s.gcr.io
through `docker` as ci, and the Quay image fails after a 404 from `docker` and no request to quay-remote (the error text is not checked: with network access containerd falls back to the real registry of the name, so the repository and tags are lab-only names); control 1: the wildcard alone sends all three names to `docker` (a working default
route, the Quay image 404); control 2: quay.io sent to quay-remote with ci is refused: 403 for ci on quay-remote in the stand-in's log (the question's error); control 3: with quay-reader for the endpoint of quay-remote the Quay
image is served and the Docker Hub image still comes from `docker` as ci (the lab can be solved).
The oracle (oracle.sh): the lab unchanged and its rules intact (probes with both accounts); phase A (node as left) and phase B (after `nodectl restart`): for docker.io/benchlab62439/web, k8s.gcr.io/
benchlab62439/web and quay.io/benchlab62439/flannel the node's images are removed, a NEW build is published to the matching public-registry stand-in (new tag, new digests), `crictl run` creates a host-network
Pod, the image id is the new build, every request of the pull comes from containerd to the right repository (docker, docker, quay-remote) as the right account (ci, ci, quay-reader) without a 403/404, the
manifest and both blobs are served to that account and read by the stand-in's cache from the public-registry stand-in (every request there from jcr-lab/1: no direct pull), and the container prints the nonce
and the salt of the new build.

Where the samples fail: nothing done; the typo fixed only (404 from docker); the typo fixed and quay.io sent to quay-remote with ci (403); the right endpoint and account under the name quai.io (the
Quay image still falls to the wildcard); the right file but no restart; quay-reader for every endpoint (docker 403); the wildcard and the k8s.gcr.io entry removed (the k8s.gcr.io name leaves the
JFrog); quay.io sent straight to the public-registry stand-in (caught by the user agent in its log); the account in the wrong key (without the port, or the name quay.io); `config_path` kept together with the
mirrors (the node's CRI does not load); the account's permissions changed; a pull by hand (the check removes the images).
Valid: the reference (typo fixed, quay.io to quay-remote, quay-reader for its endpoint, restart); `auth` as base64; the registry settings moved to a hosts directory (`config_path`, `_default` and `quay.io`
with Basic `Authorization` headers; the legacy tables removed); the explicit k8s.gcr.io and docker.io entries dropped (the wildcard covers them).

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/configuration/q62439583/ and converts their exit codes
into the structured `cases` dict.

Taxonomy category: Runtime Configuration
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/configuration/q62439583/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "configuration" / "q62439583"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q62439583",
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
    cleanup_timeout = max(timeout, 120)      # containerd, its shims, the JFrog stand-in
    setup_timeout = max(timeout, 300)        # two static programs are compiled, the node starts
    pre_timeout = max(timeout, 240)          # three control containerds are started
    solution_timeout = max(timeout, 150)     # a solution may restart the node
    oracle_timeout = max(timeout, 300)       # six pods, one restart

    # 1. reset to a known clean state before every sample
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 2. precondition oracle: the Quay image is looked for in the wrong repository (404); the right endpoint with ci is refused (403); with quay-reader it is served
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

    # 4. postcondition oracle: new Pods for the three names pull through the right repositories with the right accounts, as left and after a restart of the node
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
