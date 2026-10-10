#!/bin/bash
set -e

CASE_ID="bench73941545"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
D_SOCK="$RUN_BASE/containerd/containerd.sock"
K_SOCK="$RUN_BASE/k3s/containerd/containerd.sock"
D_CFG="$LIB_BASE/etc/containerd/config.toml"
K_CFG="$LIB_BASE/k3s/agent/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"
APP_REF="$CASE_ID.local/app:1"

CTR_D="sudo ctr -a $D_SOCK"
CTR_K="sudo ctr -a $K_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$K_SOCK" --image-endpoint "unix://$K_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the workload printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line
snapshot() {   # $1 = socket: what the daemon holds, in every namespace (namespaces, images, containers)
    local ns
    sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort | sed 's/^/ns /'
    for ns in $(sudo ctr -a "$1" namespaces ls -q 2>/dev/null | sort); do
        sudo ctr -a "$1" -n "$ns" images ls -q 2>/dev/null | sort | sed "s/^/image $ns /"
        sudo ctr -a "$1" -n "$ns" containers ls -q 2>/dev/null | sort | sed "s/^/container $ns /"
    done
}

echo "[precondition] checking the two containerd daemons (the processes of setup), each with its own socket, and the CRI of K3s's..."
for f in d.id k.id pod_id container_app pid starttime marker app.digest d.snapshot k.snapshot beat0 config.sha image_app.json; do
    sudo test -e "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same d || fail "the recorded node containerd is not running"
alive_same k || fail "the recorded K3s containerd is not running"
[ "$D_SOCK" != "$K_SOCK" ] || fail "both daemons have the same socket"
$CTR_D version >/dev/null 2>&1 || fail "the node's containerd does not answer on $D_SOCK"
$CTR_K version >/dev/null 2>&1 || fail "the K3s containerd does not answer on $K_SOCK"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the K3s containerd does not answer"
PK=$(awk '{print $1}' "$STATE_DIR/k.id")
KCMD=$(sudo tr '\0' ' ' < "/proc/$PK/cmdline")
case "$KCMD" in *" -a $K_SOCK "*"--state "*"--root "*) ;; *) fail "the K3s containerd is not started as 'containerd -c .. -a SOCKET --state DIR --root DIR': $KCMD" ;; esac
echo "  -> OK (node containerd pid $(awk '{print $1}' "$STATE_DIR/d.id"), K3s containerd pid $PK)"

echo "[precondition] checking the symptom of the thread: the node's own containerd holds nothing (no image, no container, in any namespace),"
echo "[precondition] while the K3s containerd, whose namespaces are separate, has nothing in its 'default' namespace either..."
[ "$(snapshot "$D_SOCK")" = "$(st d.snapshot)" ] || fail "the node's containerd changed since setup"
[ ! -s "$STATE_DIR/d.snapshot" ] || fail "the node's containerd is not empty"
[ "$($CTR_D images ls -q 2>/dev/null | wc -l)" = 0 ] || fail "ctr images ls on the node's containerd lists images"
[ "$($CTR_D -n k8s.io images ls -q 2>/dev/null | wc -l)" = 0 ] || fail "k8s.io of the node's containerd lists images"
[ "$($CTR_K images ls -q 2>/dev/null | wc -l)" = 0 ] || fail "the 'default' namespace of the K3s containerd lists images"
echo "     ctr -a <node containerd> images ls:           $($CTR_D images ls 2>/dev/null | wc -l) line(s) (header only)"
echo "     ctr -a <K3s containerd> images ls (default):  $($CTR_K images ls 2>/dev/null | wc -l) line(s) (header only)"
echo "  -> OK"

echo "[precondition] checking what is in K3s's containerd, namespace k8s.io: the image $APP_REF with the digest of the image built at setup,"
echo "[precondition] and the pod's container, running (host pid and start time as recorded), its heartbeat counting, its marker the recorded one..."
[ "$(snapshot "$K_SOCK")" = "$(st k.snapshot)" ] || fail "the K3s containerd changed since setup"
REAL=$($CTR_K -n k8s.io images ls 2>/dev/null | awk -v r="$APP_REF" '$1==r{print $3}')
[ "$REAL" = "$(st app.digest)" ] || fail "containerd shows $REAL for $APP_REF, setup recorded $(st app.digest)"
APP_ID=$(st container_app); PID=$(st pid)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "the workload has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the workload process has another start time"
L1=$(lastlog); sleep 2; L2=$(lastlog)
[ "$(field beat "$L2")" -gt "$(field beat "$L1")" ] || fail "the heartbeat does not advance ($L1 / $L2)"
[ "$(field marker "$L2")" = "$(st marker)" ] || fail "the workload's marker is not the recorded one"
[ "$(field pid "$L2")" = "1" ] || fail "the workload is not pid 1 in its own pid namespace"
echo "  -> OK ($L2; $APP_REF = $REAL)"
