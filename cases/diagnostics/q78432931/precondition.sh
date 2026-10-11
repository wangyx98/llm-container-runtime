#!/bin/bash
set -e

CASE_ID="bench78432931"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_DIR="$WORK_DIR/app"
REG_ADDR="127.0.0.1:43293"
NS="k8s.io"
TINY_REF="$REG_ADDR/bench/tiny:1"

CTR_T="sudo ctr -a $T_SOCK -n $NS"
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[precondition] checking what setup recorded: the private containerd, the registry and the helpers are the processes and files of setup..."
alive_same containerd || fail "the private containerd is not the process setup started"
alive_same registry || fail "the registry is not the process setup started"
[ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config changed"
(cd "$STATE_DIR" && sha256sum registry.py mkimage.py patch_config.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
$CTR_T version >/dev/null 2>&1 || fail "containerd does not answer on $T_SOCK"
[ "$(stat -c %U "$T_SOCK")" = "$(id -un)" ] || fail "the socket is not the user's: the Go program could not connect without sudo"
echo "  -> OK"

echo "[precondition] the registry: the image bench/app:1 is there, its blobs have the sizes of the record, and the layers are served at a limited rate..."
python3 - "$STATE_DIR" "$REG_ADDR" <<'PYEOF' || fail "the registry does not serve bench/app:1 as recorded"
import json
import sys
import time
import urllib.request

state, addr = sys.argv[1:3]
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
app = json.load(open(state + "/app.json"))
m = op.open(urllib.request.Request("http://%s/v2/bench/app/manifests/1" % addr,
            headers={"Accept": "application/vnd.oci.image.manifest.v1+json"}), timeout=10)
body = m.read()
assert m.headers["Docker-Content-Digest"] == app["manifest"]["digest"], "manifest digest"
assert len(body) == app["manifest"]["size"], "manifest size"
doc = json.loads(body)
assert [l["digest"] for l in doc["layers"]] == [l["digest"] for l in app["layers"]]
assert len(doc["layers"]) == 3, "the image has three layers"
for l in app["layers"]:
    h = op.open(urllib.request.Request("http://%s/v2/bench/app/blobs/%s" % (addr, l["digest"]), method="HEAD"), timeout=10)
    assert int(h.headers["Content-Length"]) == l["size"], "blob size"
big = max(app["layers"], key=lambda l: l["size"])
t0 = time.time()
r = op.open(urllib.request.Request("http://%s/v2/bench/app/blobs/%s" % (addr, big["digest"]), headers={"Range": "bytes=0-163839"}), timeout=10)
n = len(r.read())
dt = time.time() - t0
assert n == 163840 and r.status == 206, "range request"
assert dt >= 0.15, "the layers are served at full speed (160 KiB in %.2f s)" % dt
assert big["seconds"] >= 8 and all(l["seconds"] >= 6 and l["size"] >= 4.2 * 1048576 for l in app["layers"]), "durations"
print("  -> OK: 3 layers (%s), 160 KiB of the largest in %.2f s: about %.1f MiB/s" % (
      ", ".join("%.1f MiB" % (l["size"] / 1048576) for l in app["layers"]), dt, 160 / 1024 / dt))
PYEOF

echo "[precondition] nothing of bench/app:1 is in containerd yet: no image, no blob (the pull has to download it)..."
APP_BLOBS=$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1] + "/app.json"))
print(a["manifest"]["digest"], a["config"]["digest"], *[l["digest"] for l in a["layers"]])' "$STATE_DIR")
$CTR_T images ls -q | grep -q 'bench/app' && fail "bench/app is already an image of the namespace"
for d in $APP_BLOBS; do
    $CTR_T content ls -q | grep -qx "$d" && fail "the blob $d is already in the content store"
done
echo "  -> OK"

echo "[precondition] the program of the question: it builds, it pulls an image, and it is silent (no progress at all)..."
[ -f "$APP_DIR/main.go" ] && [ -f "$APP_DIR/go.mod" ] && [ -x "$APP_DIR/pull" ] || fail "$APP_DIR does not hold main.go, go.mod and the built pull"
grep -q 'containerd/v2/client' "$APP_DIR/main.go" || fail "the program does not use the containerd Go client"
grep -qE 'ListStatuses|progress|Progress' "$APP_DIR/main.go" && fail "the program already reports progress"
OUT=$(cd "$WORK_DIR" && timeout -k 3 60 "$APP_DIR/pull" --address "$T_SOCK" --namespace "$NS" --ref "$TINY_REF" 2>"$WORK_DIR/pre.err" </dev/null) \
    || { cat "$WORK_DIR/pre.err"; fail "the starter program could not pull $TINY_REF"; }
grep -q 'Pulled image' "$WORK_DIR/pre.err" || fail "the starter program did not say it pulled the image"
[ -z "$OUT" ] || fail "the starter program printed on stdout: $OUT"
grep -qE 'offset|total|progress' "$WORK_DIR/pre.err" && fail "the starter program reports progress"
$CTR_T images ls -q | grep -qx "$TINY_REF" || fail "the pulled tiny image is not in the namespace"
$CTR_T images rm --sync "$TINY_REF" >/dev/null 2>&1 || fail "could not remove the tiny image again"
rm -f "$WORK_DIR/pre.err"
echo "  -> OK: it pulls, and prints nothing while it does"

echo "[precondition] the program is still the starter, unchanged..."
cmp -s "$APP_DIR/main.go" "$(dirname "$0")/starter/main.go" || fail "main.go is not the starter"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED: a silent pull program, a registry that serves three layers slowly, a containerd with an empty content store."
