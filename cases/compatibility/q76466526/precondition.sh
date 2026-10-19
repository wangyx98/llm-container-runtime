#!/bin/bash
# Precondition oracle: the lab is the one setup.sh recorded, and the question's symptom is there. Docker shows the image, ctr shows nothing of it
# in any namespace (default, k8s.io, moby), so this is not a wrong namespace: the two programs keep their images in two stores.
CASE_ID="bench76466526"
LIB_BASE="/var/lib/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
DOCKER="$LIB_BASE/bin/docker"
CTR="$LIB_BASE/bin/ctr"
IMAGE="bench76466526/app:v1"
CTR_REF="docker.io/bench76466526/app:v1"

fail() { echo "[precondition] FAIL: $*"; exit 1; }
step() { echo "[precondition] $*"; }
ctr() { sudo "$CTR" "$@" 2> >(grep -v DEPRECATION >&2); }

for f in image.id nonce driver files.sha layers.json; do [ -s "$STATE_DIR/$f" ] || fail "$STATE_DIR/$f is missing: setup.sh has not run"; done
IMAGE_ID="$(cat "$STATE_DIR/image.id")"; HEX="${IMAGE_ID#sha256:}"

step "1/5 the stack: containerd and dockerd run on the case's sockets, the files of the engineer are as recorded..."
for n in containerd dockerd; do
    pid="$(cat "$RUN_BASE/$n.pid" 2>/dev/null)"
    [ -n "$pid" ] && sudo kill -0 "$pid" 2>/dev/null || fail "$n is not running"
done
[ -S "$RUN_BASE/containerd.sock" ] && [ -S "$RUN_BASE/docker.sock" ] || fail "a socket of the stack is missing"
( cd "$LIB_BASE" && sudo sha256sum -c "$STATE_DIR/files.sha" >/dev/null 2>&1 ) || fail "a file of the stack (script or configuration) differs from the record"
echo "  -> OK"

step "2/5 docker's store is the classic graph-driver store (daemon.json: containerd-snapshotter false)..."
[ "$(sudo "$DOCKER" info --format '{{.Driver}}' 2>/dev/null)" = "$(cat "$STATE_DIR/driver")" ] || fail "docker's storage driver is not the recorded one"
sudo "$DOCKER" info 2>/dev/null | grep -qi "io.containerd.snapshotter" && fail "docker uses the containerd image store"
sudo grep -q '"containerd-snapshotter": false' "$LIB_BASE/etc/daemon.json" || fail "daemon.json does not name the classic store"
sudo test -e "$LIB_BASE/docker/image/$(cat "$STATE_DIR/driver")/imagedb/content/sha256/$HEX" || fail "docker's own image database does not hold the image's config"
echo "  -> OK ($(cat "$STATE_DIR/driver"), the config is in docker's imagedb)"

step "3/5 the symptom of the question: docker image ls shows the image..."
sudo "$DOCKER" image ls --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E "^$IMAGE sha256:$HEX|^$IMAGE ${HEX:0:12}" || fail "docker image ls does not show $IMAGE"
[ "$(sudo "$DOCKER" image inspect --format '{{.Id}}' "$IMAGE")" = "$IMAGE_ID" ] || fail "docker's image is not the recorded one"
[ "$(sudo "$DOCKER" image inspect --format '{{json .RootFS.Layers}}' "$IMAGE")" = "$(cat "$STATE_DIR/layers.json")" ] || fail "docker's layers are not the recorded ones"
echo "  -> OK"

step "4/5 ...and ctr shows nothing of it in default, k8s.io or moby (images and content), and finds no file of it in containerd's root; ctr run cannot start it..."
for ns in default k8s.io moby; do
    echo "  ctr -n $ns images ls:"
    ctr -n "$ns" images ls | sed 's/^/    /'
    ctr -n "$ns" images ls -q | grep -q "bench76466526" && fail "namespace $ns already lists the image"
    ctr -n "$ns" content ls -q | grep -q "$HEX" && fail "namespace $ns already holds the image's config blob"
done
[ -z "$(sudo find "$LIB_BASE/containerd" -name "$HEX" 2>/dev/null)" ] || fail "containerd's root already has a file named like the image's config digest"
out="$(ctr -n default run --rm "$CTR_REF" precondition-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -qi "not found" || fail "ctr run of $CTR_REF did not fail with 'not found' (rc=$rc): $out"
echo "  ctr run: $(echo "$out" | head -1)"
echo "  -> OK"

step "5/5 the oracle itself, as the control: it must FAIL while the image is not in containerd's namespace default..."
out="$(bash "$(dirname "$0")/oracle.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "the oracle passes although nothing was delivered"
echo "$out" | grep -q "does not list" || fail "the oracle failed for another reason than the missing image: $(echo "$out" | tail -2)"
echo "  -> OK ($(echo "$out" | tail -1))"

echo "[precondition] PASS - docker has the image, containerd has none of it in any namespace; the stores are separate, a namespace cannot show it."
