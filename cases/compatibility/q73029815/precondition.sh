#!/bin/bash
set -e

CASE_ID="bench73029815"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMG="localhost/$CASE_ID/shop:snap"
SHA_LIST="sha256sum /srv/state/orders.dat /root/marker /etc/passwd /bin/busybox"

fail() { echo "  -> FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[precondition] the lab as recorded: CRI-O runs both containers with their own data, Podman runs its own container, and there is no image $IMG yet..."
for C in "$SHOP_CTR" "$BLOG_CTR"; do
    S="$(sudo crictl inspect "$C" | python3 -c 'import sys, json; s = json.load(sys.stdin)["status"]; print(s["state"], s["startedAt"])')"
    case "$S" in CONTAINER_RUNNING*) ;; *) fail "CRI-O container $C is not running ($S)";; esac
done
[ "$(sudo crictl exec "$SHOP_CTR" $SHA_LIST)" = "$SHOP_SHA" ] || fail "the data of the shop container is not as recorded"
[ "$(sudo crictl exec "$BLOG_CTR" $SHA_LIST)" = "$BLOG_SHA" ] || fail "the data of the blog container is not as recorded"
[ "$SHOP_SHA" != "$BLOG_SHA" ] || fail "both containers hold the same data"
[ "$(sudo podman inspect --format '{{.Id}} {{.State.Running}}' "$CASE_ID-native" 2>/dev/null)" = "$NATIVE_ID true" ] || fail "the Podman container is not running"
sudo podman image exists "$IMG" && fail "the image $IMG exists already"
echo "  -> OK"

echo "[precondition] the symptom of the question: 'podman ps -a' does not show the CRI-O containers, podman does not know them, and 'podman commit' of the shop container fails and makes no image..."
PS="$(sudo podman ps -a --format '{{.ID}} {{.Names}}')"
echo "$PS" | grep -q "$CASE_ID-native" || fail "podman ps -a does not show the container of Podman"
echo "$PS" | grep -q -e "${SHOP_CTR:0:12}" -e "${BLOG_CTR:0:12}" && fail "podman ps -a shows a CRI-O container"
sudo podman container exists "$SHOP_CTR" && fail "podman knows the CRI-O container"
sudo crictl ps -a -q | grep -q "${SHOP_CTR:0:12}" || fail "crictl ps -a does not show the shop container"
sudo podman commit "$SHOP_CTR" "localhost/$CASE_ID/pre:probe" >/dev/null 2>&1 && fail "podman commit worked on the CRI-O container"
sudo podman image exists "localhost/$CASE_ID/pre:probe" && fail "podman commit made an image"
echo "  -> OK"

echo "[precondition] controls: the oracle says FAIL with no image and with the base image under the name; it says PASS for an image made correctly..."
OUT="$(bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed with no image"
echo "$OUT" | grep -q "there is no image" || { echo "$OUT" | tail -3; fail "the oracle failed for another reason with no image"; }
sudo podman tag docker.io/library/busybox:1.36 "$IMG"
OUT="$(bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed with the base image"
echo "$OUT" | grep -q "differ from those of the running shop container" || { echo "$OUT" | tail -3; fail "the oracle failed for another reason with the base image"; }
sudo podman untag docker.io/library/busybox:1.36 "$IMG"
ROOT="$(sudo crictl inspect "$SHOP_CTR" | python3 -c 'import sys, json; print(json.load(sys.stdin)["info"]["runtimeSpec"]["root"]["path"])')"
sudo tar --numeric-owner -C "$ROOT" -cf - . | sudo podman import --change 'CMD ["/bin/sh"]' - "$IMG" >/dev/null
OUT="$(bash "$CASE_DIR/oracle.sh" 2>&1)" || { echo "$OUT" | tail -4; sudo podman rmi -f "$IMG" >/dev/null 2>&1; fail "the oracle rejected a correct image"; }
sudo podman rmi -f "$IMG" >/dev/null
sudo podman image exists "$IMG" && fail "the control image could not be removed"
echo "  -> OK"

echo "[precondition] PASS - the CRI-O containers are invisible to Podman and cannot be committed; the oracle tells right from wrong."
