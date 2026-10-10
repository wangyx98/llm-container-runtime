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

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id image_id diff_id marker archive.sha256 archive.size pause.tar; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the archive: a valid docker archive (manifest.json, one layer, the config file named by its own digest) whose"
echo "[precondition] manifest.json has \"RepoTags\": null (the result of 'docker save <image id>'), and that it is the one of setup..."
[ -f "$ARCHIVE" ] || fail "$ARCHIVE is missing"
[ "$(stat -c %s "$ARCHIVE")" = "$(st archive.size)" ] && [ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" = "$(st archive.sha256)" ] || fail "the archive is not the one of setup"
OUT=$(python3 - "$ARCHIVE" <<'PYEOF'
import hashlib
import json
import sys
import tarfile

t = tarfile.open(sys.argv[1])
names = t.getnames()
manifest = json.load(t.extractfile("manifest.json"))
assert len(manifest) == 1, "more than one image in the archive"
m = manifest[0]
assert "RepoTags" in m and m["RepoTags"] is None, "RepoTags is not null: %r" % (m.get("RepoTags", "missing"),)
assert "repositories" not in names, "there is a repositories file"
cfg = t.extractfile(m["Config"]).read()
image_id = "sha256:" + hashlib.sha256(cfg).hexdigest()
assert m["Config"] == image_id.split(":")[1] + ".json", "the config file is not named by its digest"
assert len(m["Layers"]) == 1
layer = t.extractfile(m["Layers"][0]).read()
assert json.loads(cfg)["rootfs"]["diff_ids"] == ["sha256:" + hashlib.sha256(layer).hexdigest()], "the layer does not match the config"
print(image_id)
PYEOF
) || fail "the archive is not what setup built ($OUT)"
[ "$OUT" = "$IMAGE_ID" ] || fail "the image id in the archive ($OUT) is not the recorded one ($IMAGE_ID)"
echo "  -> OK (RepoTags null; the image is $IMAGE_ID)"

echo "[precondition] checking that namespace k8s.io (and every other) is empty: no image, no container, no content, nothing the CRI knows..."
for ns in $($CTR namespaces ls -q 2>/dev/null) k8s.io; do
    [ -z "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] || fail "namespace $ns already has images"
    [ -z "$($CTR -n "$ns" containers ls -q 2>/dev/null)" ] || fail "namespace $ns already has containers"
    [ -z "$($CTR -n "$ns" content ls -q 2>/dev/null)" ] || fail "namespace $ns already has content"
done
[ "$("${CRI[@]}" images -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["images"]))')" = 0 ] || fail "the CRI already lists images"
[ -z "$("${CRI[@]}" ps -a -q 2>/dev/null)" ] || fail "the CRI already lists containers"
echo "  -> OK"

echo "[precondition] the symptom, as a CONTROL in a scratch namespace (not k8s.io): the plain import prints nothing and exits 0, yet no image"
echo "[precondition] record is created (the blobs of the archive sit in the content store at most until containerd's garbage collection)..."
CTL_NS="$CASE_ID-control"
OUT=$($CTR -n "$CTL_NS" images import "$ARCHIVE" 2>/dev/null) && RC=0 || RC=$?
LISTED=$($CTR -n "$CTL_NS" images ls -q 2>/dev/null | wc -l)
BLOBS=$($CTR -n "$CTL_NS" content ls -q 2>/dev/null | wc -l)
# take the scratch namespace away again: images, snapshots, content, then the namespace
$CTR -n "$CTL_NS" images rm --sync $($CTR -n "$CTL_NS" images ls -q 2>/dev/null) >/dev/null 2>&1 || true
for s in $($CTR -n "$CTL_NS" snapshots ls 2>/dev/null | awk 'NR>1 {print $1}'); do $CTR -n "$CTL_NS" snapshots rm "$s" >/dev/null 2>&1 || true; done
$CTR -n "$CTL_NS" content rm $($CTR -n "$CTL_NS" content ls -q 2>/dev/null) >/dev/null 2>&1 || true
$CTR namespaces rm "$CTL_NS" >/dev/null 2>&1 || true
echo "     exit code $RC; standard output: '$OUT'; images listed: $LISTED; blobs in the content store right after it: $BLOBS (they are collected by the garbage collector soon)"
[ "$RC" = 0 ] || fail "the plain import was expected to end with exit code 0, it gave $RC"
[ -z "$OUT" ] || fail "the plain import was expected to print nothing"
[ "$LISTED" = 0 ] || fail "the plain import created an image record"
if $CTR namespaces ls -q 2>/dev/null | grep -qx "$CTL_NS"; then fail "could not remove the scratch namespace"; fi
for ns in $($CTR namespaces ls -q 2>/dev/null) k8s.io; do
    [ -z "$($CTR -n "$ns" images ls -q 2>/dev/null)" ] && [ -z "$($CTR -n "$ns" content ls -q 2>/dev/null)" ] || fail "after the control, namespace $ns is not empty"
done
echo "  -> OK (silent, exit 0, no image; the scratch namespace is removed and k8s.io is still empty)"

echo "[precondition] ALL OK: an unnamed docker archive, an empty k8s.io, and the plain import creates no image."
