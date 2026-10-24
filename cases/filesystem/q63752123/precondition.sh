#!/bin/bash
# Precondition: two containers run with runc's default read-only /proc/sys; a process that joins the MOUNT namespace of one gets "Read-only file system" when it writes ns_last_pid
# (the asker's symptom); the container's PID namespace is not the host's. Reads only, except for the value the probe tries to write (it never lands: the write fails).
CASE_ID="bench63752123"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
now=$(sudo sh -c "( find '$LIB/runc' '$LIB/bin' '$LIB/etc' '$LIB/rootfs' -type f -exec sha256sum {} + ; find '$LIB/rootfs' -type l -printf '%p -> %l\n' ) | sort | sha256sum")
[ "$now" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the host side changed since setup"
"$LIB/runc" --version | grep -q 'runc version 1.1.12' || fail "runc is not 1.1.12"
[ ! -e "$LIB/nsfork" ] || fail "$LIB/nsfork exists before the solution"
hostns=$(readlink /proc/self/ns/pid)
for f in target other; do
    id=$(cat "$LIB/etc/$f.id")
    pid=$(sudo "$LIB/runc" --root "$RUN/runc" state "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])') || fail "$id does not run"
    [ "$(sudo readlink "/proc/$pid/ns/pid")" != "$hostns" ] || fail "$id shares the host's PID namespace"
    sudo grep -E ' /proc/sys ro[, ]' "/proc/$pid/mountinfo" >/dev/null || fail "/proc/sys is not read-only in $id"
done
id=$(cat "$LIB/etc/target.id")
pid=$(sudo "$LIB/runc" --root "$RUN/runc" state "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')
msg=$(sudo nsenter -t "$pid" -m -p -- /bin/wr /proc/sys/kernel/ns_last_pid 5000 2>&1)
echo "$msg" | grep -q 'Read-only file system' || fail "joining the mount namespace does not give 'Read-only file system': $msg"
echo "[precondition] PASS: /proc/sys is read-only in both containers; a process that joined the mount namespace gets: $msg"
