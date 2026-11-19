# q76703140 — How to configure containerd to use AWS ECR? (configuration) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
The asker pulls from ECR with Docker but not with containerd. In `/etc/containerd/config.toml` he set `registry.auths."<acct>.dkr.ecr.ap-southeast-1.amazonaws.com"` with `username = "AWS"` and `auth = "<value from .docker/config.json>"`. No error text is quoted. The only answer (not accepted, 0 votes): pull with the docker CLI, export the image, import it into containerd (costs disk twice). No one names a root cause.

## Why it was not collected
- Third-party platform: ECR credentials are a 12-hour token from `aws ecr get-login-password` (IAM identity, STS/ECR API). The screening note asks for a real ECR repository, a minimal IAM identity, a rotatable token and ECR provenance / credential audit, and says a mock does not replace it. The sandbox reaches none of `public.ecr.aws`, `ecr.<region>.amazonaws.com`, `sts.amazonaws.com` (connection fails) and has no AWS CLI or ecr-login helper, so not even one real pull could be measured.
- A local stand-in (Basic-auth registry, expiring token) would lose ECR itself and add only "static credential expired, edit the config, restart containerd", which is already covered: node-held registry credentials q67635227 / q76136482, registry 401 chains q69088569 / q64513122 / q75622952, kubelet pull secrets q64935442.
- The root cause is not established by the thread (expired token, a missing `auth` because the Docker config uses a credential helper, or `username` mixed with `auth` are all possible). ECR's own mechanisms (kubelet image credential provider, `docker-credential-ecr-login`) live outside containerd.
- No Windows or architecture limit: the case is out for the platform, not for x86/arm64.

## If it is taken up later
Needs a host with AWS network access, a test ECR repository and a least-privilege IAM identity that can rotate tokens. Bad state: expired or missing token (static `auths` entry) -> pull fails with 401/`authorization failed`; reference: fresh token written into the CRI registry auth (or an `Authorization` header in a `hosts.toml`) and containerd restarted, or a credential provider; oracle: a NEW digest pushed to ECR, old token fails, refreshed token pulls and runs, ECR source and credential audit kept (no mock).
