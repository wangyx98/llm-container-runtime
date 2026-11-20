#!/bin/bash
set -e

CASE_ID="bench64540738"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
REG_DIR="$LIB_BASE/registry"
CTD_SOCK="$RUN_BASE/ctd/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FAASD_BIN="/usr/local/bin/faasd"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CTR() { sudo ctr -a "$CTD_SOCK" -n openfaas-fn "$@" 2>/dev/null; }
daemon_ok() {   # $1 = registry|containerd|provider|holder: the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe _ < <(sj "daemons/$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }

echo "[precondition] checking the state setup recorded and the four processes (the registry, containerd, faasd's provider, the holder of their mount namespace)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
for d in registry containerd provider holder; do daemon_ok "$d" || fail "the recorded $d is not running"; done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
ADDR=$(sj addr); PORT=$(sj port); USER=$(sj user); PASS=$(sj password); REPO=$(sj repo); APASS=$(sj admin_password)
HOST="$ADDR:$PORT"; CA="$LIB_BASE/certs/ca.pem"
echo "  -> OK"

echo "[precondition] checking faasd as the thread has it: the provider is release $(sj v_old) ($FAASD_BIN, the running binary too), the newer release is staged but not installed, and"
echo "[precondition] there is no registry credential file for faasd..."
[ "$(sha256sum "$FAASD_BIN" | cut -d' ' -f1)" = "$(sj old_sha)" ] || fail "$FAASD_BIN is not the recorded release"
pp=$(sj daemons/provider | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
[ "$(sudo sha256sum "/proc/$pp/exe" | cut -d' ' -f1)" = "$(sj old_sha)" ] || fail "the running provider is not the recorded release"
[ "$(sha256sum "$LIB_BASE/releases/faasd-$(sj v_new)" | cut -d' ' -f1)" = "$(sj new_sha)" ] || fail "the staged release is not the recorded one"
[ ! -e /var/lib/faasd/.docker/config.json ] || fail "faasd already has a docker config file"
PW=$(sudo cat /var/lib/faasd/secrets/basic-auth-password)
[ "$(code -u "admin:$PW" http://127.0.0.1:8081/system/functions)" = "200" ] || fail "the provider's API does not answer"
[ "$(curl -s --max-time 5 -u "admin:$PW" http://127.0.0.1:8081/system/functions | tr -d ' \n')" = "[]" ] || fail "the provider already holds functions"
[ -z "$(CTR images ls -q)" ] || fail "containerd already holds images of the case"
echo "  -> OK"

echo "[precondition] checking the registry at $HOST: HTTPS with the lab CA, the challenge of an anonymous request names the token service but no scope, the token service wants"
echo "[precondition] the account, and the images are there..."
ip -4 addr show dev lo | grep -qF "$ADDR/" || fail "the address $ADDR is not on this host"
H=$(curl -s -D - -o /dev/null --max-time 5 --cacert "$CA" "https://$HOST/v2/$REPO/manifests/1.0" | tr -d '\r')
echo "$H" | head -1 | grep -q ' 401' || fail "the registry does not answer an anonymous manifest request with 401"
echo "$H" | grep -i '^www-authenticate:' | grep -qi '^www-authenticate: *bearer realm="https://[^"]*/token",service="[^"]*"$' || fail "the registry's challenge is not 'Bearer realm=...,service=...' without a scope: $(echo "$H" | grep -i '^www-authenticate' | cut -c1-200)"
[ "$(code --cacert "$CA" "https://$HOST/token?service=bench-registry&scope=repository:$REPO:pull")" = "401" ] || fail "the token service gives a token without the account"
[ "$(code --cacert "$CA" -u "$USER:$PASS" "https://$HOST/token?service=bench-registry&scope=repository:$REPO:pull")" = "200" ] || fail "the token service does not give the account a token"
for tag in 1.0 verify; do
    T=$(curl -s --max-time 5 --cacert "$CA" -u "$USER:$PASS" "https://$HOST/token?service=bench-registry&scope=repository:$REPO:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    [ "$(code --cacert "$CA" -H "Authorization: Bearer $T" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "https://$HOST/v2/$REPO/manifests/$tag")" = "200" ] || fail "the registry does not serve $REPO:$tag to a token of the account"
done
echo "  -> OK"

echo "[precondition] reproducing the thread: deploying an image of the registry through the provider's API, with the registry login in the body (as faas-cli sends it), is refused with"
echo "[precondition] 'no scope specified for token auth challenge', and the registry's log shows containerd's first request, anonymous, and no token request..."
L0=$(sudo wc -l < "$REG_DIR/requests.log")
BODY=$(printf '{"service":"bench64540738-pre","image":"%s/%s:1.0","registryAuth":"%s"}' "$HOST" "$REPO" "$(printf '%s:%s' "$USER" "$PASS" | base64 -w0)")
OUT=$(curl -s --max-time 120 -w '\nHTTP %{http_code}' -u "admin:$PW" -H 'Content-Type: application/json' -d "$BODY" http://127.0.0.1:8081/system/functions)
echo "$OUT" | tail -1 | grep -q 'HTTP 400' || fail "the deployment is not refused with HTTP 400: $(echo "$OUT" | tail -2 | cut -c1-250 | tr '\n' ' ')"
echo "$OUT" | grep -q 'no scope specified for token auth challenge' || fail "the refusal is not the thread's: $(echo "$OUT" | head -1 | cut -c1-250)"
NEW=$(sudo tail -n +$((L0 + 1)) "$REG_DIR/requests.log")
echo "$NEW" | grep -E '^(HEAD|GET) /v2/.*/manifests/1\.0 401 ua=containerd/.* auth=none' >/dev/null || fail "the registry's log has no anonymous, refused manifest request of containerd"
! echo "$NEW" | grep -q '/token' || fail "containerd asked the token service although the challenge named no scope"
[ "$(curl -s --max-time 5 -u "admin:$PW" http://127.0.0.1:8081/system/functions | tr -d ' \n')" = "[]" ] || fail "the refused deployment left a function"
[ -z "$(CTR containers ls -q)" ] || fail "the refused deployment left a container"
echo "  -> OK"
echo "[precondition] the lab is as the thread describes: the registry needs an account, and the deployment through faasd's provider fails with the scope error."
