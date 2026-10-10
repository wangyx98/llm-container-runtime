#!/bin/bash
set -e

CASE_ID="bench67607380"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ARCHIVE="$WORK_DIR/myimage.tar"
PAUSE_REF="$CASE_ID.local/pause:1"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
IMAGE_ID=$(st image_id)      # what the image is: the digest of its config file, which is what the CRI calls the image id
MARKER=$(st marker)
# the images the CRI lists with the image id $1: one line per image, "tags: ... digests: ..."
cri_refs_of() {
    "${CRI[@]}" images -o json 2>/dev/null | python3 -c '
import json, sys
for im in json.load(sys.stdin)["images"]:
    if im["id"] == sys.argv[1]:
        for r in im.get("repoTags", []) + im.get("repoDigests", []):
            print(r)' "$1"
}

echo "[oracle] check 0: the node's containerd is still the process of setup, its CRI answers, and the archive is untouched..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in containerd.id image_id marker archive.sha256 archive.size pause.tar; do
    sudo test -s "$STATE_DIR/$f" || fail "setup's recorded $f is missing"
done
[ -f "$ARCHIVE" ] || fail "the archive $ARCHIVE is gone (moved, renamed or deleted)"
[ "$(stat -c %s "$ARCHIVE")" = "$(st archive.size)" ] && [ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" = "$(st archive.sha256)" ] || fail "the archive was changed (the image has to come from the archive as it is)"
echo "  -> OK"

echo "[oracle] check 1: the CRI of the node lists the image of the archive, identified by its image id $IMAGE_ID"
echo "[oracle]          (the digest of the config file: an image with other content has another id), and the image has a record in k8s.io..."
REFS=$(cri_refs_of "$IMAGE_ID")
NAMED=$($CTR -n k8s.io images ls 2>/dev/null | awk -v id="$IMAGE_ID" 'NR>1 && $1 != id {print $1}')
if ! "${CRI[@]}" inspecti "$IMAGE_ID" >/dev/null 2>&1; then
    WHY=""
    if $CTR -n k8s.io content ls -q 2>/dev/null | grep -qxF "$IMAGE_ID"; then
        WHY="; the blobs of the archive ARE in the content store of k8s.io, but no image record points at them (that is what the plain import leaves behind)"
    fi
    for ns in $($CTR namespaces ls -q 2>/dev/null); do
        [ "$ns" = k8s.io ] && continue
        if [ -n "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] && $CTR -n "$ns" content ls -q 2>/dev/null | grep -qxF "$IMAGE_ID"; then
            WHY="$WHY; the image was imported into the namespace $ns, which the CRI does not look at"
        fi
    done
    OTHERS=$($CTR -n k8s.io images ls -q 2>/dev/null | head -3 | tr '\n' ' ')
    [ -z "$OTHERS" ] || WHY="$WHY; k8s.io has other images ($OTHERS) but none of them is the image of the archive (another image id)"
    fail "the CRI does not know an image with the id of the archive$WHY"
fi
[ "$("${CRI[@]}" inspecti "$IMAGE_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')" = "$IMAGE_ID" ] || fail "crictl inspecti $IMAGE_ID does not report that id"
[ -n "$NAMED" ] || fail "the image has no record under a name or digest reference in k8s.io"
for n in $NAMED; do
    case "$n" in *@*) continue ;; esac       # a name@digest import record: the CRI knows it by the id, not by this string
    [ "$("${CRI[@]}" inspecti "$n" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])' 2>/dev/null)" = "$IMAGE_ID" ] \
        || fail "the name $n in k8s.io does not resolve, in the CRI, to the image of the archive"
done
echo "     records in k8s.io: $(tr '\n' ' ' <<<"$NAMED")"
echo "  -> OK (crictl inspecti $IMAGE_ID)"

echo "[oracle] check 2: the image runs ITS OWN program (not only 'has blobs'): a pod (oracle-owned sandbox image, imported only now) and a"
echo "[oracle]          container created from the image id print the name and the random marker of setup..."
REF="$IMAGE_ID"
$CTR -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || fail "the oracle could not import its own sandbox image"
python3 - "$WORK_DIR" "$CASE_ID" "$REF" <<'PYEOF'
import json
import sys

work, case, ref = sys.argv[1:4]
ns = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}
with open(work + "/oracle-pod.json", "w") as f:
    json.dump({"metadata": {"name": case + "-oracle-pod", "namespace": "default", "attempt": 1, "uid": case + "-oracle-uid"},
               "log_directory": work + "/logs", **ns}, f)
with open(work + "/oracle-app.json", "w") as f:
    json.dump({"metadata": {"name": "oracle-app"}, "image": {"image": ref}, "log_path": "oracle-app.log", **ns}, f)
PYEOF
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/runp_err.txt") || { head -3 "$STATE_DIR/runp_err.txt"; fail "the oracle could not start its pod"; }
CID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/oracle-app.json" "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/create_err.txt") \
    || { head -3 "$STATE_DIR/create_err.txt" | cut -c1-300; fail "a container cannot be created from the image (the CRI lists it, crictl inspecti works, but it cannot run it: the reference it has for the image is not one the CRI can resolve)"; }
"${CRI[@]}" start "$CID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { head -3 "$STATE_DIR/start_err.txt"; fail "the container of $REF cannot be started"; }
LINE=""
for _ in $(seq 1 30); do
    LINE=$("${CRI[@]}" logs "$CID" 2>/dev/null | grep -m1 "bench67607380 name=" || true)
    [ -n "$LINE" ] && break
    sleep 0.5
done
[ -n "$LINE" ] || fail "the container of $REF printed nothing"
[ "$LINE" = "bench67607380 name=hello marker=$MARKER" ] || fail "the container of $REF printed '$LINE', not the name and marker of the archive's program"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the container of $REF is not running"
echo "  -> OK ($LINE)"

echo "[oracle] check 3: still the same containerd, the archive as it was, and the image still listed..."
alive_same containerd || fail "containerd was replaced meanwhile"
[ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" = "$(st archive.sha256)" ] || fail "the archive was changed"
[ -n "$(cri_refs_of "$IMAGE_ID")" ] || fail "the image is not listed any more"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
