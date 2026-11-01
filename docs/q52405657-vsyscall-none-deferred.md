# q52405657 — "Segmentation fault when executing binary in runc container" (runc 1.0.0-rc5+dev, file capability + chpst; fixed by `vsyscall=emulate`) (isolation) — DEFERRED

Status: deferred by the user (2026-11-01) after a feasibility check. Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
A start-up script in a runc container (BOSH-style job; runc `1.0.0-rc5+dev`, commit 69663f0) runs as root `setcap cap_net_bind_service=+ep ${PACKAGE_DIR}/bin/my-binary` and then `chpst -u vcap:vcap my-binary --config ...`; every run ends with `Segmentation fault`. The same command by hand in the container works; so do: no `chpst` (as root), no `setcap`, or `chown vcap:vcap my-binary`. None of these is an option for the real deployment. Replacing the binary's code by a 2-hour sleep changed nothing. One answer (by the asker): the kernel log has `bosh-dns[PID] vsyscall attempted with vsyscall=none ip:ffffffffff600000 ...` and `segfault at ffffffffff600000 ip ffffffffff600000 ... error 15`; adding `vsyscall=emulate` to the kernel command line fixed it ("I don't know why").

## What it is
x86_64 only: an old (pre-vDSO-aware, e.g. old Go) binary calls the legacy vsyscall page at the fixed address `0xffffffffff600000`; a kernel booted with `vsyscall=none` (or built with `CONFIG_LEGACY_VSYSCALL_NONE`) has no such page and the process gets SIGSEGV. It is not a permission problem. The thread does not explain why `setcap`, `chpst` or the owner switch the crash on and off (they changed which code path ran, or the observations are coincidental); no claim is made here.

## Measured on 2026-11-01 (sandbox: x86_64, kernel 6.18.44, a cloud VM with a fixed command line)
- `CONFIG_LEGACY_VSYSCALL_XONLY=y`, `CONFIG_LEGACY_VSYSCALL_NONE` not set; `/proc/self/maps` shows `ffffffffff600000-ffffffffff601000 --xp [vsyscall]`.
- A small C program that calls the vsyscall `time` entry (`0xffffffffff600400`) runs fine: `vsyscall time() ok`. So on this kernel the old binary of the thread does not crash.
- The failing state needs a kernel booted with `vsyscall=none`; the sandbox cannot be rebooted or given another command line.

## Why it was not built
- Platform: the failure exists only on x86_64 with `vsyscall=none`. The sandbox kernel cannot be restarted with that parameter; the VM is Ubuntu aarch64, which has no vsyscall page at all (no crash, and `vsyscall=emulate` has nothing to compare). The fix itself (change the kernel command line and reboot) cannot be a step of a script oracle, and the screening note forbids changing boot parameters on a shared runner or on macOS.
- No stand-in: nothing in seccomp, namespaces, runc options or the runtime can make the vsyscall page disappear for one container; a program that crashes by itself at that address would test our own crash, and an arbitrary capability error is not a SIGSEGV.
- Artifacts missing: the original binary (bosh-dns), chpst, the old libc and runc rc5 are not at hand.
- Coverage: no existing case deals with vsyscall, SIGSEGV at start-up or a file capability (the file-capability angle appears only in the deferred q59763024 note).

## If it is taken up later
Needs a recoverable x86_64 machine that can be booted twice, once with `vsyscall=none` and once with `vsyscall=emulate` (a VM with a bootloader the lab controls, not the shared runner), plus an old Go-era binary that really uses the vsyscall page (pinned by sha256; a static program calling `0xffffffffff600400` is the minimal stand-in and must be labelled as such), runc rc5 or a modern runc with the same spec, a non-root user, the file capability `cap_net_bind_service=+ep` and the original owner (root). Bad control: SIGSEGV with the kernel log line `vsyscall attempted with vsyscall=none`. Oracle after the change and reboot: same binary, same non-root identity and file capability, the program does its real work (a random request answered / a heartbeat number advancing, the port bound if it is a service), no SIGSEGV; a run as root or without the capability, or only "no crash", must not pass.
