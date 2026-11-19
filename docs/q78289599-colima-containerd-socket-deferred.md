# q78289599 — Using Colima, how to expose a containerd socket to the host? (compatibility) — DEFERRED

Status: analysed and deferred by the user (2026-11-18). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Colima 0.6.8 on a Mac. With `colima start --runtime docker` the host gets `~/.colima/default/docker.sock`; with `--runtime containerd` the directory holds only `colima.yaml` and `daemon`, no containerd socket on the host, although `colima ssh sudo ls -l /run/containerd/containerd.sock` shows it inside the VM. The only answer (by the asker, not accepted): the source code shows that socket forwarding is implemented for Docker only. There is no fix, no configuration and no code in the thread: the answer is "the feature does not exist".

## Why it was deferred
- Only reproducible on macOS with Colima (a Lima VM). Sandbox measurement (2026-11-18): no `/dev/kvm`, `cloud-images.ubuntu.com` not reachable; the Colima Linux binary (v0.6.8) is downloadable from GitHub releases, but without hardware acceleration a Lima VM cannot be started per sample. The Ubuntu 22.04 aarch64 test VM is itself a VM; nested virtualization is not reliable.
- The thread has no verifiable repair. The screening-note design (host SDK reaches the VM's containerd through a controlled socket or SSH forward, negative control when the forward is cut) is ours, not the thread's answer.
- Not a Windows limit; it is a missing macOS/Colima runner, outside the Linux x86_64 + arm64 batch.

## Coverage
- No case tests "host reaches a socket inside a VM through a forwarder". Closest: networking/q73394153 and q70704948 (a Rancher-Desktop-like VM as one network+mount namespace with proxy settings); q74953529 (macOS forwarding layer, not collected); q66597987 (Windows named pipe SDK, deferred: a Linux socket must not replace the original transport); q76980610 (Docker Desktop VM, deferred).

## If it is taken up later
- Reopen only with a shared macOS/Colima runner (pinned Colima/Lima/macOS versions), or a Linux runner with KVM where a real Lima VM can be started per sample.
- With a runner: create a unique object in the VM's containerd (an image or container with a per-run nonce); initial state: no usable socket on the host; allowed fix: an explicit, controlled forward (Lima `portForwards` with `guestSocket`/`hostSocket`, or `ssh -L` over `colima ssh-config`); the VM boundary stays. Oracle: a host-side containerd client reaches the requested endpoint, returns the unique object and runs a probe; cutting the forward is a negative control that must fail; a socket file that merely exists does not count. Not verified in this analysis: that Colima 0.6.8's configuration can express such a forward.
- Without a runner, the only buildable thing is a forwarding-mechanism variant (netns/mount ns as the "VM", private containerd and sshd, `ssh -L` unix-socket forward, host client + negative control, about 2-3 hours). It must be labelled as such in `task.txt` and the docs index and must not be counted as Colima or macOS coverage.
