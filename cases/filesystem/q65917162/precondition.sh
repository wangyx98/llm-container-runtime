#!/bin/bash
# Precondition: the question's bad case: in the running container made from the bad bundle (every capability, no seccomp, no AppArmor) the child user + mount + PID namespaces of
# `probe` cannot mount proc (EPERM, the old /proc shows the container's processes); the same without a user namespace works (not a missing CAP_SYS_ADMIN); and a throwaway container
# with maskedPaths and readonlyPaths both empty lets the probe mount proc (the host allows the good case at all).
CASE_ID="bench65917162"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
RC="$LIB/runc --root $RUN/runc"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
now=$(sudo sh -c "( find '$LIB/runc' '$LIB/bin' '$LIB/etc' '$LIB/rootfs' '$LIB/bundles/bad' -type f -exec sha256sum {} + ) | sort | sha256sum")
[ "$now" = "$(sudo cat "$STATE_DIR/lab.sha")" ] || fail "a file of the host side changed since setup"
"$LIB/runc" --version | grep -q 'runc version 1.1.12' || fail "runc is not 1.1.12"
[ ! -e "$LIB/mkct" ] || fail "$LIB/mkct exists before the solution"
bad=$(cat "$LIB/etc/bad.id")
sudo $RC state "$bad" | grep -q '"status": "running"' || fail "$bad does not run"
hostuserns=$(sudo readlink /proc/self/ns/user)
bpid=$(sudo $RC state "$bad" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')
[ "$(sudo readlink "/proc/$bpid/ns/user")" = "$hostuserns" ] || fail "the container has a user namespace of its own"
pj() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['$1'])" "$2"; }
out=$(sudo $RC exec "$bad" /bin/probe) || fail "probe does not run in $bad"
[ "$(pj mount_rc "$out")" = -1 ] && [ "$(pj errno "$out")" = "Operation not permitted" ] || fail "the child user namespace can mount proc in the bad container: $out"
[ "$(pj self_pid "$out")" != 1 ] && [ "$(pj submounts_before "$out")" -gt 0 ] || fail "unexpected probe result in the bad container: $out"
plain=$(sudo $RC exec "$bad" /bin/probe plain)
[ "$(pj mount_rc "$plain")" = 0 ] && [ "$(pj self_pid "$plain")" = 1 ] || fail "even without a user namespace proc cannot be mounted in the bad container: $plain"
t="pre$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sudo "$LIB/bin/newct" "$t" --unconfined >/dev/null || fail "the throwaway container did not start"
good=$(sudo $RC exec "$t" /bin/probe)
sudo $RC delete -f "$t" >/dev/null 2>&1; sudo rm -rf "$LIB/bundles/$t"
[ "$(pj mount_rc "$good")" = 0 ] && [ "$(pj self_pid "$good")" = 1 ] || fail "with both path lists empty the probe cannot mount proc either (this host does not allow the good case): $good"
echo "[precondition] PASS: bad container: $out | without userns: $plain | both lists empty: $good"
