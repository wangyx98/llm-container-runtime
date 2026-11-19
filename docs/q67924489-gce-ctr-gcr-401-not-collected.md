# q67924489 — Configure access to GCR for containerd CLI ctr (configuration) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19), after it had been marked deferred for the cloud environment. Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
On a GCE VM (not GKE) `sudo ctr images pull gcr.io/<path>` ends with `failed to resolve reference "gcr.io/<path>:latest": unexpected status code [manifests latest]: 401 Unauthorized`; Docker cannot be used. Answers: (1) GKE nodes use the VM's service account (not applicable, asker is not on GKE); (2) (2022) use the JSON key login of the GCR authentication methods: `ctr images pull -u '_json_key:{ "type": "service_account", ... }' gcr.io/<path>`.

## Why it was not collected
- Cloud identity is the only new point (the VM's service account, the metadata server's access token, a token handed to `ctr -u oauth2accesstoken:<token>`), and it needs a real GCE VM, IAM and a registry. The sandbox reaches no Google endpoint (`gcr.io`, `us-docker.pkg.dev`, the metadata server, `oauth2.googleapis.com` all fail) and has no GCP credentials. The screening note asks for a real GCE runner and a gcr.io test repository hosted by Artifact Registry with IAM, and says GCR must not be faked; the historical GCR backend was shut down, so any case would be a modern adaptation (Artifact Registry behind `gcr.io`), never the original service.
- The accepted route of the thread (static account/key with `ctr -u`) repeats q72298729; a local Basic-auth registry or a fake metadata server would be exactly the forgery the screening note excludes, and node-held registry credentials are covered by q73910486, q67635227, q76136482.
- The thread has no cause beyond "no credential given to ctr"; ctr, unlike the CRI, reads no node-wide credential file, which is already shown by q72298729 and q73910486.

## If it is taken up later
Needs a GCE VM with a service account and a gcr.io repository served by Artifact Registry (state in the note that the old GCR is gone). Bad state: `ctr images pull` without credentials gives the 401. Reference: token from the metadata server (or a key file) given as `-u oauth2accesstoken:<token>` / `_json_key:<json>`. Oracle: `ctr` pulls and runs a NEW remote digest with no Docker; an identity without permission fails, an identity with the role succeeds; no forged GCR.
