# q49877639 — Running systemd in a Docker managed plugin (configuration)

Status: built and verified in the sandbox (x86_64, Docker 29.8.2, containerd 2.3.6, runc 1.5.1, systemd 255.4, cgroup v1/hybrid) as root, as non-root `bench` (sudo) and under a pty; the oracle passed three times on one setup, residue is clean. NOT yet run on the user's VM (aarch64, cgroup v2): see "VM-only".

## What the thread is really about

A managed plugin (a volume driver) should run systemd as its init, with a unit that starts the driver. With the asker's config.json (entrypoint systemd, `/sys/fs/cgroup` bind-mounted read-only, socket in `/run/docker/plugins`) `docker plugin enable` fails with `dial unix /run/docker/plugins/<id>/sysd.sock: connect: no such file or directory`; the container has already exited. Two independent causes (answer of the thread):

1. systemd mounts a tmpfs on `/run`, hiding `/run/docker/plugins`, the directory where the socket must appear. Fix: bind it to another path (`/dockerplugins`) before systemd starts, create the socket there.
2. Docker adds its own `/sys/fs/cgroup` mount after the mounts of config.json, so no option of a mount at that destination gives systemd the cgroups it needs. Fix: mount the host's cgroups at `/hostcgroup` in config.json and `mount --rbind /hostcgroup /sys/fs/cgroup` in an init script that then execs systemd.

Both fixes need an init script, i.e. a shell, mount and mkdir in the rootfs.

## Design

- Private containerd + dockerd of the case (sockets `/run/bench49877639/{containerd,docker}.sock`, roots below `/var/lib/bench49877639`); the machine's Docker is not touched. Plugins run in the containerd namespace `plugins.moby`.
- `helpers/mkplugin.py` builds the plugin directory offline from the machine's own files: systemd (+ systemd-executor, systemctl, targets and slices), dash, mount, mkdir, their libraries (ldd, merged-/usr aware) and `plugin.c`, a static volume driver. Its `VolumeDriver.Get` answers with its pid, the name of PID 1 and its `INVOCATION_ID`. `config.json` and `plugin.service` are the asker's. Installed with `docker plugin create bench/sysd:1`.
- Modern adaptation: the question's Docker 18.03 and systemd are not pinned (offline); the systemd is the machine's, its version is recorded. CAP_SYS_RESOURCE is left out of the capabilities (not needed; some sandboxes cannot grant it).
- task.txt states the symptom, the error, the rules and the wanted result, not the causes (decision of the user).
- precondition.sh: lab as recorded; control 1: `plugin enable` fails with the question's error and leaves the plugin disabled; control 2: a repaired COPY of the plugin directory under another name (`bench/ctl:1`) enables and its driver reports PID 1 = systemd.
- Oracle (`helpers/verify.py`), phase A as left, phase B after `docker plugin disable` + `enable`: plugin enabled with a volume-driver interface; running task in the lab's containerd whose init is a `systemd` that is a file of the plugin's rootfs, PID 1 of its own PID namespace, PID/mount namespaces different from the host's, version equal to the recorded one; a volume made through the plugin answers with pid / pid1=systemd / invocation id; on the host that pid is a descendant of the task's init (never of the host's PID 1), in a cgroup of a service below the plugin's own cgroup, the MainPID of an active unit, and its environment carries the unit's invocation id; the task of phase B is a new process.

## Samples (8) and what each one proves

| sample | expected | where it fails / what it exercises |
|---|---|---|
| reference_solution | PASS | init script + `/hostcgroup` rbind mount + unit socket in `/dockerplugins`, plugin re-created and enabled |
| alt_valid_unit_mounts_the_kept_directory_back | PASS | init keeps the directory; the unit puts it back on `/run/docker/plugins` (ExecStartPre) |
| no_op_baseline | FAIL | plugin installed but not enabled |
| wrong_cgroup_fix_only_socket_stays_in_run | FAIL | enable fails: the socket is hidden by /run's tmpfs |
| wrong_question_attempt_rw_cgroup_mount_in_config | FAIL | the asker's kind of try: enable still fails |
| wrong_driver_as_entrypoint_no_systemd | FAIL | PID 1 is the driver, not systemd |
| cheating_fake_systemd_the_driver_copied_over_systemd | FAIL | PID 1 is named systemd but the driver has no INVOCATION_ID (no unit) |
| wrong_directory_fixed_plugin_not_reinstalled | FAIL | the directory is repaired, the installed plugin is the old copy |

Not in the fixture on purpose: "init + /run fix but the asker's read-only cgroup mount" and "read-only /hostcgroup". On a cgroup v1/hybrid host they PASS (runc keeps the container's own cgroup writable), on cgroup v2 they should FAIL; the result depends on the host, so no fixed expectation. (Emulation in the sandbox: bind `/sys/fs/cgroup/unified` as the host mount: ro fails, rw rbind works.)

## Findings worth keeping

1. `/run/docker/plugins` is a global host path (not under `--exec-root`); plugin cgroups are named by the 64-hex plugin id at the cgroup root; cleanup records the ids before deleting the data root.
2. systemd 255 needs `systemd-executor` in the rootfs; without it PID 1 dies ("Failed to allocate manager object") with the very same enable error.
3. The driver must ignore SIGPIPE (a dying driver is restarted by `Restart=on-failure`; the pid the oracle read goes stale).
4. `ctr tasks exec` into a plugin task whose init is systemd made the task die and restart in a loop (exit 137 every 0.6 s, dockerd restarts it). The oracle uses `nsenter -t <init> -m -p -u -i -C -r -w`.
5. `docker plugin create` copies the directory; a `rootfs` symlink is not followed.
6. Without a terminal systemd's messages are invisible (no /dev/console); use `script -qec` or strace to see them.

## VM-only (not verifiable in the sandbox)

- cgroup v2: the reference solution (rw rbind of the host's cgroup tree, systemd non-cgroupns) is expected to pass; the sandbox only emulated it. Control 2 of precondition.sh checks exactly this on the VM before any sample runs.
- AppArmor/seccomp of the VM's Docker for `mount` inside a plugin; `--exec-opt native.cgroupdriver=cgroupfs` on a v2 host.
- aarch64: the rootfs is made from the machine's own files; the libraries and loader are found with ldd.
