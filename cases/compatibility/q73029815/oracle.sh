#!/bin/bash
set -e

CASE_ID="bench73029815"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMG="localhost/$CASE_ID/shop:snap"
SHA_LIST="sha256sum /srv/state/orders.dat /root/marker /etc/passwd /bin/busybox"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[oracle] 1/4 the source must be as it was: both CRI-O pods and containers are the same ones, running, not restarted; the Podman container still runs; no pod was added or removed..."
cri_state() { sudo crictl inspect "$1" 2>/dev/null | python3 -c 'import sys, json; s = json.load(sys.stdin)["status"]; print(s["state"], s["startedAt"])'; }
pod_state() { sudo crictl inspectp "$1" 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["status"]["state"])'; }
[ "$(cri_state "$SHOP_CTR")" = "CONTAINER_RUNNING $SHOP_STARTED" ] || fail "the container of the shop pod is gone, stopped or was restarted (now: $(cri_state "$SHOP_CTR"))"
[ "$(cri_state "$BLOG_CTR")" = "CONTAINER_RUNNING $BLOG_STARTED" ] || fail "the container of the blog pod is gone, stopped or was restarted (now: $(cri_state "$BLOG_CTR"))"
[ "$(pod_state "$SHOP_POD")" = "SANDBOX_READY" ] || fail "the shop pod is not ready any more"
[ "$(pod_state "$BLOG_POD")" = "SANDBOX_READY" ] || fail "the blog pod is not ready any more"
[ "$(sudo crictl pods -q | wc -l)" = "$PODS_TOTAL" ] || fail "the number of CRI-O pods changed (was $PODS_TOTAL)"
[ "$(sudo podman inspect --format '{{.Id}} {{.State.Running}}' "$CASE_ID-native" 2>/dev/null)" = "$NATIVE_ID true" ] || fail "the container of Podman ($CASE_ID-native) is gone or stopped"
[ "$(sudo crictl exec "$SHOP_CTR" $SHA_LIST)" = "$SHOP_SHA" ] || fail "the data of the running shop container was changed"

echo "[oracle] 2/4 the image $IMG must exist in root's Podman store..."
sudo podman image exists "$IMG" || fail "there is no image $IMG in root's Podman store"

echo "[oracle] 3/4 the image must run, and the three files and the shell's own program in it must be those of the running shop container (not the blog's, not the base image's)..."
sudo timeout 120 podman run --rm --network none --pull=never --entrypoint /bin/sh "$IMG" -c true >/tmp/"$CASE_ID"-run.log 2>&1 || { tail -3 /tmp/"$CASE_ID"-run.log; fail "the image does not run /bin/sh"; }
# only podman's STDOUT is compared: on some hosts podman prints warnings about other tools' CNI files on stderr on every call
GOT="$(sudo timeout 120 podman run --rm --network none --pull=never --entrypoint /bin/sh "$IMG" -c "$SHA_LIST 2>&1; true" 2>/dev/null)"
if [ "$GOT" != "$SHOP_SHA" ]; then
    echo "--- expected (the running container)"; echo "$SHOP_SHA"; echo "--- found (in the image)"; echo "$GOT"
    fail "the files of the image differ from those of the running shop container"
fi
[ "$GOT" != "$BLOG_SHA" ] || fail "the image holds the data of the blog container"

echo "[oracle] 4/4 the image must have been made for this: its content is not the base image's..."
[ "$(sudo podman image inspect --format '{{.Id}}' "$IMG")" != "$(sudo podman image inspect --format '{{.Id}}' docker.io/library/busybox:1.36)" ] || fail "the image is the base image itself"

echo "[oracle] ALL CHECKS PASSED: $IMG runs and holds the current files of the container app of the pod bench73029815-shop; the source containers still run."
