#!/bin/bash
set -e

CASE_ID="bench70936917"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMG_DIR="$WORK_DIR/images"
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
# the images of namespace $1 as "REF DIGEST" lines (ctr's DIGEST column is the digest of the manifest)
images_of() { $CTR -n "$1" images ls 2>/dev/null | awk 'NR>1 {print $1, $3}'; }
# the three expectations: name, reference, expected manifest digest, expected CRI image id (digest of the config), marker, file name
while IFS=$'\t' read -r n r m c; do
    NAMES+=("$n"); REFS+=("$r"); MANS+=("$m"); CFGS+=("$c")
done < <(sudo cat "$STATE_DIR/truth.tsv" 2>/dev/null)
while IFS=$'\t' read -r n r f k; do
    FILES+=("$f"); MARKS+=("$k")
done < <(sudo cat "$STATE_DIR/images.tsv" 2>/dev/null)

echo "[oracle] check 0: the node's containerd is still the process of setup, its CRI answers, and the three archives are untouched..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in containerd.id truth.tsv images.tsv archives.sha pause.tar; do
    sudo test -s "$STATE_DIR/$f" || fail "setup's recorded $f is missing"
done
[ "${#NAMES[@]}" = 3 ] && [ "${#FILES[@]}" = 3 ] || fail "setup's recorded images are missing"
for i in 0 1 2; do
    f="$IMG_DIR/${FILES[$i]}"
    [ -f "$f" ] || fail "the archive ${FILES[$i]} is gone (moved, renamed or deleted)"
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$(awk -F'\t' -v f="${FILES[$i]}" '$2==f {print $1}' < <(st archives.sha))" ] || fail "the archive ${FILES[$i]} was changed"
done
echo "  -> OK"

echo "[oracle] check 1: namespace k8s.io of the node's containerd holds each of the three images under its own reference AND with the"
echo "[oracle]          digest of the manifest in its archive (a retagged copy of another image, or an image from somewhere else, has another digest)..."
K8S=$(images_of k8s.io)
MISSING=()
for i in 0 1 2; do
    D=$(awk -v r="${REFS[$i]}" '$1==r {print $2; exit}' <<<"$K8S")
    if [ -z "$D" ]; then
        MISSING+=("${REFS[$i]} (from ${FILES[$i]})")
        continue
    fi
    [ "$D" = "${MANS[$i]}" ] || fail "${REFS[$i]} is in k8s.io but with digest ${D:0:19}..., the archive ${FILES[$i]} has ${MANS[$i]:0:19}..."
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    ELSEWHERE=""
    for ns in $($CTR namespaces ls -q 2>/dev/null); do
        [ "$ns" = k8s.io ] && continue
        for i in 0 1 2; do
            images_of "$ns" | grep -qxF "${REFS[$i]} ${MANS[$i]}" && ELSEWHERE="$ELSEWHERE ${REFS[$i]}@$ns"
        done
    done
    [ -z "$ELSEWHERE" ] || echo "     imported, but into another namespace:$ELSEWHERE"
    fail "k8s.io is missing ${#MISSING[@]} of the 3 images: $(printf '%s; ' "${MISSING[@]}")"
fi
echo "  -> OK (all three, with the digests of their archives)"

echo "[oracle] check 2: the CRI sees them: each reference is listed (crictl images) with the image id (digest of the config) of its archive..."
CRIIMGS=$("${CRI[@]}" images -o json 2>/dev/null)
for i in 0 1 2; do
    ID=$(python3 -c '
import json, sys
ref = sys.argv[1]
for im in json.load(sys.stdin)["images"]:
    if ref in im.get("repoTags", []):
        print(im["id"])
        break' "${REFS[$i]}" <<<"$CRIIMGS")
    [ -n "$ID" ] || fail "the CRI does not list ${REFS[$i]}"
    [ "$ID" = "${CFGS[$i]}" ] || fail "the CRI lists ${REFS[$i]} with id ${ID:0:19}..., the archive ${FILES[$i]} has ${CFGS[$i]:0:19}..."
    "${CRI[@]}" inspecti "${REFS[$i]}" >/dev/null 2>&1 || fail "crictl inspecti ${REFS[$i]} fails"
done
echo "  -> OK"

echo "[oracle] check 3: every image runs ITS OWN program: a pod (oracle-owned sandbox image, imported only now) with one container per image;"
echo "[oracle]          each prints the name and the random marker of setup, and no other image's marker..."
$CTR -n k8s.io images import "$STATE_DIR/pause.tar" >/dev/null 2>&1 || fail "the oracle could not import its own sandbox image"
python3 - "$WORK_DIR" "$CASE_ID" <<'PYEOF'
import json
import sys

work, case = sys.argv[1:3]
with open(work + "/oracle-pod.json", "w") as f:
    json.dump({"metadata": {"name": case + "-oracle-pod", "namespace": "default", "attempt": 1, "uid": case + "-oracle-uid"},
               "log_directory": work + "/logs",
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/runp_err.txt") || { head -3 "$STATE_DIR/runp_err.txt"; fail "the oracle could not start its pod"; }
for i in 0 1 2; do
    python3 - "$WORK_DIR" "${NAMES[$i]}" "${REFS[$i]}" <<'PYEOF'
import json
import sys

work, name, ref = sys.argv[1:4]
with open(work + "/oracle-" + name + ".json", "w") as f:
    json.dump({"metadata": {"name": "oracle-" + name}, "image": {"image": ref}, "log_path": "oracle-" + name + ".log",
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF
    CID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/oracle-${NAMES[$i]}.json" "$WORK_DIR/oracle-pod.json" 2>"$STATE_DIR/create_err.txt") \
        || { head -3 "$STATE_DIR/create_err.txt"; fail "the container of ${REFS[$i]} cannot be created"; }
    "${CRI[@]}" start "$CID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { head -3 "$STATE_DIR/start_err.txt"; fail "the container of ${REFS[$i]} cannot be started"; }
    LINE=""
    for _ in $(seq 1 30); do
        LINE=$("${CRI[@]}" logs "$CID" 2>/dev/null | grep -m1 "bench70936917 name=" || true)
        [ -n "$LINE" ] && break
        sleep 0.5
    done
    [ -n "$LINE" ] || fail "the container of ${REFS[$i]} printed nothing"
    [ "$LINE" = "bench70936917 name=${NAMES[$i]} marker=${MARKS[$i]}" ] || fail "the container of ${REFS[$i]} printed '$LINE', not its own name and marker"
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the container of ${REFS[$i]} is not running"
    echo "     ${REFS[$i]}: $LINE"
done
echo "  -> OK"

echo "[oracle] check 4: still the same containerd, and still the three images (and the archives still as they were)..."
alive_same containerd || fail "containerd was replaced meanwhile"
K8S=$(images_of k8s.io)
for i in 0 1 2; do
    grep -qxF "${REFS[$i]} ${MANS[$i]}" <<<"$K8S" || fail "${REFS[$i]} is not in k8s.io any more"
    [ "$(sha256sum "$IMG_DIR/${FILES[$i]}" | awk '{print $1}')" = "$(awk -F'\t' -v f="${FILES[$i]}" '$2==f {print $1}' < <(st archives.sha))" ] || fail "the archive ${FILES[$i]} was changed"
done
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
