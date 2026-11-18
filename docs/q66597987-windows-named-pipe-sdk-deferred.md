# q66597987 — "how to connection to containerd on windows using sdk?" (Go SDK over a Windows named pipe) (compatibility) — DEFERRED

Status: assessed and deferred by the user (2026-11-18). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
A question plus the asker's own answer. The containerd getting-started example uses `containerd.New("/run/containerd/containerd.sock")`. The asker works on Windows, where containerd's log says `serving... address="\\\\.\\pipe\\containerd-containerd"`, and asks how to use that in the code. The only answer (by the asker): `client, err := containerd.New(`\\.\pipe\containerd-containerd`)`. No error text, no Go or containerd version, no object to look up.

## Why it was deferred
- The whole question is the Windows transport: the Go SDK dials a named pipe on Windows; the same string on Linux is a meaningless unix-socket path. A real case needs a Windows host with `containerd.exe` as a service, a Go SDK client and a PowerShell variant of the five stages (the harness `run_script` / `run_shell_snippet` is bash). The sandbox is x86_64 Linux and the test machine is Ubuntu 22.04 aarch64: neither can run Windows containers or a Windows containerd, and the project has no Windows runner (x86_64 or arm64).
- A Linux stand-in (private containerd on a non-default unix socket plus a Go SDK client) does not keep the meaning of the question and was not built; the screening note says the Linux socket or a TCP mock must not replace the named pipe.
- The answer is one line that a model can give from the containerd documentation, so the value per sample is low even with a runner.

## Coverage
- No Windows, named-pipe or Go SDK case exists in the repo (checked in the case index on 2026-11-18). Coverage value is high only if a Windows runner exists (Windows transport plus SDK).
- Same reason as q64667740 (ACI/LCOW), also deferred.

## If it is taken up later
Reopen only when a Windows batch with a runner exists; then prefer it before complicated hcsshim threads. Design sketch: Windows runner with a pinned containerd and Go version; a daemon with one unique pre-created object (container or image with a per-run nonce); initial state keeps the Linux default path `/run/containerd/containerd.sock` in the sample Go program, the named pipe transport and the needed permissions stay; the Go SDK connects through the named pipe and returns the daemon version and the object ID (a real query or run succeeds); a wrong pipe name is a negative control that must fail; a Linux socket or an unrelated TCP mock does not count. Both x86_64 and arm64 Windows would be needed to keep the dual-ISA rule.
