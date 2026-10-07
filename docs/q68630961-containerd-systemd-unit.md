# q68630961 — "Failed to restart containerd.service: Unit not found" (Runtime Compatibility)

Status: built, verified in the sandbox on a real systemd, and verified on the test VM (all 10 samples behave as designed; the residual check is clean apart from one empty systemd directory, see below).

## What the Stack Overflow thread is about

containerd 1.5.4 was installed on CentOS 7 from the release tarball (`tar -C / -xzf ...`, then `containerd config default > /etc/containerd/config.toml`). `systemctl start containerd` answers "Unit not found": the tarball holds binaries only, no systemd unit. The (closed) question's answer points at the distro package `containerd.io`, which ships the unit, and warns that `tar -C /` overwrote `/bin` on its CentOS 7. The manual route is to write containerd's own `containerd.service`, `daemon-reload`, `enable --now`.

## Why this case is special

It is the only case so far whose subject is the init system, not the runtime's API: the solution is a systemd unit, and "works" has to include "still works after a reboot". It also needs a systemd-booted machine; a plain container or a sandbox without systemd cannot run it.

## Design

Nothing of the host is replaced, and the unit name is private (`bench68630961-containerd.service`), so the host's `containerd.service` is never involved.

- `setup.sh` builds the "release tarball" from the host's containerd, ctr and containerd-shim-runc-v2 (`bin/` only, like the official one), unpacks it as root into `/opt/bench68630961`, writes `containerd config default` there (private root `/var/lib/bench68630961/containerd`, state and socket under `/run/bench68630961`, NRI off), and preloads an offline-built image (static `/show` printing a random token) into the root by running the tarball's containerd once by hand and stopping it again; the runtime dir is then removed, as a reboot would. It records the host's containerd/docker unit state and the host's containerd binary hash, and the setup time (for the journal excerpt).
- `precondition.sh`: systemd is the init; tarball and config untouched and without any unit; `systemctl start` fails with "not found" (`LoadState=not-found`); no containerd of the case runs and `/run/bench68630961` does not exist; the image blobs and name are in the root; host state as recorded.
- Task: make the tarball's containerd run as that service, enabled, surviving a restart and a reboot, answering on the socket and running the preloaded image; no hand-started daemon, host containerd/docker untouched, no downloads.
- `oracle.sh`, 7 checks:
  1. a real, non-transient unit file in a persistent place (not /run, /tmp);
  2. active and running;
  3. every process running the tarball's containerd binary exists and sits in the unit's cgroup (fails a hand-started daemon next to a fake unit, and the host's own binary);
  4. the RPC answers, the preloaded image is listed (so the root is the original one) and prints its token;
  5. boot persistence: `UnitFileState=enabled` (not enabled-runtime), `default.target` pulls the unit in, ExecStart is not in a volatile directory;
  6. cold start: stop, remove `/run/bench68630961`, daemon-reload, start; a new MainPID; checks 3 and 4 again;
  7. the host's containerd/docker units and the host's containerd binary are unchanged.

## Samples (10)

| sample | expected | why |
|---|---|---|
| reference_solution | PASS | unit in /etc/systemd/system, daemon-reload, enable --now |
| alt_valid_wrapper_script_simple_type | PASS | wrapper script as ExecStart, Type=simple, unit in /usr/local/lib/systemd/system, no waiting |
| no_op_baseline | FAIL | Unit not found |
| naive_unit_file_only | FAIL | known to systemd, but inactive |
| naive_start_without_enable | FAIL | active, but `UnitFileState=disabled` |
| naive_execstart_upstream_path | FAIL | the upstream unit's /usr/local/bin path: 203/EXEC, auto-restart |
| naive_hardened_unit_needs_run_dir | FAIL | works the first time, fails the cold start with 226/NAMESPACE (ProtectSystem plus ReadWritePaths on a dir that only exists because the script created it) |
| cheat_use_system_binary | FAIL | no process runs the tarball's binary |
| cheat_transient_systemd_run | FAIL | transient unit |
| cheat_fake_unit_plus_manual_daemon | FAIL | the daemon is not in the unit's cgroup (it sits in the caller's session scope) |

## Findings worth reusing

- A real reboot cannot be done by an oracle; checks 5 and 6 are proxies. They were validated against a genuine reboot in the sandbox rig: after killing and rebooting the rig, the reference solution comes up active and runs the image; start-without-enable stays inactive; the hardened unit fails with 226. The proxies predict all three correctly.
- containerd 2.x looks for `containerd-shim-runc-v2` next to its own binary (verified with a PATH that lacks the system shim), so a tarball layout needs no PATH setting; `runc` must be in PATH (it is in the default PATH of systemd units).
- `Type=simple` does not wait for readiness, so the oracle gives the socket up to 20 s before counting it as not answering.
- Journal lines of earlier runs of the same unit name survive between samples; the oracle shows only lines since this run's setup (`journalctl --since @epoch`).
- **The harness reports only the last 500 characters of the oracle's stdout.** On the VM the journal excerpt was longer than in the sandbox and pushed the "-> FAIL:" prefix of one sample out of the window. The excerpt is now capped at 220 characters, so the whole failure line (at most about 400 characters) is always reported. Rule for every oracle: keep the failure line itself short, and put variable-length diagnostics last and capped.
- A unit that gets its own mount namespace (ProtectSystem=, ReadWritePaths=) leaves an empty directory `/run/systemd/propagate/<unit>` on systemd 249 (the VM) even after the unit is gone; systemd 255 (the sandbox) removes it. It is empty, lives in tmpfs and is not a mount; cleanup.sh now removes it with `rmdir` (which only removes an empty directory).
- Not covered on purpose: CNI plugins (the oracle runs the container with host networking), `OOMScoreAdjust` (needs CAP_SYS_RESOURCE; the sandbox lacks it, a real VM has it, so the reference leaves it out).
- Risk for real LLM runs: a unit whose ExecStart has no `--config` starts a second containerd on the host's default socket `/run/containerd/containerd.sock`. The task text names the config explicitly and forbids touching the host's services; none of the samples does this.

## Residual check (all empty after a run, except the last line)

```bash
ls -d /opt/bench68630961 /run/bench68630961 /var/lib/bench68630961 /tmp/bench68630961* 2>&1 | grep -v "No such"
sudo find /etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /run/systemd -name 'bench68630961*' 2>/dev/null
systemctl list-units --all --no-pager | grep bench68630961
ps -eo pid,stat,args | grep bench68630961 | grep -v grep
findmnt -rn | grep bench68630961
systemctl is-active containerd docker      # same as before the run
```

The alt sample may leave the empty directory `/usr/local/lib/systemd/system` (the sample creates it with `mkdir -p`); that is harmless.

## How it was tested without systemd in the sandbox

A real systemd (255) was booted as PID 1 in private pid/mount/uts namespaces, with a private `/run`, `/tmp`, `/var/tmp` and an overlay on `/etc/systemd/system`. WARNING for anyone repeating this: without a private `/tmp`, `systemd-tmpfiles --remove --boot` empties the real `/tmp` of the machine (it did, once). All samples were run as root and as a plain user with passwordless sudo, and the reference solution passed three runs in a row.
