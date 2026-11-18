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
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"
# explicit endpoints: whatever the solution did to the wrappers or to a crictl config, grade against the daemons themselves
crictl_at() { local s=$1; shift; sudo "$CRICTLBIN" --runtime-endpoint "unix://$s" --image-endpoint "unix://$s" --config /dev/null --timeout 30s "$@"; }

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
jget() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
except Exception:
    sys.exit(0)
if v is not None:
    print(v)
' "$1"
}

echo "[oracle] check 0: setup's record is there; the three daemons are the recorded processes with the recorded configs (none restarted or reconfigured);"
echo "[oracle]          the wrappers and app.tar are unchanged..."
EXPECTED=$(st "d['image_id']" 2>/dev/null) && TOKEN=$(st "d['token']") && POD_AT_SETUP=$(st "d['pod_id']") || fail "setup's record is missing"
for n in k3s system worker; do
    PID=$(st "d['daemons']['$n']['pid']")
    sudo test -d "/proc/$PID" || fail "the containerd of '$n' (pid $PID) is not running any more"
    [ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['daemons']['$n']['start']")" ] || fail "the containerd of '$n' was restarted"
    [ "$(sha "$RUN_BASE/$n/config.toml")" = "$(st "d['daemons']['$n']['config_sha']")" ] || fail "the config of '$n' was changed"
done
for w in master/ctr master/crictl worker/ctr worker/crictl; do
    [ "$(sha "$WORK_DIR/$w")" = "$(st "d['wrappers']['$w']")" ] || fail "the wrapper $w was changed"
done
[ "$(sha "$WORK_DIR/app.tar")" = "$(st "d['tar_sha']")" ] || fail "app.tar was changed"
echo "  -> OK"

echo "[oracle] check 1: the CRI of k3s (what its kubelet and crictl consult) lists the image, and it is THE image of app.tar (id = the sha256 of its config blob)..."
IMAGES_JSON=$(crictl_at "$SOCK_K" images -o json 2>/dev/null || true)
FOUND_ID=$(echo "$IMAGES_JSON" | jget "next((i['id'] for i in d['images'] if any('$APP_TAG' in t for t in (i.get('repoTags') or []))), '')")
[ -n "$FOUND_ID" ] || fail "the CRI of k3s does not list $APP_TAG"
[ "${FOUND_ID#sha256:}" = "$EXPECTED" ] || fail "the image listed by the CRI of k3s has id ${FOUND_ID#sha256:}, expected $EXPECTED (not the image of app.tar)"
ACCEPTED=$(echo "$IMAGES_JSON" | jget "' '.join([i['id'] for i in d['images'] if i['id'] == '$FOUND_ID'] + [r for i in d['images'] if i['id'] == '$FOUND_ID' for r in (i.get('repoDigests') or [])])")
echo "  -> OK ($FOUND_ID)"

echo "[oracle] check 2: the system containerd, where the image was first imported, still has it (it was to be copied, not moved)..."
sudo "$CRICTLBIN" --runtime-endpoint "unix://$SOCK_S" --config /dev/null --timeout 30s images -o json 2>/dev/null | jget "next((i['id'] for i in d['images'] if any('$APP_TAG' in t for t in (i.get('repoTags') or []))), '')" | grep -qx "sha256:$EXPECTED" || fail "the system containerd does not list the image any more"
echo "  -> OK"

echo "[oracle] check 3: the worker, the good node, is as it was: the image with the tar's id and its container still running..."
[ "$(crictl_at "$SOCK_W" images -o json 2>/dev/null | jget "next((i['id'] for i in d['images'] if any('$APP_TAG' in t for t in (i.get('repoTags') or []))), '')")" = "sha256:$EXPECTED" ] || fail "the worker's image is not as it was"
WCTR=$(st "d['worker_container_id']")
[ "$(crictl_at "$SOCK_W" ps -o json 2>/dev/null | jget "next((c['state'] for c in d['containers'] if c['id'] == '$WCTR'), '')")" = "CONTAINER_RUNNING" ] || fail "the worker's container is not running any more"
echo "  -> OK"

echo "[oracle] check 4: on the containerd of k3s the pod sandbox is the ORIGINAL one (not recreated), the only one, SANDBOX_READY..."
PODS_JSON=$(crictl_at "$SOCK_K" pods -o json 2>/dev/null || true)
[ "$(echo "$PODS_JSON" | jget "len(d['items'])")" = 1 ] || fail "expected exactly one pod sandbox on the containerd of k3s ($(echo "$PODS_JSON" | jget "len(d['items'])") found)"
POD_ID=$(echo "$PODS_JSON" | jget "next(p['id'] for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
[ "$POD_ID" = "$POD_AT_SETUP" ] || fail "the pod sandbox was recreated (id ${POD_ID:-none}, was $POD_AT_SETUP)"
[ "$(echo "$PODS_JSON" | jget "d['items'][0]['state']")" = "SANDBOX_READY" ] || fail "the pod sandbox is not SANDBOX_READY"
echo "  -> OK"

echo "[oracle] check 5: exactly one container '$CONTAINER_NAME' on the containerd of k3s, in that pod, CONTAINER_RUNNING..."
CTRS_JSON=$(crictl_at "$SOCK_K" ps -a -o json 2>/dev/null || true)
[ "$(echo "$CTRS_JSON" | jget "len(d['containers'])")" = 1 ] || fail "expected exactly one container on the containerd of k3s"
CTR_ID=$(echo "$CTRS_JSON" | jget "next(c['id'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
[ -n "$CTR_ID" ] || fail "no container named '$CONTAINER_NAME' on the containerd of k3s"
[ "$(echo "$CTRS_JSON" | jget "d['containers'][0]['podSandboxId']")" = "$POD_ID" ] || fail "the container is not in pod '$POD_NAME'"
[ "$(echo "$CTRS_JSON" | jget "d['containers'][0]['state']")" = "CONTAINER_RUNNING" ] || fail "the container is $(echo "$CTRS_JSON" | jget "d['containers'][0]['state']"), expected CONTAINER_RUNNING"
echo "  -> OK ($CTR_ID)"

echo "[oracle] check 6: it was created from that very image..."
INSPECT=$(crictl_at "$SOCK_K" inspect -o json "$CTR_ID" 2>/dev/null || true)
REF=$(echo "$INSPECT" | jget "d['status'].get('imageRef', '')"); IID=$(echo "$INSPECT" | jget "d['status'].get('imageId', '')")
MATCH=0
for r in $REF $IID; do for ok in $ACCEPTED; do [ "$r" = "$ok" ] && MATCH=1; done; done
[ "$MATCH" = 1 ] || fail "the container's image '${REF:-?}' is not the image of app.tar"
echo "  -> OK"

echo "[oracle] check 7: it runs the image's own entrypoint (no overridden command) and that process is alive..."
ARGS=$(echo "$INSPECT" | jget "' '.join(d['info']['runtimeSpec']['process']['args'])")
[ "$ARGS" = "/bench-app" ] || fail "the process args are '$ARGS', expected '/bench-app'"
PID=$(echo "$INSPECT" | jget "d['info'].get('pid')")
{ [ -n "$PID" ] && [ "$PID" != 0 ] && sudo kill -0 "$PID" 2>/dev/null; } || fail "the container's process (pid '${PID:-none}') is not alive"
case "$(sudo tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)" in "/bench-app"*) ;; *) fail "pid $PID is not /bench-app" ;; esac
echo "  -> OK (pid $PID)"

echo "[oracle] check 8: its log carries the token that exists only inside the image (waits up to 10 s)..."
SEEN=0
for _ in $(seq 1 20); do
    crictl_at "$SOCK_K" logs "$CTR_ID" 2>/dev/null | grep -qF "bench74685092-image-ok token=$TOKEN" && { SEEN=1; break; }
    sleep 0.5
done
[ "$SEEN" = 1 ] || fail "the container's log never showed the token of the image"
echo "  -> OK"
echo "[oracle] ALL CHECKS PASSED"
