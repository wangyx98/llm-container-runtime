#!/bin/bash
set -e

CASE_ID="bench72228017"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FIXTURE="$WORK_DIR/test.txt"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"
APP_REF="$CASE_ID.local/app:1"

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
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the service printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id pod_id container_app pid starttime fixture.sha256 fixture.size beat0 layers layers.listing containers.list images.list image.digest; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the container runs (the recorded host pid and start time), its heartbeat counts, and it is pid 1..."
APP_ID=$(st container_app); PID=$(st pid)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the container is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "the container has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the container process has another start time"
L1=$(lastlog); sleep 2; L2=$(lastlog)
[ "$(field beat "$L2")" -gt "$(field beat "$L1")" ] || fail "the heartbeat does not advance ($L1 / $L2)"
[ "$(field pid "$L2")" = "1" ] || fail "the service is not pid 1 in its own pid namespace"
echo "  -> OK ($L2)"

echo "[precondition] checking the host file: random content with the recorded size and SHA-256, and that it is NOT in the container: not"
echo "[precondition] mounted into it, not in the layers of its image, not in its writable layer, not readable from inside..."
[ "$(stat -c %s "$FIXTURE")" = "$(st fixture.size)" ] || fail "the host file has not the recorded size"
[ "$(sha256sum "$FIXTURE" | awk '{print $1}')" = "$(st fixture.sha256)" ] || fail "the host file has not the recorded SHA-256"
[ "$(field data "$L2")" = "none" ] || fail "the service already sees a /data/test.txt ($L2)"
if sudo test -e "/proc/$PID/root/data/test.txt"; then fail "/data/test.txt exists in the container"; fi
if sudo awk '{print $5}' "/proc/$PID/mountinfo" | grep -qxF /data; then fail "something is mounted at /data in the container"; fi
if sudo grep -q "$FIXTURE" "/proc/$PID/mountinfo"; then fail "the host file is mounted into the container"; fi
[ "$("${CRI[@]}" inspect -o go-template --template '{{len .status.mounts}}' "$APP_ID")" = 0 ] || fail "the container has mounts configured"
[ -z "$(sudo find $(cat "$STATE_DIR/layers") -name test.txt 2>/dev/null)" ] || fail "an image layer holds a test.txt"
OUT=$("${CRI[@]}" exec "$APP_ID" /bin/sha256sum /data/test.txt 2>&1 >/dev/null || true)
echo "     sha256sum /data/test.txt inside the container: $(head -1 <<<"$OUT" | cut -c1-90)"
for t in cat cp sh; do
    if "${CRI[@]}" exec "$APP_ID" "/bin/$t" --version >/dev/null 2>&1; then fail "the container has /bin/$t"; fi
done
echo "  -> OK (host file $(st fixture.size) bytes, sha256 $(cut -c1-16 <<<"$(st fixture.sha256)")...)"

echo "[precondition] checking containerd's inventory is the recorded one (images, containers) and the image layers hold what they held..."
[ "$($CTR -n k8s.io containers ls -q 2>/dev/null | sort)" = "$(st containers.list)" ] || fail "the containers of containerd changed"
[ "$($CTR -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort)" = "$(st images.list)" ] || fail "the images of containerd changed"
LISTING=$(while read -r d; do sudo find "$d" -printf '%P %y %s\n' | sort; done < "$STATE_DIR/layers")
[ "$LISTING" = "$(st layers.listing)" ] || fail "the image layers hold other files than at setup"
echo "  -> OK"
