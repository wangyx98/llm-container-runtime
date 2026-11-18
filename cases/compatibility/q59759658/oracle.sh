#!/bin/bash
set -e

CASE_ID="bench59759658"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN_BASE/containerd.sock"
IMAGE_REF="docker.io/library/$CASE_ID-web:local"
CONTAINER="$CASE_ID-web"
CTR="sudo ctr -a $SOCK"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }

NONCE=$(sudo cat "$STATE_DIR/nonce" 2>/dev/null || true)
[ -n "$NONCE" ] || fail "setup's nonce is missing"

echo "[oracle] check 0: the node's containerd is the process setup started (not stopped, not restarted, not reconfigured); the tools, the wrappers and the project files are unchanged..."
PID=$(st "d['pid']")
sudo test -d "/proc/$PID" || fail "the node's containerd (pid $PID) is gone: it was stopped or restarted"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd any more"
$CTR version >/dev/null 2>&1 || fail "the node's containerd does not answer"
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a tool, a wrapper, the containerd config or a project file changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 1: a BuildKit with the containerd worker of THIS node did a build: its namespace 'buildkit' in the node's containerd holds a committed snapshot..."
N=$($CTR -n buildkit snapshots ls 2>/dev/null | awk '$3 == "Committed"' | wc -l)
[ "$N" -ge 1 ] || fail "the node's containerd has no snapshot of a BuildKit build in its 'buildkit' namespace (the image was not built by BuildKit on this node)"
echo "  -> OK ($N committed snapshot(s))"

echo "[oracle] check 2: the node's 'default' namespace has the image $IMAGE_REF, with the build argument of the compose file in its labels, its entrypoint, and in its layers the file /nonce.txt of this run and /app..."
$CTR -n default images ls -q 2>/dev/null | grep -qxF "$IMAGE_REF" || fail "the image $IMAGE_REF is not in the node's default namespace"
TMP=$(mktemp -d); trap 'sudo rm -rf "$TMP"' EXIT
$CTR -n default images export "$TMP/image.tar" "$IMAGE_REF" >/dev/null 2>&1 || fail "the image cannot be exported from the node's containerd"
python3 - "$TMP/image.tar" "$NONCE" <<'PYEOF' || fail "the image does not hold what the compose build makes (see above)"
import json, sys, tarfile

path, nonce = sys.argv[1:3]
t = tarfile.open(path)
blob = lambda digest: t.extractfile("blobs/" + digest.replace(":", "/")).read()
idx = json.load(t.extractfile("index.json"))
desc = idx["manifests"][0]
doc = json.loads(blob(desc["digest"]))
while "manifests" in doc:                       # an index: take the first manifest that has layers
    doc = json.loads(blob(doc["manifests"][0]["digest"]))
cfg = json.loads(blob(doc["config"]["digest"]))
labels = (cfg.get("config") or {}).get("Labels") or {}
if labels.get("bench59759658.built-by") != "compose-" + nonce:
    print("     label bench59759658.built-by is %r, expected 'compose-%s' (the build argument of the compose file)" % (labels.get("bench59759658.built-by"), nonce)); sys.exit(1)
if (cfg.get("config") or {}).get("Entrypoint") != ["/app"]:
    print("     entrypoint is %r" % (cfg.get("config") or {}).get("Entrypoint")); sys.exit(1)
found = {}
for layer in doc["layers"]:
    lt = tarfile.open(fileobj=t.extractfile("blobs/" + layer["digest"].replace(":", "/")))
    for m in lt.getmembers():
        n = m.name.lstrip("./")
        if n in ("nonce.txt", "app"):
            found[n] = lt.extractfile(m).read() if m.isfile() else b""
if found.get("nonce.txt", b"").decode().strip() != nonce or not found.get("app"):
    print("     the layers hold nonce.txt=%r and app=%d bytes" % (found.get("nonce.txt"), len(found.get("app", b"")))); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 3: exactly one container made by compose (labels com.docker.compose.service=web and a project) runs in the node's 'default' namespace from that image..."
COUNT=0; CID=""
for c in $($CTR -n default containers ls -q 2>/dev/null); do
    INFO=$($CTR -n default containers info "$c" 2>/dev/null) || continue
    if echo "$INFO" | python3 -c 'import json,sys; l=json.load(sys.stdin).get("Labels") or {}; sys.exit(0 if l.get("com.docker.compose.service") == "web" and l.get("com.docker.compose.project") else 1)'; then
        COUNT=$((COUNT + 1)); CID=$c
    fi
done
[ "$COUNT" = "1" ] || fail "expected exactly 1 container with the compose labels (service web) in the node's default namespace, found $COUNT (a container started by hand has no compose labels)"
IMG=$($CTR -n default containers info "$CID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Image"])')
[ "$IMG" = "$IMAGE_REF" ] || [ "$IMG" = "$CASE_ID-web:local" ] || fail "the container runs the image '$IMG', not $IMAGE_REF"
echo "  -> OK (container ${CID:0:12})"

echo "[oracle] check 4: its task is RUNNING, the process is alive and is /app, and the log shows the nonce of this run (waits up to 10 s)..."
$CTR -n default tasks ls 2>/dev/null | awk -v id="$CID" '$1 == id {print $3}' | grep -qx RUNNING || fail "the container has no RUNNING task in the node's containerd"
TPID=$($CTR -n default tasks ls 2>/dev/null | awk -v id="$CID" '$1 == id {print $2}')
sudo kill -0 "$TPID" 2>/dev/null || fail "the container's process (pid '$TPID') is not alive"
[ "$(sudo cat "/proc/$TPID/cmdline" 2>/dev/null | tr '\0' ' ')" = "/app " ] || fail "pid $TPID is not /app"
SEEN=0
for _ in $(seq 1 20); do
    if sudo env PATH="$LIB_BASE/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$LIB_BASE/bin/nerdctl" --address "$SOCK" --data-root "$LIB_BASE/nerdctl" --cni-netconfpath "$LIB_BASE/cni-conf" logs "$CID" 2>&1 | grep -qF "bench59759658-ok nonce=$NONCE"; then SEEN=1; break; fi
    sleep 0.5
done
[ "$SEEN" = "1" ] || fail "the container's log never showed the nonce of this run"
echo "  -> OK (pid $TPID)"

echo "[oracle] ALL CHECKS PASSED"
