"""
SO-68630845: "Kubernetes fails to pull images from gitlab registry unknown-sha256: <4ca..252> unexpected commit digest precondition" (2021). A containerd node of a bare-metal cluster pulls an image from a
GitLab container registry (https://HOST:5050/USER/PROJECT/nginx:v1, deploy token as imagePullSecret); every pull ends with `failed commit on ref "unknown-sha256:D1": unexpected commit digest sha256:D2,
expected sha256:D1: failed precondition`, while `docker pull` and `ctr image pull` work. The only answer: a mistake in the registry section of /etc/containerd/config.toml, the endpoint without the port
`HOST:5050`.

What was measured (containerd 1.6.6 and 1.6.17, crictl 1.34, distribution registry 2.8.3, linux/amd64 in the Claude sandbox): a mirror entry for `HOST:5050` whose endpoint is `https://HOST` (port 443) sends
the CRI's requests to the host's web application, which answers /v2/... with a redirect to its sign-in page (200 text/html, a CSRF token that differs at every request). Without a Docker-Content-Digest
header containerd takes the sha256 of the page the HEAD/GET of the tag gave as the manifest's digest D1, labels the unknown media type with the ref `unknown-sha256:D1`, asks for D1 as a blob (another
redirect, another page, digest D2) and fails with exactly the question's message. With the endpoint `https://HOST:5050` the same pull goes to the registry (token from the web application's /jwt/auth,
manifest by tag and by digest, blobs). `ctr` never reads the CRI's mirror entries, which is why it worked. A stable page would give `unexpected media type text/html` instead (q75622952).

HONEST SCOPE: the GitLab host is a controlled stand-in (the sandbox cannot reach gitlab.com or packages.gitlab.com and a GitLab omnibus is not feasible here): the registry is the REAL distribution 2.8.3
with token authentication (JWT signed by the stand-in, kid computed as libtrust does), the web application on port 443 is a Python stand-in (routes only: /jwt/auth, /users/sign_in, a redirect for the rest)
and NOT GitLab. What the asker's host answered on port 443 is not in the question: the stand-in reproduces the message form exactly, it does not prove the asker's host behaved this way. Only containerd
1.6.x was run (the asker's 1.4/1.5 needs another crictl); the two ports are the real 443 and 5050 on the alias 10.68.63.45 of lo, setup refuses to run when either is taken.

precondition.sh: lab files, processes and listeners; the node's effective settings are the question's (CA for both names, mirror endpoint without port); the registry is fine (401 + realm, the token for the
deploy token, the manifest under the recorded digest, refused without a token or with an anonymous one) and the web application gives a sign-in page that differs at each request; `ctr images pull` with
the CA and the deploy token works and is removed (content too); the CRI pull fails with the question's message, D1/D2 equal the sha256 of two different pages in the web application's log, the node asked
the manifest path and then D1 as a blob (302), and the registry's log has nothing of it.
The oracle (oracle.sh): lab files, processes and trust store unchanged; no verification skipped and every mirror endpoint of the project https on the registry's address with its port; cold `crictl pull`
with the deploy token succeeds with the recorded repoDigest; the registry's log shows HEAD by tag, GET by digest and blobs (200) to containerd; the web application's log only /jwt/auth for it (no /v2/,
no sign-in page); a pod runs the image (per-run token in its log); a wrong password and no credentials still fail; the registry refuses a manifest request without a token.

Where the samples fail: no-op; http scheme (the registry speaks TLS); a trailing slash after the port (the path is taken as the API root: the registry
says not found); no restart; TLS verification switched off; the deploy token added to the config with the endpoint unchanged; the image copied by ctr only; the web application edited. Valid: the reference
(endpoint with the port, restart); the endpoint with /v2/; the mirror entry removed; a registry config directory (hosts.toml, the mirror and the configs tables removed: config_path refuses them); a mirror
endpoint that does not work (port 5051, nothing listens; or an explicit :443, which has no CA entry in the configs table and fails the TLS check): the CRI tries the mirror, fails, and falls back
to the original host, so the pull still reaches the registry (only a mirror that ANSWERS with a trusted certificate, as the web application does, breaks it).

This module does NOT reimplement the test logic in Python. It just orchestrates the existing bash scripts under cases/diagnostics/q68630845/ and converts their results into the structured `cases` dict.

Taxonomy category: Runtime Diagnostics
"""

from pathlib import Path

from src.utils.shell import run_script, run_shell_snippet

# cases/diagnostics/q68630845/ relative to the repo root
CASE_DIR = Path(__file__).resolve().parents[3] / "cases" / "diagnostics" / "q68630845"


def run_tests(sample: dict, cfg: dict):
    """
    sample: {
        "case_id": "q68630845",
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
    cleanup_timeout = max(timeout, 180)      # containerd, mounts
    setup_timeout = max(timeout, 600)        # the first run downloads 70 MB; later runs take 15 s
    pre_timeout = max(timeout, 240)          # curl controls, a ctr pull and one failing CRI pull
    solution_timeout = max(timeout, 180)     # a solution edits the configuration, restarts containerd and pulls
    oracle_timeout = max(timeout, 400)       # two cold pulls, a pod and a failing pull

    # 1. reset to a known clean state before every sample
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    setup = run_script(CASE_DIR / "setup.sh", timeout=setup_timeout)
    cases["setup_ok"] = setup.ok
    if not setup.ok:
        error_message = f"setup.sh failed: {setup.stdout.strip()[-300:]} {setup.stderr.strip()[-300:]}"
        run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)
        return cases, error_message

    # 2. precondition oracle: the registry is fine, the node's settings are the question's, the pull fails with "unexpected commit digest" between two sign-in pages
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

    # 4. postcondition oracle: cold pull and run through the CRI with the deploy token, the registry's own responses, verification and authentication still working
    oracle = run_script(CASE_DIR / "oracle.sh", timeout=oracle_timeout)
    cases["oracle_passed"] = oracle.ok
    cases["oracle_output"] = oracle.stdout[-2000:]
    if not oracle.ok:
        error_message = error_message or f"oracle failed: {oracle.stdout.strip()[-500:]}"

    # 5. always tear down afterwards, whether it passed or not
    run_script(CASE_DIR / "cleanup.sh", timeout=cleanup_timeout)

    return cases, error_message
