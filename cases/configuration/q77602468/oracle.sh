#!/bin/bash
# Postcondition oracle. Every check is dynamic: what CRI-O reports for the image, and a container that the oracle creates through the CRI
# (what the kubelet does) from that image, starts, reads the log of and runs a command in.
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
daemon_ok() {
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }

IMG=$(sj img); HEX=$(sj config_hex); TOKEN=$(sj token)

echo "[oracle] check 1: the lab is the one of setup (containerd, Docker and CRI-O are the recorded processes; CRI-O's configuration, the wrappers"
echo "[oracle] are unchanged), and Docker still holds the image with the same id: it was copied, not moved..."
for d in containerd dockerd crio; do daemon_ok "$d" || fail "the $d of setup is not running (or was replaced)"; done
sudo python3 - "$STATE_DIR/state.json" <<'PYEOF' || fail "a file of the lab was changed (see above)"
import hashlib, json, sys
d = json.load(open(sys.argv[1])); bad = []
for f, h in d["files"].items():
    try:
        if hashlib.sha256(open(f, "rb").read()).hexdigest() != h: bad.append(f)
    except OSError: bad.append(f)
if bad: print("changed: " + ", ".join(bad)); sys.exit(1)
PYEOF
[ "$(DOCKER image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)" = "sha256:$HEX" ] || fail "Docker no longer holds $IMG with its original id (the image was removed or replaced in Docker)"
echo "  -> OK"

echo "[oracle] check 2: CRI-O's own storage holds the image under its name, and its image id is the config digest of the image in Docker..."
J=$(CRICTL inspecti "$IMG" 2>/dev/null) || fail "CRI-O does not know $IMG"
echo "$J" | python3 -c '
import json, sys
s = json.load(sys.stdin)["status"]
assert sys.argv[2] in s.get("repoTags", []), "repoTags " + str(s.get("repoTags"))
assert s["id"].replace("sha256:", "") == sys.argv[1], "image id %s is not the Docker image id %s" % (s["id"], sys.argv[1])
' "$HEX" "$IMG" 2>&1 | tail -1 | grep . && fail "the image CRI-O has under that name is not the Docker image ($(echo "$J" | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"]; print(s["id"][:12], s.get("repoTags"))'))"
echo "  -> OK (id ${HEX:0:12}...)"

echo "[oracle] check 3: a new pod and a container made through the CRI from that image (no pull is possible) run it: same image id, the log shows the"
echo "[oracle] token of this run, and a command run inside prints it..."
D="$STATE_DIR/oracle-$$"; sudo mkdir -p "$D/logs"
sudo tee "$D/pod.json" >/dev/null <<JEOF
{"metadata":{"name":"oracle","namespace":"bench","uid":"u-oracle-$$","attempt":1},"log_directory":"$D/logs","linux":{}}
JEOF
sudo tee "$D/ctr.json" >/dev/null <<JEOF
{"metadata":{"name":"app"},"image":{"image":"$IMG"},"log_path":"app.log","linux":{}}
JEOF
POD=""; CTR=""
cleanup_oracle() { [ -z "$POD" ] || { CRICTL stopp "$POD" >/dev/null 2>&1; CRICTL rmp -f "$POD" >/dev/null 2>&1; }; sudo rm -rf "$D"; }
trap cleanup_oracle EXIT
POD=$(CRICTL runp "$D/pod.json" 2>/dev/null | tail -1) || true
[ -n "$POD" ] || fail "CRI-O cannot start a pod sandbox"
CTR=$(CRICTL create "$POD" "$D/ctr.json" "$D/pod.json" 2>&1 | tail -1) || true
case "$CTR" in [0-9a-f]???????????????*) ;; *) fail "CRI-O cannot create a container from $IMG: $(echo "$CTR" | cut -c1-200)" ;; esac
CRICTL start "$CTR" >/dev/null 2>&1 || fail "the container did not start"
ST=""
for _ in $(seq 1 20); do
    ST=$(CRICTL inspect "$CTR" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null || true)
    [ "$ST" = "CONTAINER_RUNNING" ] && break
    sleep 1
done
[ "$ST" = "CONTAINER_RUNNING" ] || fail "the container is $ST, not running"
sleep 1
CRICTL inspect "$CTR" 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)["status"]; hexid = sys.argv[1]
assert s.get("imageId", "").replace("sha256:", "") == hexid, "the container runs image %s" % s.get("imageId")
' "$HEX" 2>&1 | tail -1 | grep . && fail "the container does not run the Docker image"
CRICTL logs "$CTR" 2>/dev/null | grep -q "token=$TOKEN" || fail "the log of the container does not show the token of the image"
[ "$(CRICTL exec "$CTR" /app --token 2>/dev/null | tr -d '\r\n')" = "$TOKEN" ] || fail "a command run in the container does not print the token of the image"
echo "  -> OK"
echo "[oracle] CRI-O runs the image that only Docker had: the same image id, from CRI-O's own storage, with Docker's copy left in place."
