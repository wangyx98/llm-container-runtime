#!/bin/bash
# Postcondition oracle. Every check is dynamic: the functions' images are removed from containerd and the functions are deployed again through the provider's API (the
# deployment the thread attempts), then called through the provider; the registry's log tells how containerd authenticated to the registry.
set -e

CASE_ID="bench64540738"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
REG_DIR="$LIB_BASE/registry"
CTD_SOCK="$RUN_BASE/ctd/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FAASD_BIN="/usr/local/bin/faasd"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CTR() { sudo ctr -a "$CTD_SOCK" -n openfaas-fn "$@" 2>/dev/null; }
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }
newlog() { sudo tail -n +"$(( ${1} + 1 ))" "$REG_DIR/requests.log"; }
pidstart() { sudo awk '{print $22}' "/proc/$1/stat" 2>/dev/null | tr -d ')'; }
alive() { [ -n "$1" ] && [ -d "/proc/$1" ] && ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status" 2>/dev/null; }

ADDR=$(sj addr); PORT=$(sj port); USER=$(sj user); PASS=$(sj password); REPO=$(sj repo); PW=$(sudo cat /var/lib/faasd/secrets/basic-auth-password)
HOST="$ADDR:$PORT"; CA="$LIB_BASE/certs/ca.pem"; API="http://127.0.0.1:8081"
REPOQ=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$REPO")

echo "[oracle] check 1: the lab is the one of setup: the registry is the recorded process and keeps its files, account and content (nothing was written to it) and still needs the"
echo "[oracle] account, with the challenge it had; containerd runs from its configuration file; faasd's provider runs from $FAASD_BIN in the namespace of the daemons..."
rp=$(sj daemons/registry | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])'); rs=$(sj daemons/registry | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')
alive "$rp" && [ "$(pidstart "$rp")" = "$rs" ] || fail "the registry of setup is not running"
sudo python3 - "$STATE_DIR/state.json" "$REG_DIR/state.json" <<'PYEOF' || fail "a file of the lab was changed (see above)"
import hashlib, json, sys
d = json.load(open(sys.argv[1])); bad = []
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for f, h in d["files"].items():
    try:
        if sha(f) != h: bad.append(f)
    except OSError: bad.append(f)
if sha(sys.argv[2]) != d["registry_state"]: bad.append("the registry's content")
if bad: print("changed: " + ", ".join(bad)); sys.exit(1)
PYEOF
if newlog "$(sj registry_lines)" | grep -qE '^(PUT|PATCH|DELETE|POST /v2/)'; then fail "something wrote to the registry"; fi
H=$(curl -s -D - -o /dev/null --max-time 5 --cacert "$CA" "https://$HOST/v2/$REPO/manifests/1.0" | tr -d '\r')
echo "$H" | head -1 | grep -q ' 401' || fail "the registry does not answer an anonymous manifest request with 401 any more: it must keep requiring a token of the account"
echo "$H" | grep -i '^www-authenticate:' | grep -qi 'scope' && fail "the registry's challenge names a scope now: the registry must stay as it is"
[ "$(code --cacert "$CA" "https://$HOST/token?service=bench-registry&scope=repository:$REPO:pull")" = "401" ] || fail "the token service gives a token without the account"
if sudo iptables-save -t nat 2>/dev/null | grep -qE "$ADDR|dport $PORT"; then fail "a NAT rule redirects traffic of the registry's address or port"; fi
cp=$(pgrep -x containerd | while read -r p; do sudo tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF -- "--config $CTD_CONF" && echo "$p"; done | head -1)
[ -n "$cp" ] || fail "the containerd that answers is not the one started from $CTD_CONF"
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
pp=$(pgrep -x faasd | while read -r p; do sudo tr '\0' ' ' < "/proc/$p/cmdline" | grep -q 'faasd provider' && echo "$p"; done | head -1)
[ -n "$pp" ] || fail "faasd's provider is not running"
[ "$(sudo readlink "/proc/$pp/exe")" = "$FAASD_BIN" ] || fail "the running provider is not the program at $FAASD_BIN (it is $(sudo readlink "/proc/$pp/exe"))"
hp=$(sj daemons/holder | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
[ "$(sudo readlink "/proc/$pp/ns/mnt")" = "$(sudo readlink "/proc/$hp/ns/mnt")" ] && [ "$(sudo readlink "/proc/$cp/ns/mnt")" = "$(sudo readlink "/proc/$hp/ns/mnt")" ] \
    || fail "the provider and containerd do not run in the mount namespace of the daemons (start them with faasdctl)"
[ "$(code -u "admin:$PW" "$API/system/functions")" = "200" ] || fail "the provider's API does not answer"
echo "  -> OK"

L1=$(sudo wc -l < "$REG_DIR/requests.log")
NAMES=""
cleanup_oracle() {
    local n
    for n in $NAMES; do curl -s --max-time 30 -o /dev/null -u "admin:$PW" -X DELETE -H 'Content-Type: application/json' -d "{\"functionName\":\"$n\"}" "$API/system/functions" || true; done
}
trap cleanup_oracle EXIT

deploy_check() {   # $1 = tag, $2 = function name: remove the image from containerd, deploy it through the API, call it, and read the registry's log
    local tag="$1" name="$2" ref="$HOST/$REPO:$1" tok man cfg lay n0 body out st i
    tok=$(sj images/$tag/token); man=$(sj images/$tag/manifest); cfg=$(sj images/$tag/config); lay=$(sj images/$tag/layer)
    NAMES="$NAMES $name"
    curl -s --max-time 60 -o /dev/null -u "admin:$PW" -X DELETE -H 'Content-Type: application/json' -d "{\"functionName\":\"$name\"}" "$API/system/functions" || true
    CTR images rm --sync "$ref" >/dev/null || true
    [ -z "$(CTR images ls -q | grep -F "$REPO:$tag" || true)" ] || fail "could not remove $ref from containerd before the deployment"
    n0=$(sudo wc -l < "$REG_DIR/requests.log")
    body=$(printf '{"service":"%s","image":"%s","registryAuth":"%s"}' "$name" "$ref" "$(printf '%s:%s' "$USER" "$PASS" | base64 -w0)")
    out=$(curl -s --max-time 120 -w '\nHTTP %{http_code}' -u "admin:$PW" -H 'Content-Type: application/json' -d "$body" "$API/system/functions")
    case "$(echo "$out" | tail -1)" in "HTTP 2"??) ;; *) fail "the deployment of $ref is refused: $(echo "$out" | tr '\n' ' ' | grep -oE 'HTTP [0-9]+|(failed to [a-z ]+|no scope specified|unauthorized|denied|not found)[^"]{0,90}' | head -2 | tr '\n' ' ')" ;; esac
    st=""
    for i in $(seq 1 40); do
        st=$(curl -s --max-time 5 -u "admin:$PW" "$API/function/$name" || true)
        echo "$st" | grep -q "bench64540738-fn-ok token=" && break
        sleep 1
    done
    echo "$st" | grep -q "bench64540738-fn-ok token=$tok\$" || fail "the function $name (deployed from $ref) does not answer with the token of the image (it answers: $(echo "$st" | head -c 80))"
    [ "$(CTR containers info "$name" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Image"])' 2>/dev/null)" = "$ref" ] || fail "the container $name was not created from $ref"
    newlog "$n0" | grep -E '^GET /token\?' | grep -E "ua=containerd/.* auth=basic-ok scope=repository:$REPO:pull\$" >/dev/null \
        || fail "the registry's log has no token request of containerd with the account for the scope repository:$REPO:pull"
    for want in "manifests/$tag" "manifests/$man" "blobs/$cfg" "blobs/$lay"; do
        newlog "$n0" | grep -E "^(GET|HEAD) /v2/$REPO/$want 200 ua=containerd/.*auth=bearer-ok" >/dev/null || fail "the registry did not see containerd fetch $REPO/$want with a token of the account"
    done
}

echo "[oracle] check 2: the image $REPO:1.0 is removed from containerd and deployed through the provider's API, with the registry login in the body as faas-cli sends it (the deployment"
echo "[oracle] of the thread): the deployment must succeed, the function must answer with the token of the image, and the registry's log must show containerd asking the token"
echo "[oracle] service with the account for the scope of the repository and then fetching the manifest and both blobs with the token..."
deploy_check 1.0 bench64540738-o1
echo "  -> OK"

echo "[oracle] check 3: the same for the second tag of the repository (verify), deployed as a second function..."
deploy_check verify bench64540738-o2
echo "  -> OK"

echo "[oracle] check 4: the registry still stands as setup left it after all of this (nothing written, same content), and its account is still required..."
if newlog "$L1" | grep -qE '^(PUT|PATCH|DELETE|POST /v2/)'; then fail "something wrote to the registry"; fi
sudo python3 - "$STATE_DIR/state.json" "$REG_DIR/state.json" <<'PYEOF' || fail "the registry's content changed"
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest() == d["registry_state"] else 1)
PYEOF
[ "$(code --cacert "$CA" "https://$HOST/v2/$REPO/manifests/verify")" = "401" ] || fail "the registry serves an image without a token of the account"
echo "  -> OK"
echo "[oracle] faasd's provider deploys from the private registry with the account's token flow; the registry is as it was."
