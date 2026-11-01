# q58382208 — "How gVisor can protect host from dirty cow PoC?" (isolation) — NOT COLLECTED (skip)

Status: classified skip by the user and confirmed after a short check (2026-11-01). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
The asker read gVisor's Sentry code (`pkg/sentry/mm/syscalls.go`, `MemoryManager.Decommit` for `madvise(MADV_DONTNEED)`, which takes `mappingMu` and `activeMu`) and asks whether there is a structural reason gVisor avoided Dirty COW, or whether a race in the same place in the Sentry would let a PoC write a read-only file just like with plain Docker (the Sentry acts as root). The one answer quotes the gVisor mailing list: the Sentry does lock the memory manager to avoid the DirtyCow race, but nothing fundamental in the Sentry protects it from harmful races besides good coding and testing; gVisor's more fundamental protection is two layers of isolation from the host (the Sentry is a user-space process inside a locked-down Linux container), so code execution in the Sentry still needs an independent bug in the small Linux attack surface that container exposes.

## Why it was not collected
- It is an architecture / threat-model explanation, with no initial state to repair and no task a script could do or check.
- No failing state can be reproduced: the sandbox kernel (6.18) and the VM kernel (5.15) contain the fix for CVE-2016-5195 (Linux 4.8.3 and later); a vulnerable kernel cannot be booted on either.
- Dirty COW is a probabilistic race: a PoC that does not trigger proves nothing about protection, so no oracle could claim "protected".
- The only buildable parts are ordinary semantics (a `MAP_PRIVATE` write does not change the source file, `MAP_SHARED` permission behaviour), which are not protection against Dirty COW, probably behave the same on runc and runsc, and would misrepresent a vulnerability benchmark. "Checking the Sentry's isolation configuration" has no check that proves "an independent bug is needed to escape".
- Coverage: nothing in the index deals with Dirty COW, `madvise` or COW semantics; gVisor itself appears only in q63132692 (built), q72555998 (deferred) and q78668565 (not collected).

## If it is taken up later
Only with a deliberately vulnerable kernel (a pre-4.8.3 image booted in a VM the lab controls) and a bounded, repeatable trigger, and then as a kernel-vulnerability case rather than a gVisor one; a gVisor comparison would additionally need the same PoC run under runsc with the outcome (file unchanged) recorded over many repetitions, still without a claim of absolute safety.
