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

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id truth.tsv images.tsv archives.sha pause.tar; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
[ "${#NAMES[@]}" = 3 ] && [ "${#FILES[@]}" = 3 ] || fail "setup did not record three images"
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the directory $IMG_DIR: three archives, as recorded, one of them with a space in its name..."
[ "$(ls -1 "$IMG_DIR" | wc -l)" = 3 ] || fail "$IMG_DIR does not hold exactly three files"
SPACES=0
for i in 0 1 2; do
    f="$IMG_DIR/${FILES[$i]}"
    [ -f "$f" ] || fail "${FILES[$i]} is missing"
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$(awk -F'\t' -v f="${FILES[$i]}" '$2==f {print $1}' < <(st archives.sha))" ] || fail "${FILES[$i]} is not the archive of setup"
    case "${FILES[$i]}" in *" "*) SPACES=$((SPACES+1)) ;; esac
done
[ "$SPACES" = 1 ] || fail "exactly one archive name should contain a space"
echo "  -> OK ($(ls -1 "$IMG_DIR" | tr '\n' ',' | sed 's/,$//'))"

echo "[precondition] checking that every archive is a valid tagged image: its own tag and the digests the oracle expects (read from the"
echo "[precondition] archive itself, not from the recorded values), and that the three differ..."
for i in 0 1 2; do
    OUT=$(python3 - "$IMG_DIR/${FILES[$i]}" <<'PYEOF'
import hashlib
import json
import sys
import tarfile

t = tarfile.open(sys.argv[1])
index = json.load(t.extractfile("index.json"))
man = index["manifests"][0]
blob = t.extractfile("blobs/sha256/" + man["digest"].split(":")[1]).read()
assert "sha256:" + hashlib.sha256(blob).hexdigest() == man["digest"]
cfg = json.loads(blob)["config"]["digest"]
print(man["annotations"]["io.containerd.image.name"], man["digest"], cfg)
PYEOF
    ) || fail "${FILES[$i]} is not a valid image archive"
    [ "$OUT" = "${REFS[$i]} ${MANS[$i]} ${CFGS[$i]}" ] || fail "${FILES[$i]} does not carry what setup recorded ($OUT)"
    echo "     ${FILES[$i]} -> $OUT" | cut -c1-150
done
[ "$(printf '%s\n' "${REFS[@]}" | sort -u | wc -l)" = 3 ] && [ "$(printf '%s\n' "${MANS[@]}" | sort -u | wc -l)" = 3 ] || fail "the three images are not different"
echo "  -> OK"

echo "[precondition] checking the node is offline for these images: their registry host does not exist, so nothing can be pulled..."
if getent hosts "$CASE_ID.local" >/dev/null 2>&1; then fail "$CASE_ID.local resolves: the images could be pulled"; fi
echo "  -> OK"

echo "[precondition] checking namespace k8s.io (and every other) is empty: no image, no container, nothing the CRI knows..."
for ns in $($CTR namespaces ls -q 2>/dev/null) k8s.io; do
    [ -z "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] || fail "namespace $ns already has images"
    [ -z "$($CTR -n "$ns" containers ls -q 2>/dev/null)" ] || fail "namespace $ns already has containers"
done
[ "$("${CRI[@]}" images -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["images"]))')" = 0 ] || fail "the CRI already lists images"
[ -z "$("${CRI[@]}" ps -a -q 2>/dev/null)" ] || fail "the CRI already lists containers"
echo "  -> OK"

echo "[precondition] the original attempt, as a CONTROL in a scratch namespace (not k8s.io): the file names are handed over by xargs to ONE"
echo "[precondition] 'images import' (ctr, standing in for 'nerdctl load -i'): it finishes with exit code 0 and says 'saved', but only the first"
echo "[precondition] archive is imported..."
CTL_NS="$CASE_ID-control"
OUT=$(cd "$IMG_DIR" && ls | xargs $CTR -n "$CTL_NS" images import --no-unpack 2>&1) && RC=0 || RC=$?
echo "     exit code $RC; output: $(grep -v DEPRECATION <<<"$OUT" | head -1 | cut -c1-80)"
GOT=$(images_of "$CTL_NS" | awk '{print $1}')
$CTR -n "$CTL_NS" images rm --sync $($CTR -n "$CTL_NS" images ls -q 2>/dev/null) >/dev/null 2>&1 || true
$CTR namespaces rm "$CTL_NS" >/dev/null 2>&1 || true
[ "$RC" = 0 ] || fail "the xargs attempt was expected to end with exit code 0, it gave $RC"
[ "$GOT" = "${REFS[0]}" ] || fail "the xargs attempt was expected to import only ${REFS[0]}, it imported: $(tr '\n' ' ' <<<"$GOT")"
for ns in $($CTR namespaces ls -q 2>/dev/null) k8s.io; do
    [ -z "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] || fail "after the control, namespace $ns is not empty"
done
echo "  -> OK (only ${REFS[0]} was imported, silently; the control namespace is removed, k8s.io is still empty)"

echo "[precondition] ALL OK: three archives, an empty k8s.io, and the xargs way imports only one of them."
