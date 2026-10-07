#!/bin/bash
set -e

CASE_ID="bench71572715"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_NS="default"
WORKLOAD="bench71572715-workload"
NODE="bench71572715-node"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
HB="$WORK_DIR/hb/heartbeat"

CTR="sudo ctr -a $CTD_SOCK"
K3S_BIN=$(cat "$STATE_DIR/k3s.bin" 2>/dev/null || true)
kube() { sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB_BASE/k3s" "$K3S_BIN" kubectl "$@"; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the pre-installed containerd runs, is the one setup started and answers..."
for f in containerd.id workload.id k3s.id k3s.bin embedded.version external.version token heartbeat.0; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
[ -x "$K3S_BIN" ] || fail "the k3s binary $K3S_BIN is missing"
$CTR version >/dev/null 2>&1 || fail "the external containerd does not answer on $CTD_SOCK"
alive_same containerd || fail "the recorded containerd is not running"
echo "  -> OK (containerd $(cat "$STATE_DIR/external.version"))"

echo "[precondition] checking the independent workload runs in that containerd and keeps writing its heartbeat..."
read -r WPID WSTART < "$STATE_DIR/workload.id"
LINE=$($CTR -n "$CTD_NS" tasks ls 2>/dev/null | awk -v n="$WORKLOAD" '$1==n')
echo "$LINE" | awk '{exit !($3=="RUNNING" && $2=="'"$WPID"'")}' || fail "the task of $WORKLOAD is not RUNNING with pid $WPID: '$LINE'"
[ "$(sudo awk '{print $22}' /proc/$WPID/stat 2>/dev/null)" = "$WSTART" ] || fail "pid $WPID is not the process setup recorded"
H1=$(awk '{print $2}' "$HB"); sleep 2; H2=$(awk '{print $2}' "$HB")
[ "$H2" -gt "$H1" ] 2>/dev/null || fail "the heartbeat of the workload does not advance ($H1 -> $H2)"
[ "$(awk '{print $1}' "$HB")" = "$(sudo cat "$STATE_DIR/token")" ] || fail "the heartbeat does not carry the token of the machine"
echo "  -> OK"

echo "[precondition] checking k3s runs, is the one setup started, and uses its OWN containerd: a containerd"
echo "[precondition] child of k3s, and a node whose runtime is not the pre-installed containerd..."
alive_same k3s || fail "the recorded k3s is not running"
read -r KPID _ < "$STATE_DIR/k3s.id"
[ "$(pgrep -x k3s-server | wc -l)" = "1" ] || fail "there is not exactly one k3s process"
pgrep -P "$KPID" -x containerd >/dev/null || fail "k3s has no containerd of its own as a child process"
READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
RT=$(kube get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
[ "$RT" = "$(cat "$STATE_DIR/embedded.version")" ] || fail "the runtime of the node changed: $RT"
[ "$RT" != "containerd://$(cat "$STATE_DIR/external.version")" ] || fail "the node already uses the version of the external containerd: $RT"
echo "  -> OK (node runtime $RT, the pre-installed one is containerd://$(cat "$STATE_DIR/external.version"))"

echo "[precondition] checking k3s is not told to use an external runtime, and the control scripts exist..."
! grep -q 'container-runtime-endpoint' /etc/rancher/k3s/config.yaml || fail "the k3s configuration already names a container runtime endpoint"
for s in k3sctl containerdctl; do [ -x "$CTL_DIR/$s" ] || fail "$CTL_DIR/$s is missing"; done
echo "  -> OK"

echo "[precondition] all conditions met."
