#!/bin/bash
set -e

CASE_ID="bench59811664"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
WS_DIR="$WORK_DIR/workstation"
WS_PODMAN="sudo podman --root $WS_DIR/root --runroot $WS_DIR/run"
WS_IMAGE="localhost/$CASE_ID/app:v1"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"

# $1 = python expression over `d` (the parsed JSON on stdin); prints its value, or nothing on any error
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

echo "[oracle] check 0: CRI-O answers, and setup's recorded values are there..."
sudo systemctl is-active --quiet crio.service || { echo "  -> FAIL: crio.service is not active"; exit 1; }
sudo crictl info >/dev/null 2>&1 || { echo "  -> FAIL: crictl cannot talk to CRI-O"; exit 1; }
EXPECTED_ID=$(sudo cat "$STATE_DIR/expected_image_id" 2>/dev/null || true)
DIFF_ID=$(sudo cat "$STATE_DIR/diff_id" 2>/dev/null || true)
TOKEN=$(sudo cat "$STATE_DIR/token" 2>/dev/null || true)
REGISTRY=$(sudo cat "$STATE_DIR/registry_addr" 2>/dev/null || true)
if [ -z "$EXPECTED_ID" ] || [ -z "$TOKEN" ] || [ -z "$REGISTRY" ]; then
    echo "  -> FAIL: setup's recorded image id / token / registry address are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: the workstation's image must be unchanged (the image has to come from it)..."
WS_ID=$($WS_PODMAN image inspect --format '{{.Id}}' "$WS_IMAGE" 2>/dev/null || true)
if [ "${WS_ID#sha256:}" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: $WS_IMAGE in the workstation store is '$WS_ID', expected $EXPECTED_ID"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: exactly one pod sandbox named '$POD_NAME', SANDBOX_READY..."
PODS_JSON=$(sudo crictl pods -o json 2>/dev/null || true)
POD_COUNT=$(echo "$PODS_JSON" | jget "sum(1 for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
if [ "${POD_COUNT:-0}" != "1" ]; then
    echo "  -> FAIL: expected exactly 1 pod sandbox named '$POD_NAME', found ${POD_COUNT:-0}"
    exit 1
fi
POD_STATE=$(echo "$PODS_JSON" | jget "next(p['state'] for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
POD_ID=$(echo "$PODS_JSON" | jget "next(p['id'] for p in d['items'] if p['metadata']['name'] == '$POD_NAME')")
if [ "$POD_STATE" != "SANDBOX_READY" ]; then
    echo "  -> FAIL: pod sandbox is $POD_STATE, expected SANDBOX_READY"
    exit 1
fi
echo "  -> OK ($POD_ID)"

echo "[oracle] check 3: exactly one container named '$CONTAINER_NAME', in that pod, CONTAINER_RUNNING..."
CTRS_JSON=$(sudo crictl ps -a -o json 2>/dev/null || true)
CTR_COUNT=$(echo "$CTRS_JSON" | jget "sum(1 for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
if [ "${CTR_COUNT:-0}" != "1" ]; then
    echo "  -> FAIL: expected exactly 1 container named '$CONTAINER_NAME', found ${CTR_COUNT:-0}"
    exit 1
fi
CTR_ID=$(echo "$CTRS_JSON" | jget "next(c['id'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
CTR_STATE=$(echo "$CTRS_JSON" | jget "next(c['state'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
CTR_POD=$(echo "$CTRS_JSON" | jget "next(c['podSandboxId'] for c in d['containers'] if c['metadata']['name'] == '$CONTAINER_NAME')")
if [ "$CTR_POD" != "$POD_ID" ]; then
    echo "  -> FAIL: the container belongs to pod $CTR_POD, not to '$POD_NAME' ($POD_ID)"
    exit 1
fi
if [ "$CTR_STATE" != "CONTAINER_RUNNING" ]; then
    echo "  -> FAIL: container is $CTR_STATE, expected CONTAINER_RUNNING"
    exit 1
fi
echo "  -> OK ($CTR_ID)"

echo "[oracle] check 4: CRI-O must have started THE workstation's image: the container's image id is"
echo "[oracle]          the recorded config digest (a rebuilt or re-imported lookalike has another id),"
echo "[oracle]          and the image's layer is the recorded one..."
INSPECT_JSON=$(sudo crictl inspect -o json "$CTR_ID" 2>/dev/null || true)
CTR_IMAGE_ID=$(echo "$INSPECT_JSON" | jget "d['status'].get('imageId', '').replace('sha256:', '')")
CTR_IMAGE_REF=$(echo "$INSPECT_JSON" | jget "d['status']['image'].get('image', '')")
if [ "$CTR_IMAGE_ID" != "$EXPECTED_ID" ]; then
    echo "  -> FAIL: the container's image id is '$CTR_IMAGE_ID', expected $EXPECTED_ID"
    exit 1
fi
IMG_JSON=$(sudo crictl inspecti -o json "$EXPECTED_ID" 2>/dev/null || true)
GOT_DIFF=$(echo "$IMG_JSON" | jget "d['info']['imageSpec']['rootfs']['diff_ids'][0].replace('sha256:', '')")
if [ -n "$DIFF_ID" ] && [ "$GOT_DIFF" != "$DIFF_ID" ]; then
    echo "  -> FAIL: CRI-O's image has layer '$GOT_DIFF', expected '$DIFF_ID'"
    exit 1
fi
echo "  -> OK (sha256:$EXPECTED_ID, named '$CTR_IMAGE_REF')"

echo "[oracle] check 5: it runs the image's own entrypoint (no overridden command), as a live process..."
CTR_ARGS=$(echo "$INSPECT_JSON" | jget "' '.join(d['info']['runtimeSpec']['process']['args'])")
if [ "$CTR_ARGS" != "/app" ]; then
    echo "  -> FAIL: the container's process args are '$CTR_ARGS', expected '/app'"
    exit 1
fi
CTR_PID=$(echo "$INSPECT_JSON" | jget "d['info'].get('pid')")
if [ -z "$CTR_PID" ] || [ "$CTR_PID" = "0" ] || ! sudo kill -0 "$CTR_PID" 2>/dev/null; then
    echo "  -> FAIL: the container's process (pid '${CTR_PID:-none}') is not alive"
    exit 1
fi
echo "  -> OK (pid $CTR_PID)"

echo "[oracle] check 6: the unique file is read out of the running container (its root as the kernel sees"
echo "[oracle]          it), and the program printed it to the container's log (waits up to 10 s)..."
FILE_TOKEN=$(sudo cat "/proc/$CTR_PID/root/etc/unique.txt" 2>/dev/null | tr -d '\n' || true)
if [ "$FILE_TOKEN" != "$TOKEN" ]; then
    echo "  -> FAIL: /etc/unique.txt inside the container is '$FILE_TOKEN', expected the workstation image's token"
    exit 1
fi
SEEN=0
for _ in $(seq 1 20); do
    if sudo crictl logs "$CTR_ID" 2>/dev/null | grep -qF "bench59811664-app file=$TOKEN"; then SEEN=1; break; fi
    sleep 0.5
done
if [ "$SEEN" != "1" ]; then
    echo "  -> FAIL: the container's log never showed the unique file's content"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 7: delivery path. Every name that the image carries in CRI-O's store (and the name the"
echo "[oracle]          container was created with) that points to the registry is a claim 'this came from the"
echo "[oracle]          registry': the registry must really have served it (request log + stored manifest). An"
echo "[oracle]          image with no registry name is an imported artifact, proven by checks 4 and 6..."
# all names of that image id in CRI-O's own listing; which one the container reports depends on the version
IMG_REFS=$(sudo crictl images -o json 2>/dev/null | jget "'\\n'.join(r for i in d['images'] if i['id'].replace('sha256:', '') == '$EXPECTED_ID' for r in (i.get('repoTags') or []) + (i.get('repoDigests') or []))")
ALL_REFS=$(printf '%s\n%s\n' "$CTR_IMAGE_REF" "$IMG_REFS" | sort -u | grep -F "$REGISTRY/" || true)
if [ -z "$ALL_REFS" ]; then
    echo "  -> OK (imported artifact: the image's names are: $(echo $IMG_REFS))"
else
    sudo python3 - "$STATE_DIR" "$REGISTRY" "$EXPECTED_ID" "$ALL_REFS" <<'PYEOF'
import json, os, sys
state, reg, eid, refs = sys.argv[1:5]


def fail(msg):
    print(msg)
    sys.exit(1)


lines = [l.split() for l in open(state + "/registry.log") if l.strip()]
names = set()
for ref in refs.split():
    name = ref[len(reg) + 1:].split("@")[0]
    if ":" in name.rsplit("/", 1)[-1]:
        name = name.rsplit(":", 1)[0]
    names.add(name)
for name in sorted(names):
    mdir = state + "/registry/data/manifests"
    pref = name.replace("/", "_") + "__"
    ok = False
    for f in os.listdir(mdir):
        if f.startswith(pref):
            try:
                if json.load(open(mdir + "/" + f))["config"]["digest"] == "sha256:" + eid:
                    ok = True
            except Exception:
                pass
    if not ok:
        fail("  -> FAIL: the image is named '%s/%s' but the registry holds no manifest of it with config sha256:%s" % (reg, name, eid))

    def served(kind, tail=None):
        return any(l[1] == "GET" and l[3] == "200" and ("/v2/%s/%s/" % (name, kind)) in l[2]
                   and (tail is None or l[2].endswith(tail)) for l in lines)

    if not served("blobs", "sha256:" + eid):
        fail("  -> FAIL: the image is named '%s/%s' but the registry log shows no successful GET of its config blob" % (reg, name))
    if not served("manifests"):
        fail("  -> FAIL: the image is named '%s/%s' but the registry log shows no successful GET of a manifest" % (reg, name))
print("  -> OK (registry route: %s served from %s)" % (", ".join(sorted(names)), reg))
PYEOF
fi

echo "[oracle] ALL CHECKS PASSED"
