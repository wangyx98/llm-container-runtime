# q36815374 — Runc Containerd Check pointing support (compatibility) — NOT COLLECTED

Status: analysed 2026-11-18, not built. Reason: the thread is a support/concept inquiry with no operation target; nothing to execute or verify.

## What the thread says
- The asker found a Docker tool, containerd, that uses runc natively, and asks three things: how it checkpoints a container, how to use it for live migration, and what the functional call sequence of its implementation is.
- No answers. One comment ("why not read this tool documentation?"); the asker replies that the documentation was read but did not show the answers nor the tools used to implement the checkpointing.
- No version, command, environment, error or restore target.

## Why it is not collected
- All three questions are about how something works (mechanism, call sequence). There is no operation, no failure and no final state that could be checked, so a precondition and an oracle cannot be written for the question as asked. This is the "fall back to a support inquiry when there is no clear operation target" case of the screening note.
- Making a checkpoint/restore task out of it would be our own invention, not the thread's, and would have to be labelled as unrelated to the original.
- Sandbox facts (2026-11-18): no `criu` binary, `apt-cache policy criu` has no candidate, kernel 6.18 (x86_64). CRIU/kernel/runc compatibility could not be measured here; it would have to be established on the VM first (aarch64 kernel 5.15, cgroup v2).

## Note for a future checkpoint/restore case (the gap is real, this thread does not fill it)
- Take a source question with a concrete restore operation. Fix a known working CRIU + kernel + runc combination for both x86_64 and aarch64 before anything else (time-box the search to 60 minutes; if none is found, defer).
- Workload: a static program that keeps a random marker and a counter only in memory and answers requests; the oracle must see that the restored process still holds the marker, the counter continues (not restarted from the initial value), it answers a new request, and the original process was stopped first. Checking only the existence of checkpoint files, or restarting the program, must fail.
- Reference: `runc checkpoint` then `runc restore` (or the containerd/CRI equivalents), stdio and mounts handled as CRIU needs.

## Related cases
- None for checkpoint/restore in the case index.
