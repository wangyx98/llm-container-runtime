# q42621604 — Execute process in Runc container via Garden API (compatibility) — DEFERRED

Status: analysed 2026-11-18, deferred by the user. Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread says
- Cloud Foundry Bosh Lite, Diego cell with Garden (gdn) on runc. On the cell, `runc exec <id> /usr/bin/printenv` prints the environment.
- The asker tries the same through the Garden API: `curl -X POST -d '{"path":"/usr/bin/printenv"}' localhost:7777/containers/<id>/processes` -> `{"Type":"","Message":"EOF","Handle":""}`. Adding `"user":"vcap"` changes nothing; adding `-H "Content-Type: application/json"` gives `curl: (56) Problem (2) in the Chunked-Encoded data`. Goal: run an arbitrary command in a container through the Garden API (curl or a Java HTTP client) and get its output.
- One answer (Garden maintainer, score 2, not marked accepted): the supported way is the Go client library (`container.Run(garden.ProcessSpec, garden.ProcessIO)`, then `process.Wait()`); the unsupported `gaol` CLI (`gaol create`, `gaol run -c ...`, `GAOL_TARGET`) also works; plain HTTP is possible in principle but the `run` endpoint hijacks the connection, stdin goes over the hijacked connection and stdout/stderr need two other endpoints, so streaming output is hard. Comments: the asker falls back to calling runc directly; the maintainer suggests the garden logs `/var/vcap/sys/log/garden/garden.std{out,err}.log`.

## Why it was deferred
- The reported symptom (EOF) comes from Garden's own protocol (connection hijack plus separate stdio endpoints), not from runc, the container runtime or the architecture; `runc exec` on the same container already works in the thread.
- Reproducing it needs an old Garden server (gdn) with its runc, init/dadoo/nstar and a rootfs, plus a Garden Go client (or gaol) for the control. In the sandbox the GitHub API for the release repository is not readable and Docker Hub is blocked; no pinned artifact with sha256 for x86_64 AND aarch64 was found (arm64 availability of gdn releases not established), so the dual-ISA requirement cannot be promised.
- Cost: maintaining an old Cloud Foundry platform stand-in for one API-wrapper question.
- Coverage: container exec itself (runc, ctr, crictl, nerdctl) is already covered; only the Garden SDK/API layer would be new (low to medium, as the screening note says).

## Reopen only if
- A pinned Garden server/client artifact for both x86_64 and aarch64 (version, sha256, runc) is available offline or from a reachable source, and the task can be limited to the Garden interface with the original request reproduced first (the POST that answers EOF), then solved through a supported client (Go client or gaol) or a correct hijack+stdio HTTP client.
- Contract to state in task.txt: the exec user, cwd, env and stream contract. Oracle: the Garden API run returns the expected stdout and exit code and the container's unique marker; the host PID/namespace of the process corresponds to the target container (not a host process); a direct host exec or a `runc exec` bypass must not pass; no residue after cleanup.

## Related cases
- Plain in-container exec: existing runc/ctr/crictl/nerdctl cases (see the case index). No Garden/Cloud Foundry case.
