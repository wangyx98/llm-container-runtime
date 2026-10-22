# q75622952 — `unexpected media type text/html` pulling from Harbor (built, diagnostics)

Status: built and verified in the sandbox (x86_64, cgroup v1). 13 samples: 3 valid pass, 10 fail for their own reasons.

Honest scope: the lab is a **controlled stand-in for Harbor's routes** (a Python TLS front: /v2/ Bearer registry API, /service/token, every other path = portal page 200 text/html), not a Harbor. The cause shown (mirror endpoint with trailing slash `https://host/` -> containerd 1.6.17 CRI requests `/<repo>/manifests/<tag>` without /v2 -> portal HTML taken as the manifest, digest in the error = sha256 of the page) reproduces the question's exact CRI message, but it is an inference; the question kept no HTTP response, and the real config may differ. The thread's "trust the CA" answer does not fit (CA problems give x509 errors).

Check: lab hashes/front pid/containerd 1.6.17/system trust store unchanged; effective settings not weakened; cold `crictl pull` (pods + image removed) succeeds with the recorded repoDigest; log shows Basic token request + HEAD/GET of manifest below /v2/ with Bearer, nothing text/html; pod runs and prints per-run token; a second certificate from an untrusted CA must make a cold pull fail with `certificate signed by unknown authority`; anonymous manifest request still 401.

Valid: endpoint without slash (reference), `https://host/v2/`, mirror entry removed. Failing: no-op, CA in system trust only, skip_verify (settings check), CA bundle trusting the rogue CA too (behavioural rogue-cert check), no restart, ctr pre-pull, account removed, http:// endpoint, loopback endpoint, front edited.

Not run: cgroup v2 / arm64 (the target VM), real Harbor.
