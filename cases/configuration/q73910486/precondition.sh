#!/bin/bash
set -e

CASE_ID="bench73910486"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
REG_DIR="$LIB_BASE/registry"
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
daemon_ok() {   # $1 = registry|containerd: the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }
ACC='Accept: application/vnd.docker.distribution.manifest.v2+json'

echo "[precondition] checking the state setup recorded and the two daemons (the registry, containerd)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
for d in registry containerd; do daemon_ok "$d" || fail "the recorded $d is not running"; done
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
ADDR=$(sj addr); PORT=$(sj port); USER=$(sj user); PASS=$(sj password); REPO=$(sj repo); HOSTS=$(sj hosts_dir)
HOST="$ADDR:$PORT"
echo "  -> OK"

echo "[precondition] checking the registry at $HOST needs the account: without it /v2/ and the images answer 401, with it they are served..."
ip -4 addr show dev lo | grep -qF "$ADDR/" || fail "the address $ADDR is not on this host"
[ "$(code "http://$HOST/v2/")" = "401" ] || fail "the registry answers /v2/ without an account"
for tag in latest verify; do
    [ "$(code -H "$ACC" "http://$HOST/v2/$REPO/manifests/$tag")" = "401" ] || fail "the registry serves $REPO:$tag without an account"
    [ "$(code -u "$USER:$PASS" -H "$ACC" "http://$HOST/v2/$REPO/manifests/$tag")" = "200" ] || fail "the registry does not serve $REPO:$tag to the account"
done
echo "  -> OK"

echo "[precondition] checking the node: the registry's hosts.toml of the thread (plain HTTP server, pull and resolve) holds no credential, nothing gives crictl an account,"
echo "[precondition] and the node holds none of the images..."
H="$HOSTS/$HOST/hosts.toml"
grep -q "server = \"http://$HOST\"" "$H" || fail "the registry's hosts.toml is not the one of the thread"
! grep -qiE 'authorization|auth|password|identitytoken|bearer' "$H" || fail "the hosts.toml already holds a credential"
[ ! -e /etc/crictl.yaml ] || ! sudo grep -qiE 'auth|password|creds' /etc/crictl.yaml || fail "crictl's own configuration holds a credential"
[ -z "$(CRICTL images -q 2>/dev/null | grep -F "$REPO" || true)" ] || fail "the node already holds an image of the case"
echo "  -> OK"

echo "[precondition] reproducing the question: crictl pull WITHOUT account or password of an image of the authenticated registry succeeds, and the registry's log shows"
echo "[precondition] containerd answering the 401 with an account of its own..."
L0=$(sudo wc -l < "$REG_DIR/requests.log")
OUT=$(CRICTL pull "$HOST/$REPO:latest" 2>&1) || fail "the pull without credentials failed (the question's pull succeeds): $(echo "$OUT" | tail -1 | cut -c1-200)"
ID=$(sj images.latest.config)
CRICTL inspecti "$HOST/$REPO:latest" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d["status"]["id"] == sys.argv[1] else 1)' "$ID" || fail "the pulled image is not the image of the registry"
NEW=$(sudo tail -n +$((L0 + 1)) "$REG_DIR/requests.log")
echo "$NEW" | grep -E '^(HEAD|GET) .*/manifests/' | grep -q ' 401 .*auth=none' || fail "the registry's log has no 401 for the first, anonymous request of containerd"
echo "$NEW" | grep -E '^(HEAD|GET) .*/manifests/' | grep -q ' 200 ua=containerd/.*auth=ok' || fail "the registry's log shows no authenticated manifest request of containerd"
CRICTL rmi "$HOST/$REPO:latest" >/dev/null 2>&1 || fail "could not remove the image again"
[ -z "$(CRICTL images -q 2>/dev/null | grep -F "$REPO" || true)" ] || fail "the node still holds the image"
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the registry needs an account, and the node pulls from it without one."
