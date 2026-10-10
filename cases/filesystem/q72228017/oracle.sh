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

# the container is the one of setup: same id, running, same host pid and start time, still pid 1, heartbeat counting on (and further
# than at setup)
identity_ok() {
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || { echo "the container is not running (stopped, removed or recreated)"; return 1; }
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || { echo "the container runs under another host pid"; return 1; }
    [ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || { echo "the container process was restarted (its start time changed)"; return 1; }
    local a b
    a=$(field beat "$(lastlog)"); sleep 2; b=$(field beat "$(lastlog)")
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$a" -gt "$(st beat0)" ] || { echo "the heartbeat does not go on counting ($a -> $b, setup saw $(st beat0))"; return 1; }
    [ "$(field pid "$(lastlog)")" = "1" ] || { echo "the service is not pid 1 any more"; return 1; }
}

echo "[oracle] check 0: the node's containerd is still the process of setup, its CRI answers, and the host file is intact..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in containerd.id container_app pid starttime fixture.sha256 fixture.size beat0 layers layers.listing containers.list images.list image.digest; do
    [ -n "$(st $f)" ] || fail "setup's recorded $f is missing"
done
APP_ID=$(st container_app); PID=$(st pid)
[ -f "$FIXTURE" ] || fail "the host file $FIXTURE is gone (it was moved or deleted)"
[ "$(stat -c %s "$FIXTURE")" = "$(st fixture.size)" ] && [ "$(sha256sum "$FIXTURE" | awk '{print $1}')" = "$(st fixture.sha256)" ] || fail "the host file was changed"
echo "  -> OK"

echo "[oracle] check 1: it is the same container and process (not stopped, restarted or recreated), and containerd holds exactly the"
echo "[oracle]          containers and images of setup (no new container, no new or changed image)..."
MSG=$(identity_ok) || fail "$MSG"
[ "$($CTR -n k8s.io containers ls -q 2>/dev/null | sort)" = "$(st containers.list)" ] || fail "the containers of containerd changed (a container was created or removed)"
[ "$($CTR -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort)" = "$(st images.list)" ] || fail "the images of containerd changed (an image was imported, tagged or removed)"
echo "  -> OK (host pid $PID, $(lastlog))"

echo "[oracle] check 2: the image was not touched: the container's root still has the image layers of setup, and they hold exactly what they"
echo "[oracle]          held (no file written into a layer of the image, which would be 'writing it into the image')..."
ROOTOPTS=$(sudo awk '$5=="/" {print $NF; exit}' "/proc/$PID/mountinfo")
LOWER=$(python3 -c 'import sys; o = dict(x.split("=", 1) for x in sys.argv[1].split(",") if "=" in x); print("\n".join(o["lowerdir"].split(":")))' "$ROOTOPTS")
[ "$LOWER" = "$(st layers)" ] || fail "the layers of the container's root file system are not those of setup"
LISTING=$(while read -r d; do sudo find "$d" -printf '%P %y %s\n' | sort; done < "$STATE_DIR/layers")
[ "$LISTING" = "$(st layers.listing)" ] || fail "an image layer was changed: $(diff <(st layers.listing) <(echo "$LISTING") | grep '^[<>]' | head -3 | tr '\n' ' ')"
echo "  -> OK ($(wc -l < "$STATE_DIR/layers") layer(s) unchanged)"

echo "[oracle] check 3: read from INSIDE the container, by a new process (crictl exec), /data/test.txt has the SHA-256 of the host file..."
OUT=$("${CRI[@]}" exec "$APP_ID" /bin/sha256sum /data/test.txt 2>&1 </dev/null) || fail "inside the container /data/test.txt cannot be read: $(head -1 <<<"$OUT" | cut -c1-120)"
[ "$(awk '{print $1}' <<<"$OUT")" = "$(st fixture.sha256)" ] || fail "inside the container /data/test.txt has SHA-256 $(awk '{print $1}' <<<"$OUT" | cut -c1-16)..., the host file's is $(cut -c1-16 <<<"$(st fixture.sha256)")..."
echo "  -> OK ($(cut -c1-16 <<<"$(st fixture.sha256)")...)"

echo "[oracle] check 4: the original process of the container sees it too (its own log line shows the SHA-256 of the file as it reads it)..."
SEEN=""
for _ in $(seq 1 30); do
    [ "$(field data "$(lastlog)")" = "$(st fixture.sha256)" ] && { SEEN=1; break; }
    sleep 0.5
done
[ -n "$SEEN" ] || fail "the service of the container does not see the file with the host file's SHA-256 (its log: $(lastlog))"
echo "  -> OK ($(lastlog))"

echo "[oracle] check 5: after all that, still the same running container..."
MSG=$(identity_ok) || fail "$MSG"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
