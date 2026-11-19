#!/bin/bash
set -e

CASE_ID="bench76379942"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
NEXUS_DIR="$LIB_BASE/nexus"
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
daemon_ok() {   # $1 = nexus|containerd: the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

echo "[precondition] checking the state setup recorded and the two daemons (the Nexus stand-in, containerd)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
for d in nexus containerd; do daemon_ok "$d" || fail "the recorded $d is not running"; done
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
ADDR=$(sj addr); PORT=$(sj port); ENG=$(sj eng_port)
echo "  -> OK"

echo "[precondition] checking Nexus' Docker connector listens on $ADDR:$PORT (plain HTTP) and serves the four images, and nothing listens on port $ENG..."
ip -4 addr show dev lo | grep -qF "$ADDR/" || fail "the address $ADDR is not on this host"
[ "$(code "http://$ADDR:$PORT/v2/")" = "200" ] || fail "the connector does not answer on $ADDR:$PORT"
for k in web webv api apiv; do
    repo=$(sj images.$k.repo); tag=$(sj images.$k.tag)
    [ "$(code -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://$ADDR:$PORT/v2/$repo/manifests/$tag")" = "200" ] || fail "the connector does not serve $repo:$tag"
done
grep -q "^nexus.docker.docker-all.http.port=$PORT\$" "$NEXUS_DIR/etc/nexus.properties" || fail "nexus.properties does not name the connector's port"
! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$ENG\$" || fail "something listens on port $ENG"
echo "  -> OK"

echo "[precondition] checking the engineer's configuration (the mirror of docker.io points at port $ENG) and that the node holds none of the images..."
grep -q "http://$ADDR:$ENG" "$CTD_CONF" || fail "the engineer's mirror is not in the configuration"
! grep -qE '^[[:space:]]*config_path[[:space:]]*=[[:space:]]*"[^"]' "$CTD_CONF" || fail "the configuration already has a config_path"
[ -z "$(CRICTL images -q 2>/dev/null | grep -E 'bench76379942/(web|api)' || true)" ] || fail "the node already holds an image of the case"
echo "  -> OK"

echo "[precondition] checking both names fail: the default one (docker.io/bench76379942/web:1.0, through the mirror and then docker.io itself) never reaches Nexus,"
echo "[precondition] the explicit one is refused at port $ENG; and that the connector speaks HTTP (a plain pull of the real port says so)..."
L0=$(sudo wc -l < "$NEXUS_DIR/requests.log")
OUT=$(CRICTL pull bench76379942/web:1.0 2>&1) && fail "the default name pulled"
echo "$OUT" | grep -qiE 'connection refused|no such host|lookup|not found|denied|unauthorized|dial|timeout' || fail "the pull of the default name failed in an unexpected way: $(echo "$OUT" | tail -1 | cut -c1-200)"
OUT=$(CRICTL pull "$ADDR:$ENG/bench76379942/api:1.0" 2>&1) && fail "the explicit name pulled"
echo "$OUT" | grep -qi 'connection refused' || fail "the explicit name does not fail with 'connection refused': $(echo "$OUT" | tail -1 | cut -c1-200)"
[ "$(sudo wc -l < "$NEXUS_DIR/requests.log")" = "$L0" ] || fail "the failed pulls reached Nexus"
OUT=$(sudo ctr -a "$CTD_SOCK" -n k8s.io images pull "$ADDR:$PORT/bench76379942/web:verify" 2>&1) && fail "a pull without --plain-http worked on the real port"
echo "$OUT" | grep -qiE 'HTTP response to HTTPS client|first record does not look like a TLS handshake' || fail "a pull of the real port failed for another reason: $(echo "$OUT" | tail -1 | cut -c1-200)"
[ -z "$(CRICTL images -q 2>/dev/null | grep -E 'bench76379942/(web|api)' || true)" ] || fail "a failed pull left an image"
echo "  -> OK"
echo "[precondition] the lab is as the task describes: Nexus is reachable on its real port, both names fail, and the port of the names has no listener."
