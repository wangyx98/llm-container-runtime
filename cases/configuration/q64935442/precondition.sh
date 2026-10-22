#!/bin/bash
set -e

CASE_ID="bench64935442"
LIB_BASE="/var/lib/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REPO="benchlab64935/blaw-service"
TAG="v0.3.10"
NODE="bench64935442-node"
CTRL_NS="bench-control"

fail() { echo "  -> FAIL: $*"; exit 1; }
KC() { sudo "$CTL_DIR/kubectl" "$@"; }
pod_waiting() { KC get pods -n "$1" "${@:2}" -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true; }
pod_running() { KC get pods -n "$1" "${@:2}" -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || true; }
crict() { sudo "$LIB_BASE/libexec/k3s" crictl -r "unix://$RUN_BASE/containerd.sock" -i "unix://$RUN_BASE/containerd.sock" --timeout 60s "$@"; }
hub_lines() { sudo wc -l < "$RUN_BASE/hub.log"; }
# what the hub logged since line $1, one line per request: kind(token|registry) method status who auth path
hub_since() { sudo tail -n +"$(($1 + 1))" "$RUN_BASE/hub.log" | python3 -c '
import json
import sys

for ln in sys.stdin:
    r = json.loads(ln)
    print(r["srv"], r["method"], r["status"], r["who"], r["auth"], r["path"])'; }

echo "[precondition] the lab is as its record says: programs, configuration and account unchanged, the hub the process setup started, containerd and k3s running, the node Ready..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a program, a configuration file or the account of the lab was changed"
HUB_PID=$(sudo cat "$STATE_DIR/hub.pid")
[ "$(sudo awk '{print $22}' "/proc/$HUB_PID/stat" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/hub.start")" ] || fail "the hub is not the process setup started"
sudo "$CTL_DIR/containerdctl" status >/dev/null || fail "containerd is not running"
sudo "$CTL_DIR/k3sctl" status >/dev/null || fail "k3s is not running"
[ "$(KC get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] || fail "the node $NODE is not Ready"
echo "  -> OK"

echo "[precondition] the engineer's work: the Secret regcred is there (type kubernetes.io/dockerconfigjson, for https://index.docker.io/v1/) and the Deployment blaw does not name any pull secret..."
[ "$(KC get secret regcred -n default -o jsonpath='{.type}' 2>/dev/null)" = "kubernetes.io/dockerconfigjson" ] || fail "the Secret regcred is missing or of another type"
KC get secret regcred -n default -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c '
import json, sys
a = json.load(sys.stdin)["auths"]["https://index.docker.io/v1/"]
sys.exit(0 if a.get("username") == "hubuser" and a.get("password") and a.get("auth") else 1)' || fail "the Secret regcred does not hold the account for https://index.docker.io/v1/"
[ "$(KC get deployment blaw -n default -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" = "$REPO:$TAG" ] || fail "the Deployment blaw is missing or has another image"
[ -z "$(KC get deployment blaw -n default -o jsonpath='{.spec.template.spec.imagePullSecrets}' 2>/dev/null)" ] || fail "the Deployment already names a pull secret"
[ -z "$(KC get serviceaccount default -n default -o jsonpath='{.imagePullSecrets}' 2>/dev/null)" ] || fail "the default service account already names a pull secret"
echo "  -> OK"

echo "[precondition] the problem: the Pod of blaw cannot pull its image, it is refused as an anonymous reader..."
W=$(pod_waiting default -l app=blaw)
case "$W" in ErrImagePull|ImagePullBackOff) ;; *) fail "the Pod of blaw is not failing to pull (state: ${W:-none})" ;; esac
KC get events -n default --field-selector reason=Failed -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -q "insufficient_scope: authorization failed" || fail "no event of the Pod shows the insufficient_scope pull error"
! hub_since 0 | grep -q " hubuser " || fail "the account was used already"
hub_since 0 | grep -q "^registry HEAD 401 anonymous " || fail "the hub did not refuse the anonymous request for the manifest"
echo "  -> OK: $W"

echo "[precondition] control: the same image runs in a throw-away namespace when the Pod names the Secret (the account is valid, the lab can be solved)..."
# blaw is stopped meanwhile: an image in the node's store would let its Pod start without any secret
KC scale deployment blaw -n default --replicas=0 >/dev/null
for _ in $(seq 30); do [ -z "$(KC get pods -n default -l app=blaw -o name 2>/dev/null)" ] && break; sleep 1; done
PW=$(sudo python3 -c 'import json; print(json.load(open("'"$LIB_BASE"'/account.json"))["password"])')
KC create namespace "$CTRL_NS" >/dev/null
for _ in $(seq 30); do KC get serviceaccount default -n "$CTRL_NS" >/dev/null 2>&1 && break; sleep 1; done
KC create secret docker-registry regcred -n "$CTRL_NS" --docker-server=https://index.docker.io/v1/ --docker-username=hubuser --docker-password="$PW" >/dev/null
cat <<YEOF | KC apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: control
  namespace: $CTRL_NS
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - name: transcribe-service
    image: $REPO:$TAG
YEOF
N0=$(hub_lines)
R=""
for _ in $(seq 60); do R=$(pod_running "$CTRL_NS"); [ -n "$R" ] && break; sleep 2; done
cleanup_control() {
    KC delete namespace "$CTRL_NS" --wait=true --timeout=90s >/dev/null 2>&1 || true
    for id in $(crict images -q 2>/dev/null); do
        crict inspecti "$id" 2>/dev/null | grep -q "$REPO" && crict rmi "$id" >/dev/null 2>&1
    done
    KC scale deployment blaw -n default --replicas=1 >/dev/null
}
[ -n "$R" ] || { cleanup_control; fail "the Pod that names the Secret did not start"; }
hub_since "$N0" | grep -q "^token GET 200 hubuser basic " || { cleanup_control; fail "the token service did not see the account"; }
hub_since "$N0" | grep -q "^registry GET 200 hubuser bearer .*blobs" || { cleanup_control; fail "the hub did not serve the blobs to the account"; }
[ "$(KC logs control -n "$CTRL_NS" 2>/dev/null | head -1)" = "SALT initial" ] || { cleanup_control; fail "the container of the control Pod does not print the salt of the image"; }
cleanup_control
for _ in $(seq 90); do W=$(pod_waiting default -l app=blaw); case "$W" in ErrImagePull|ImagePullBackOff) break ;; esac; sleep 2; done
case "$W" in ErrImagePull|ImagePullBackOff) ;; *) fail "after the control the Pod of blaw is not failing to pull again (state: ${W:-none})" ;; esac
echo "  -> OK"

echo "[precondition] PASS - the Pod of blaw is refused as an anonymous reader; the same image runs when the Pod names the Secret regcred."
