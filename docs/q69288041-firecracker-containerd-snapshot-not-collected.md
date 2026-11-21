# q69288041 — How can I snapshot and restore firecracker VM running containers using firecracker-containerd? (filesystem) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-21). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
The asker runs containers in a Firecracker microVM through firecracker-containerd and asks whether firecracker-containerd has an API (usable from Go) to snapshot and restore a microVM that runs a container, or whether he has to use Firecracker's own snapshot API (pause, snapshot, resume, load snapshot) described in the Firecracker repository. The page has only the question: no answer, no comment, so there is no reference solution and no stated success contract.

## Why it was not collected
- The sandbox has no `/dev/kvm` (checked 2026-11-21: no device, no vmx/svm flags in `/proc/cpuinfo`, x86_64). Firecracker needs KVM, so not even a minimal microVM can be started here and nothing could be verified. The project has no KVM runner (see also q48609712: no VM runner exists); whether the test VM (Ubuntu 22.04 aarch64) exposes KVM was not known.
- It is a question about whether an API exists (the same kind as q36815374), not a failure or a target state. A task such as "memory nonce and counter continue after restore" would be our own design.
- It is not a containerd filesystem snapshot (snapshotter); restoring only the disk is not a restore of the VM's state, so no existing snapshotter-style case stands in for it.
- Cost: firecracker-containerd, Firecracker, guest kernel and rootfs (with the guest agent) pinned for x86_64 and arm64, a devmapper snapshotter (thin pool), CNI with tc-redirect-tap, and guest-side checks; estimated one to two days, all of it behind KVM.
- Coverage: no Firecracker or microVM case exists; the gap is real but the dependency list is long.

## If it is taken up later
Only with a runner that has `/dev/kvm` on both x86_64 and aarch64 and pinned Firecracker, firecracker-containerd, guest kernel and rootfs for both. Workload in the guest: a program that keeps a random memory nonce and a counter, writes a checksummed file to the disk, answers a request. Oracle: after snapshot, stop and restore the nonce and counter continue (not restarted), the guest and the container process run, the disk checksum is kept, the network comes back as the contract says; a cold start that reruns the workload, or a restore of the disk only, must fail. The Firecracker snapshot API (create snapshot of a paused VM, load snapshot) is the reference; whether firecracker-containerd of the pinned version exposes it must be measured first.
