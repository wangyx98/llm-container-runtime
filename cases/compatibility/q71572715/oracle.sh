#!/bin/bash
# Postcondition oracle. Every check is dynamic: processes, RPC answers, the node's reported runtime and
# a new container are observed on the running machine; no file is only read and believed.
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
ROOTFS="$STATE_DIR/rootfs"
HB="$WORK_DIR/hb/heartbeat"

CTR="sudo ctr -a $CTD_SOCK"
K3S_BIN=$(cat "$STATE_DIR/k3s.bin" 2>/dev/null || true)
kube() { sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB_BASE/k3s" "$K3S_BIN" kubectl "$@"; }
same_proc() {   # $1 = recorded process (state file $1.id: pid + start time) is still that process, not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }

EXT_VER=$(cat "$STATE_DIR/external.version")
EMB_VER=$(cat "$STATE_DIR/embedded.version")

check_external() {   # the pre-installed containerd and its workload: the same processes, answering, alive
    local when="$1" LINE WPID WSTART H1 H2
    same_proc containerd || fail "$when: the pre-installed containerd is not the process that was running before"
    $CTR version >/dev/null 2>&1 || fail "$when: the pre-installed containerd does not answer on $CTD_SOCK"
    read -r WPID WSTART < "$STATE_DIR/workload.id"
    LINE=$($CTR -n "$CTD_NS" tasks ls 2>/dev/null | awk -v n="$WORKLOAD" '$1==n')
    echo "$LINE" | awk '{exit !($3=="RUNNING" && $2=="'"$WPID"'")}' \
        || fail "$when: $WORKLOAD is not RUNNING with its original pid ($LINE)"
    [ "$(sudo awk '{print $22}' /proc/$WPID/stat 2>/dev/null)" = "$WSTART" ] \
        || fail "$when: the process of $WORKLOAD is not the original one"
    H1=$(awk '{print $2}' "$HB" 2>/dev/null); sleep 2; H2=$(awk '{print $2}' "$HB" 2>/dev/null)
    [ "$H2" -gt "$H1" ] 2>/dev/null || fail "$when: the heartbeat of $WORKLOAD does not advance ($H1 -> $H2)"
    [ "$(awk '{print $1}' "$HB")" = "$(sudo cat "$STATE_DIR/token")" ] \
        || fail "$when: the heartbeat does not carry the token"
}

echo "[oracle] check 1: the pre-installed containerd and its workload were not disturbed..."
check_external "before stopping k3s"
echo "  -> OK"

echo "[oracle] check 2: k3s runs again (not the process of before) and the node reports the runtime"
echo "[oracle] containerd://$EXT_VER of the pre-installed containerd..."
[ "$(pgrep -x k3s-server | wc -l)" = "1" ] || fail "there is not exactly one k3s-server process ($(pgrep -x k3s-server | wc -l))"
if same_proc k3s; then
    fail "k3s was not restarted: it still runs the old process, with its own embedded containerd"
fi
KPID=$(pgrep -x k3s-server)
READY=""; RT=""
for _ in $(seq 1 120); do
    sudo kill -0 "$KPID" 2>/dev/null || fail "k3s is not running: it exited (e.g. it cannot use the runtime endpoint it was given)"
    READY=$(kube get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    RT=$(kube get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)
    [ "$READY" = "True" ] && [ "$RT" = "containerd://$EXT_VER" ] && break
    sleep 1
done
if [ "$READY" != "True" ] || [ "$RT" != "containerd://$EXT_VER" ]; then
    if [ -z "$RT" ]; then fail "k3s answers no node after 120s: its API is down or the node never registered"
    elif [ "$RT" = "$EMB_VER" ]; then fail "the node still reports the embedded runtime $RT, not containerd://$EXT_VER"
    elif [ "$READY" != "True" ]; then fail "the node reports runtime $RT but is not Ready (Ready=$READY)"
    else fail "the node reports an unexpected runtime: $RT (expected containerd://$EXT_VER)"; fi
fi
if pgrep -P "$KPID" -x containerd >/dev/null; then fail "k3s still starts a containerd of its own (child of k3s-server)"; fi
echo "  -> OK (node Ready, runtime $RT, no containerd child of k3s)"

echo "[oracle] check 3: the API of k3s is up (it is the k3s that uses that runtime)..."
kube get --raw /readyz >/dev/null 2>&1 || fail "the API of k3s does not report ready"
echo "  -> OK"

echo "[oracle] check 4: decoupling. Stopping k3s must leave the runtime, its RPC and the workload running..."
sudo "$CTL_DIR/k3sctl" stop >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -x k3s-server >/dev/null || break; sleep 1; done
pgrep -x k3s-server >/dev/null && fail "k3s did not stop"
sleep 1
check_external "after stopping k3s"
TOK=$(sudo cat "$STATE_DIR/token")
OUT=$(timeout -k 5 60 $CTR -n "$CTD_NS" run --rm --rootfs \
    --mount "type=bind,src=/usr,dst=/usr,options=rbind:ro" \
    "$ROOTFS" "bench71572715-oracle-$$" /bin/sh -c 'cat /unique.txt' </dev/null 2>/dev/null || true)
[ "$(echo "$OUT" | tail -1)" = "$TOK" ] || fail "after stopping k3s the containerd cannot run a new container (got: '$OUT')"
echo "  -> OK (same containerd process, RPC answers, workload alive, a new container runs)"

echo "[oracle] all checks passed."
