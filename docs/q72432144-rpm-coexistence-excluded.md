# q72432144 — Installing Podman next to Docker on CentOS Stream 8 (Runtime Compatibility): not built

Status: assessed, not built. Reason: no verified reference solution and a high build cost. This is a feasibility/cost exclusion, not a proof that the task is impossible, and it is not an architecture exclusion.

## What the question asks

On a CentOS Stream 8 build server with Docker 20.10.16 installed, `yum install podman` fails: the modular `podman-4.0.2` requires `runc >= 1.0.0-57`, while Docker's `containerd.io` (1.3.7 / 1.6.4) conflicts with and obsoletes the `runc` package. The asker wants both tools on one host.

## What was checked

- The historical packages are obtainable. In the vault listing of CentOS Stream 8 (AppStream) and Docker's el8 repository, both x86_64 and aarch64 contain `podman-4.0.2-1.module_el8.7.0+1106+45480ee0`, `containerd.io-1.6.4-3.1.el8` and `docker-ce-20.10.16-3.el8`. (The list of `runc` builds quoted in the question was not checked in full.) So the case is not excluded for missing artifacts.
- The test VM (Ubuntu 22.04, aarch64) and the sandbox have no `rpm` or `dnf`; an el8 user space would have to be built.

## Why it is not built

1. No known good answer. The thread has no answer. The two obvious ways out break the task's own constraints: `--allowerasing` removes Docker's packages, and `--nodeps` ignores the dependency instead of solving it. Without a verified clean resolution there is no `reference_solution.sh`, and without it no `oracle.sh` can be defined or validated.
2. Faithful reproduction is expensive. It needs a frozen local RPM repository (the old modular builds are probably hidden by the final vault metadata; this is an inference, not tested), a CentOS Stream 8 root directory with its own rpmdb on an Ubuntu VM, and Docker 20.10 plus Podman 4.0 running side by side in it (cgroup v2 host, overlay storage, private sockets). This is much heavier than the other cases and fragile.
3. Substitutes would change the problem. Newer packages, or AlmaLinux/Rocky builds, would produce another error than the one asked about; the benchmark's rule is not to mix in arbitrary packages to create a different failure.

## What would make it worth reopening

A short experiment: pinned RPMs plus a local repository, reproduce the reported conflict in an el8 container, then try candidate ways to coexist. If a non-destructive resolution is found, the case can be built with the usual five stages (conflict recorded in `precondition.sh`; `oracle.sh` checks that docker-ce, containerd.io and podman are all installed and unmodified, that both tools build and run an image with a fresh nonce, and that the original container is untouched). If none is found, the exclusion stands with evidence.

## Funnel label

"No verified reference solution / high environment cost". Do not count in the pass@1 denominator.
