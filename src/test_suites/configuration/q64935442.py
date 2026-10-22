"""
SO-64935442: "How to configure microk8s kubernetes to use private container's in https://hub.docker.com/?" (2020; MicroK8s; the asker pushes a private image to Docker Hub, creates the Secret
`regcred` (`kubectl create secret docker-registry regcred ...`, the `docker login` way) and the Deployment `blaw` whose Pods stay in ErrImagePull / ImagePullBackOff with "pull access denied, repository
does not exist or may require authorization: server message: insufficient_scope: authorization failed"; the question text shows the Secret but not the Pod spec. The one answer: the Deployment must
reference the Secret, `imagePullSecrets: [{name: regcred}]` in the Pod template. The cause is inferred from the YAML in the question; the asker does not confirm it.)

What is measured, and what is NOT: a real private repository on Docker Hub (a real account, real quota) is not used, so the case is a controlled adaptation: a stand-in for Docker Hub (hub.py:
registry :5000 and token service :5001 on 127.64.93.54) with the rules of a private repository: an anonymous token is given but opens nothing (every request for the repository answers 401
`insufficient_scope`, the text containerd turns into the error of the question); the Basic credentials of the account at the token endpoint give an account token and everything is served; one JSON
line per request. The node is k3s (v1.30.5+k3s1, pinned, sha256 checked) on a private containerd 2.x (CRI), and docker.io is sent to the stand-in by a hosts.toml of the node (`server = ...`, no
credentials in it): that is the node's configuration, not part of the problem. Whether an unreferenced Secret is "a runtime problem" is weak: the part that reaches the runtime is the kubelet's
PullImage call carrying the credentials of the Pod's imagePullSecrets (the registry name of the image, docker.io, is matched against the key of the Secret, `https://index.docker.io/v1/`), the pull by
containerd through the endpoint of the hosts file, and the image store of the node (an image pulled once serves every later Pod with the default pull policy, whatever its secrets).

Measured (containerd 2.3.6 and 2.2.3, k3s v1.30.5+k3s1): the request-supplied credentials of the CRI call are used against the hosts.toml endpoint (the token service sees Basic hubuser; POST to it answers 405 and
containerd falls back to GET); a Pod that does not name the Secret pulls anonymously and gets the error of the question; a Secret in the namespace of the Pod is needed (Secrets are namespaced).

precondition.sh: the lab is as its record says (hashes of hub.py, account, hosts.toml, containerd and k3s configuration, control scripts; the hub process; containerd and k3s running; the node Ready); the Secret
regcred is there (type kubernetes.io/dockerconfigjson, key https://index.docker.io/v1/) and neither the Deployment nor the default service account names a pull secret; the Pod of blaw fails to pull
with `insufficient_scope: authorization failed` and the hub saw only anonymous requests; control: a Pod that names the Secret in a throw-away namespace runs the image (the account is valid), then the
namespace and the image are removed.
The oracle (oracle.sh): the lab unchanged, the hub still private; the Deployment blaw (default namespace, image benchlab64935/blaw-service:v0.3.10, 1 replica) is scaled to 0, the image is removed from the
node, a NEW build is published under the same tag; a negative control Pod WITHOUT a pull secret in another namespace must stay in ErrImagePull / ImagePullBackOff (the node must not hold credentials of
its own); blaw is scaled to 1 and its Pod must become Running and Ready, owned by the Deployment, with an imageID ending with the new manifest digest and the new salt in its log, and the hub log shows the token
service asked with the account's Basic credentials, the manifest and both blobs served to the account, every request from containerd.

Where the samples fail: nothing done; the Secret recreated but still not referenced; a Secret name that does not exist; the Secret in another namespace; a generic Secret (`--from-file=config.json`, key
config.json; or with the key `.dockerconfigjson` but no `--type`: the kubelet uses only Secrets of type kubernetes.io/dockerconfigjson); a wrong password; a Secret for the key of the lab's endpoint (127.64.93.54:5000) instead of docker.io; imagePullSecrets under the container (the API server rejects the manifest); credentials
put into the node's hosts.toml (the lab's files changed; they would also make a Pod without a secret pull); a pre-pull with `ctr` (the check removes the image); the hub made public (hub.py edited).
Valid: patch of the Pod template (reference); the whole Deployment applied again with the field; the default service account patched and `rollout restart`; the Secret recreated for `docker.io` plus the patch.

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/configuration/q64935442/ and converts their exit codes
into the structured `cases` dict.

Taxonomy category: Runtime Configuration
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/configuration/q64935442/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "configuration" / "q64935442"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q64935442",
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
    cleanup_timeout = max(timeout, 180)      # k3s, containerd, its shims, the hub
    setup_timeout = max(timeout, 600)        # k3s may be downloaded, two static programs are compiled, the node starts
    pre_timeout = max(timeout, 240)          # a control Pod is pulled and removed
    solution_timeout = max(timeout, 150)     # a solution may wait for a rollout
    oracle_timeout = max(timeout, 300)       # scale down, a negative control, scale up

    # 1. reset to a known clean state before every sample
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 2. precondition oracle: the Pod of blaw is refused as an anonymous reader; the same image runs when the Pod names the Secret
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

    # 4. postcondition oracle: a new build of the image is pulled by a new Pod of blaw with the account; a Pod without the Secret is still refused
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
