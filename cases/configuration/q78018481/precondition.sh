#!/bin/bash
set -e

CASE_ID="bench78018481"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
OLD_DIR="$RUN_BASE/registry-old"
NEW_DIR="$RUN_BASE/registry-new"
REPO="google_containers/pause"
OLD_REF="127.0.0.1:18081/$REPO:3.6"
NEW_REF="127.0.0.1:18082/$REPO:3.6"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }
sandbox_image() {   # $1 = pod sandbox id -> the image the sandbox runs, as containerd reports it for that sandbox
    "${CRI[@]}" inspectp -o json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["image"])'
}
image_digests() {   # $1 = image ref -> its repo digests, one per line (nothing when the image is not in containerd)
    local out
    out=$("${CRI[@]}" inspecti -o json "$1" 2>/dev/null) || return 0
    printf '%s' "$out" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["status"].get("repoDigests", [])))'
}

echo "[precondition] checking the state setup recorded and the three daemons (containerd and the two registries)..."
for f in containerd.id registry-old.id registry-new.id old.truth new.truth old-pod.id registry-old.state0 registry-new.state0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry-old registry-new; do alive_same "$d" || fail "the recorded $d is not running"; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking both registries serve a pause image, and that the two images are different..."
for w in old new; do
    if [ $w = old ]; then P=18081; else P=18082; fi
    HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:$P/v2/$REPO/manifests/3.6" | tr -d '\r')
    echo "$HDR" | head -1 | grep -q ' 200' || fail "the $w registry does not serve $REPO:3.6"
    [ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(jget $w manifest)" ] || fail "the digest in the $w registry is not the recorded one"
done
[ "$(jget old manifest)" != "$(jget new manifest)" ] || fail "the two pause images have the same digest"
echo "  -> OK (old $(jget old manifest | cut -c1-19)..., new $(jget new manifest | cut -c1-19)...)"

echo "[precondition] checking the existing sandbox runs the OLD pause image, from the OLD registry..."
OLD_POD=$(sudo cat "$STATE_DIR/old-pod.id")
STATE=$("${CRI[@]}" pods --id "$OLD_POD" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["state"])')
[ "$STATE" = "SANDBOX_READY" ] || fail "the existing sandbox is $STATE"
[ "$(sandbox_image "$OLD_POD")" = "$OLD_REF" ] || fail "the existing sandbox does not run $OLD_REF"
image_digests "$OLD_REF" | grep -qF "@$(jget old manifest)" || fail "the OLD pause image in containerd has not the digest of the OLD registry"
sudo grep -q "^GET /v2/$REPO/blobs/.* ua=containerd/" "$OLD_DIR/requests.log" || fail "the OLD registry log shows no blob download by containerd"
echo "  -> OK"

echo "[precondition] checking the NEW registry was never used by containerd and its image is not in containerd..."
if sudo grep -q "ua=containerd/" "$NEW_DIR/requests.log"; then fail "containerd already talked to the NEW registry"; fi
if image_digests "$NEW_REF" | grep -q .; then fail "the NEW pause image is already in containerd"; fi
echo "  -> OK"

echo "[precondition] checking a NEW sandbox, created now, still takes the OLD pause image (the reported symptom)..."
cat > "$WORK_DIR/pre-pod.json" <<CONF
{
  "metadata": {"name": "bench78018481-pre", "namespace": "default", "attempt": 1, "uid": "bench78018481-pre-uid"},
  "log_directory": "$WORK_DIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
CONF
PRE_POD=$("${CRI[@]}" runp "$WORK_DIR/pre-pod.json" 2> "$WORK_DIR/pre_err.txt") || { tail -2 "$WORK_DIR/pre_err.txt" | cut -c1-300; fail "could not start a test sandbox"; }
GOT=$(sandbox_image "$PRE_POD")
"${CRI[@]}" stopp "$PRE_POD" >/dev/null 2>&1 || true
"${CRI[@]}" rmp -f "$PRE_POD" >/dev/null 2>&1 || true
[ "$GOT" = "$OLD_REF" ] || fail "the test sandbox runs $GOT, expected $OLD_REF"
if sudo grep -q "ua=containerd/" "$NEW_DIR/requests.log"; then fail "containerd talked to the NEW registry"; fi
echo "  -> OK (a new sandbox runs $GOT)"

echo "[precondition] PASS - containerd's sandbox image is the OLD one; the NEW registry is unused."
