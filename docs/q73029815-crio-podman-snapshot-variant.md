# q73029815 — "not showing kubernetes pods in podman" (compatibility, built as a VARIANT)

Status: built and verified in the sandbox (real CRI-O 1.34.0 + Podman 4.9.5; Podman 3.4.4 built from source for the import/ps/mount checks). NOT yet run on the VM (Ubuntu 22.04 aarch64, cgroup v2, apt Podman 3.4.4).

## Decision: original constraint vs variant
Original ask: see the CRI-O containers with Podman and `podman commit` one. Measured, this cannot be met on the VM stack:
- `podman ps -a` shows no CRI-O container (both versions).
- `podman commit` of a CRI-O container fails ("no such container") in 3.4.4 and 4.9.5; with 4.9.5 `inspect`, `stop`, `cp`, `export` also fail.
- Podman 4.9.5: `ps -a --external` lists them (state "Storage") and `podman mount` works. Podman 3.4.4: `ps -a --external` is EMPTY, because CRI-O 1.34 keeps its containers in `overlay-containers/volatile-containers.json`, which the older containers/storage library does not read.
So "Podman-native list/commit" is not satisfiable; per the screening condition ("original constraint unchanged -> do not collect; alternative-tool query -> variant") the case was built as the tool-free variant: reach the goal of the commit (an image in root's Podman store with the container's CURRENT files, runnable) by any route.

## Valid routes (all pass the oracle)
1. `crictl inspect CTR` -> `info.runtimeSpec.root.path` (the mounted `.../overlay/<id>/merged`), `tar -C` it, `podman import --change 'CMD ["/bin/sh"]' -`.
2. `crictl exec CTR tar -C / -cf - --exclude=proc --exclude=sys --exclude=dev .` into `podman import`.
3. `podman build` of `FROM busybox` + `ADD upper.tar /` where upper.tar is the writable layer (`.../overlay/<id>/diff`).

## Oracle idea
Two CRI-O pods from the same image, each with an `app` container whose workload writes random data after it started (two new files, one appended line in `/etc/passwd`); a Podman container as a third object. Truth (ids, start times, sha256 of the changed files and of /bin/busybox) is recorded at setup. The check: source untouched (same containers RUNNING with the same startedAt), image exists in root's Podman store, `podman run --entrypoint /bin/sh` prints the recorded checksums. Wrong: other pod, Podman's container, base image only, writable layer only (not runnable), no image, source pod removed.

## VM-only (not verified)
Podman 3.4.4 on aarch64 running the image (the sandbox build of 3.4.4 hangs on `run`, a build artifact); real busybox:1.36 applets (`od`, `tar --exclude`, `sha256sum`); cgroup v2 CRI-O pods; apt Podman beside CRI-O on one storage (a 3.4.4 import next to a live CRI-O container was fine in the sandbox).
