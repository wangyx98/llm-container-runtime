#!/bin/bash
# Proves the initial state before the solution runs. Nothing here changes the workload or writes /data/done.
CASE_ID="bench79297389"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="k8s.io"
CT="$CASE_ID-app"
ND="sudo $WORK_DIR/node-debug"
RUNC_ROOT="/run/containerd/runc/$NS"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1"; }
UID_APP=$(st uid); GID_APP=$(st gid); PID=$(st pid)

echo "[precondition] the workload runs as ordinary user $UID_APP:$GID_APP, started once, no result yet..."
sudo ctr -n $NS tasks ls 2>/dev/null | awk -v n="$CT" -v p="$PID" '$1 == n && $2 == p && $3 == "RUNNING"' | grep -q . || fail "task $CT is not RUNNING as pid $PID"
[ "$(sudo awk '{print $22}' /proc/$PID/stat)" = "$(st starttime)" ] || fail "start time of pid $PID changed"
[ "$(sudo awk '/^Uid:/ {print $2":"$3":"$4":"$5}' /proc/$PID/status)" = "$UID_APP:$UID_APP:$UID_APP:$UID_APP" ] || fail "main process is not uid $UID_APP"
[ "$(sudo awk '/^Gid:/ {print $2}' /proc/$PID/status)" = "$GID_APP" ] || fail "main process is not gid $GID_APP"
[ ! -e "$WORK_DIR/data/done" ] || fail "/data/done exists already"
sudo sh -c "cd '$STATE_DIR' && sha256sum -c --quiet sums" || fail "wrapper, node ctr or debug spec differ from the recorded hashes"

echo "[precondition] the node debug container: host PID namespace, no SYS_ADMIN, no SYS_PTRACE, cannot mount..."
CAPEFF=$($ND grep '^CapEff' /proc/self/status 2>/dev/null | awk '{print $2}')
[ -n "$CAPEFF" ] || fail "the debug container does not start"
[ "$CAPEFF" = "$(st debug_capeff)" ] || fail "CapEff $CAPEFF differs from the recorded one"
python3 -c "import sys; v=int(sys.argv[1],16); sys.exit(0 if not (v>>21 & 1 or v>>19 & 1) else 1)" "$CAPEFF" || fail "the debug container has SYS_ADMIN or SYS_PTRACE (CapEff $CAPEFF)"
[ "$($ND readlink /proc/self/ns/pid 2>/dev/null)" = "$(readlink /proc/self/ns/pid)" ] || fail "the debug container is not in the host PID namespace"
$ND mount -t tmpfs none /mnt >/dev/null 2>&1 && fail "mount works inside the debug container"
$ND sh -c 'test -S /run/containerd/containerd.sock' || fail "the node's containerd socket is not visible after chroot /host"

echo "[precondition] from the debug container, as in the question: the user given by uid alone or by name..."
OUT=$($ND ctr -n $NS task exec --exec-id pre-uid-$$ --user 0 $CT /usr/bin/id 2>&1); RC=$?
[ $RC -ne 0 ] || fail "ctr --user 0 works in the debug container: $OUT"
echo "$OUT" | grep -q 'failed to mount' || fail "ctr --user 0 failed, but not with the mount error: $OUT"
OUT=$($ND ctr -n $NS task exec --exec-id pre-name-$$ --user root $CT /usr/bin/id 2>&1); RC=$?
[ $RC -ne 0 ] || fail "ctr --user root works in the debug container: $OUT"

echo "[precondition] ...runc exec cannot enter the workload's namespaces from there..."
OUT=$($ND runc --root $RUNC_ROOT exec --user 0:0 $CT /usr/bin/id 2>&1); RC=$?
[ $RC -ne 0 ] || fail "runc exec works in the debug container: $OUT"
echo "$OUT" | grep -q 'ns/' || fail "runc exec failed, but not on a namespace file: $OUT"

echo "[precondition] ...the same commands work from the node's own root shell (so the tools and the container are fine)..."
OUT=$(sudo ctr -n $NS task exec --exec-id pre-host-$$ --user 0 $CT /usr/bin/id 2>&1) || fail "host ctr --user 0 does not work: $OUT"
echo "$OUT" | grep -q '^uid=0 gid=0 ' || fail "host ctr --user 0 did not run as 0:0: $OUT"
OUT=$(sudo runc --root $RUNC_ROOT exec --user 0:0 $CT /usr/bin/id 2>&1) || fail "host runc exec does not work: $OUT"
echo "$OUT" | grep -q '^uid=0 gid=0 ' || fail "host runc exec did not run as 0:0: $OUT"

echo "[precondition] uid and gid are separate: root uid with the workload's gid is refused by the program..."
OUT=$($ND ctr -n $NS task exec --exec-id pre-gid-$$ --user 0:$GID_APP $CT /usr/bin/maintain 2>&1); RC=$?
[ $RC -ne 0 ] || fail "maintain ran as 0:$GID_APP"
echo "$OUT" | grep -q 'refusing to run' || fail "maintain did not refuse: $OUT"
OUT=$($ND ctr -n $NS task exec --exec-id pre-0-$$ --user 0:0 $CT /usr/bin/id 2>&1) || fail "ctr --user 0:0 does not work in the debug container: $OUT"
echo "$OUT" | grep -q '^uid=0 gid=0 ' || fail "ctr --user 0:0 did not give 0:0: $OUT"

[ ! -e "$WORK_DIR/data/done" ] || fail "/data/done appeared during the precondition"
[ "$(sudo awk '{print $22}' /proc/$PID/stat)" = "$(st starttime)" ] || fail "the workload was restarted"
sudo sh -c ": > '$STATE_DIR/debug.log'"
echo "[precondition] OK: non-root workload, a debug container without SYS_ADMIN/SYS_PTRACE; ctr --user 0 and runc exec fail there, ctr --user 0:0 works."
exit 0
