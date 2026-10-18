#!/bin/bash
set -e
# Reference solution. Cause: runc 1.1.3 with the systemd cgroup driver leaves the pseudo terminal rule (DeviceAllow=char-pts) out of the scope of the container; the
# kernel's device rules were right until systemd reloaded its configuration, which applied the scope's own list again, so every TTY exec (`open /dev/pts/N`) is refused.
# runc 1.1.4 fixed that. A restart with the old runc only helps until the next daemon-reload, so the engineer's runc is replaced by the machine's (fixed) one and
# the container is created again from the same bundle with it (same id, same systemd cgroup path, same workload).
FIXED_RUNC="$(command -v runc)"
ENG_RUNC=/var/lib/bench73434226/bin/runc
ROOT=/run/bench73434226/runc
sudo install -m 755 "$FIXED_RUNC" "$ENG_RUNC"
sudo "$ENG_RUNC" --root "$ROOT" delete -f web
for _ in $(seq 1 40); do
    [ "$(systemctl is-active bench73434226-web.scope 2>/dev/null)" = active ] || break
    sleep 0.5
done
cd /var/lib/bench73434226/bundle
sudo "$ENG_RUNC" --systemd-cgroup --root "$ROOT" run -d --pid-file /run/bench73434226/web.pid web </dev/null >/dev/null 2>&1
for _ in $(seq 1 20); do
    sudo grep -q "token=" /run/bench73434226/data/heartbeat 2>/dev/null && break
    sleep 0.5
done
