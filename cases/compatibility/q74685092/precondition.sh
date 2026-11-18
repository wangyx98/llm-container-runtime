#!/bin/bash
set -e

CASE_ID="bench74685092"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK_K="$RUN_BASE/k3s/containerd.sock"
SOCK_S="$RUN_BASE/system/containerd.sock"
SOCK_W="$RUN_BASE/worker/containerd.sock"
CRICTLBIN="$LIB_BASE/bin/crictl"
APP_TAG="$CASE_ID-app:latest"
APP_REF="docker.io/library/$APP_TAG"

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
# the id the CRI reports for the app image, from one daemon's own socket ("" when it is not listed)
cri_id() { sudo "$CRICTLBIN" --runtime-endpoint "unix://$1" --image-endpoint "unix://$1" --config /dev/null --timeout 30s images -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(next((i["id"] for i in d.get("images", []) if any(sys.argv[1] in t for t in (i.get("repoTags") or []))), ""))
' "$APP_TAG"; }

EXPECTED=$(st "d['image_id']") || fail "setup's record is missing"
echo "[precondition] the three daemons are the recorded processes with the recorded configs, the wrappers and the tar are unchanged..."
for n in k3s system worker; do
    PID=$(st "d['daemons']['$n']['pid']")
    sudo test -d "/proc/$PID" || fail "the containerd of '$n' (pid $PID) is gone"
    [ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['daemons']['$n']['start']")" ] || fail "pid $PID is not the recorded containerd of '$n'"
    [ "$(sha "$RUN_BASE/$n/config.toml")" = "$(st "d['daemons']['$n']['config_sha']")" ] || fail "the config of '$n' changed"
done
for w in master/ctr master/crictl worker/ctr worker/crictl; do
    [ "$(sha "$WORK_DIR/$w")" = "$(st "d['wrappers']['$w']")" ] || fail "the wrapper $w changed"
done
[ "$(sha "$WORK_DIR/app.tar")" = "$(st "d['tar_sha']")" ] || fail "app.tar changed"
echo "  -> OK"

echo "[precondition] the symptom of the question on the master: its ctr lists the image in k8s.io, its crictl does not..."
sudo "$WORK_DIR/master/ctr" -n k8s.io images ls -q 2>/dev/null | grep -qxF "$APP_REF" || fail "the master's 'ctr -n k8s.io images ls' does not show $APP_REF"
[ -z "$(cri_id "$SOCK_K")" ] || fail "the master's crictl (the containerd of k3s) lists the image already"
sudo "$WORK_DIR/master/crictl" images 2>/dev/null | grep -qF "$CASE_ID-app" && fail "the master's crictl wrapper lists the image"
echo "  -> OK"

echo "[precondition] where the image really is: in the system containerd (the CRI of THAT daemon lists it with the tar's id), in no namespace of the containerd of k3s..."
[ "$(cri_id "$SOCK_S")" = "sha256:$EXPECTED" ] || fail "the system containerd does not list the image with the id of app.tar"
for ns in $(sudo "$WORK_DIR/master/ctr" -a "$SOCK_K" namespaces ls -q 2>/dev/null); do
    sudo "$WORK_DIR/master/ctr" -a "$SOCK_K" -n "$ns" images ls -q 2>/dev/null | grep -qF "$CASE_ID-app" && fail "the containerd of k3s has the image already (namespace $ns)"
done
echo "  -> OK"

echo "[precondition] the worker, the good node: ctr and crictl list the image (the tar's id) and its container runs it..."
sudo "$WORK_DIR/worker/ctr" -n k8s.io images ls -q 2>/dev/null | grep -qxF "$APP_REF" || fail "the worker's ctr does not show the image"
[ "$(cri_id "$SOCK_W")" = "sha256:$EXPECTED" ] || fail "the worker's crictl does not list the image with the id of app.tar"
WCTR=$(st "d['worker_container_id']")
sudo "$WORK_DIR/worker/crictl" ps -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if any(c["id"] == sys.argv[1] and c["state"] == "CONTAINER_RUNNING" for c in d["containers"]) else 1)
' "$WCTR" || fail "the worker's container is not running"
sudo "$WORK_DIR/worker/crictl" logs "$WCTR" 2>/dev/null | grep -qF "token=$(st "d['token']")" || fail "the worker's container does not show the image's token"
echo "  -> OK"

echo "[precondition] the master's pod sandbox on the containerd of k3s is ready and empty, and creating the container there fails because the image is not found..."
POD=$(st "d['pod_id']")
sudo "$WORK_DIR/master/crictl" pods -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if any(p["id"] == sys.argv[1] and p["state"] == "SANDBOX_READY" for p in d["items"]) else 1)
' "$POD" || fail "the master's pod sandbox is not ready"
[ -z "$(sudo "$WORK_DIR/master/crictl" ps -a -q 2>/dev/null)" ] || fail "the master already has a container"
OUT=$(sudo "$WORK_DIR/master/crictl" create "$POD" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json" 2>&1) && fail "the container was created on the master before the solution"
echo "$OUT" | grep -qi "not found" || fail "creating the container failed, but not with 'not found' ($OUT)"
echo "  -> OK"
echo "[precondition] all checks passed."
