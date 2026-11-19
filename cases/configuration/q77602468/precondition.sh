#!/bin/bash
set -e

CASE_ID="bench77602468"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CRIO_SOCK="$RUN_BASE/crio.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
DOCKER() { sudo docker -H "unix://$DOCKER_SOCK" "$@"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" "$@"; }
daemon_ok() {   # $1 = containerd|dockerd|crio: the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded and the three daemons (containerd, Docker, CRI-O)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
for d in containerd dockerd crio; do daemon_ok "$d" || fail "the recorded $d is not running"; done
DOCKER version >/dev/null 2>&1 || fail "Docker does not answer on $DOCKER_SOCK"
CRICTL version >/dev/null 2>&1 || fail "CRI-O does not answer on $CRIO_SOCK"
IMG=$(sj img); PAUSE=$(sj pause_img); HEX=$(sj config_hex)
echo "  -> OK"

echo "[precondition] checking Docker holds the private image, with the recorded id (its config digest)..."
[ "$(DOCKER image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)" = "sha256:$HEX" ] || fail "Docker does not hold $IMG with the recorded id"
echo "  -> OK ($IMG, sha256:${HEX:0:12}...)"

echo "[precondition] checking CRI-O does not know the image, cannot pull it (the registry name does not exist), and cannot create a container from it..."
CRICTL inspecti "$IMG" >/dev/null 2>&1 && fail "CRI-O already has the image"
case "$(CRICTL images 2>/dev/null)" in *"bench77602468/app"*) fail "CRI-O already lists an image of the case" ;; esac
OUT=$(CRICTL pull "$IMG" 2>&1) && fail "CRI-O pulled the image"
echo "$OUT" | grep -qiE 'no such host|lookup|dial|pinging|resolve|connect' || fail "the pull failed for another reason: $(echo "$OUT" | tail -1 | cut -c1-200)"
CRICTL inspecti "$PAUSE" >/dev/null 2>&1 || fail "CRI-O lacks the sandbox image of its pods"
cat > "$WORK_DIR/.pre-pod.json" <<JEOF
{"metadata":{"name":"pre","namespace":"n","uid":"u-pre","attempt":1},"log_directory":"$WORK_DIR/.pre-logs","linux":{}}
JEOF
cat > "$WORK_DIR/.pre-ctr.json" <<JEOF
{"metadata":{"name":"c"},"image":{"image":"$IMG"},"log_path":"c.log","linux":{}}
JEOF
mkdir -p "$WORK_DIR/.pre-logs"
POD=$(CRICTL runp "$WORK_DIR/.pre-pod.json" 2>/dev/null | tail -1) || true
[ -n "$POD" ] || fail "CRI-O cannot start a pod sandbox (the lab is broken)"
if CRICTL create "$POD" "$WORK_DIR/.pre-ctr.json" "$WORK_DIR/.pre-pod.json" >/dev/null 2>&1; then CRICTL rmp -f "$POD" >/dev/null 2>&1; fail "a container could be created from the image"; fi
CRICTL stopp "$POD" >/dev/null 2>&1 || true; CRICTL rmp "$POD" >/dev/null 2>&1 || true
rm -rf "$WORK_DIR/.pre-pod.json" "$WORK_DIR/.pre-ctr.json" "$WORK_DIR/.pre-logs"
echo "  -> OK"

echo "[precondition] checking the image is not in the machine's default container storage either (it must be copied into the CRI-O's own storage, not found there)..."
for d in /var/lib/containers/storage; do
    if sudo test -f "$d/overlay-images/images.json" && sudo grep -qF "bench77602468/app" "$d/overlay-images/images.json"; then fail "the image is already in $d"; fi
done
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the image is in Docker only, CRI-O does not know it."
