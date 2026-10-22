#!/bin/bash
set -e

CASE_ID="bench76136482"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
REG_HOST="hub.registry"
REF="$REG_HOST/team/app:v1"
CRICTL="$LIB/bin/crictl"

fail() { echo "[precondition] FAIL: $*"; exit 1; }
tlog() { sudo cat "$RUN/token.log" 2>/dev/null; }

echo "[precondition] the lab: containerd 2.x with the hosts directory, the registry and its token service, the hosts file without credentials..."
sudo "$LIB/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$LIB/bin/hubctl" status >/dev/null || fail "the registry or the token service is not running"
sudo "$LIB/libexec/containerd" --version | grep -q "v2\.2\." || fail "containerd is not 2.2.x"
grep -q "# $CASE_ID\$" /etc/hosts || fail "/etc/hosts has no line of the lab"
sudo grep -q "config_path = '$LIB/etc/certs.d'" "$LIB/etc/config.toml" || fail "config.toml does not name the hosts directory"
! sudo grep -qE "registry\.configs|registry\.mirrors|identitytoken|^[[:space:]]*(auth|password)[[:space:]]*=" "$LIB/etc/config.toml" || fail "config.toml already holds credentials or mirrors"
! sudo grep -qi "header\|authorization" "$LIB/etc/certs.d/$REG_HOST/hosts.toml" || fail "hosts.toml already has a header"
echo "  containerd $(sudo "$LIB/libexec/containerd" --version | awk '{print $3}'), $(sudo cat "$LIB/etc/certs.d/$REG_HOST/hosts.toml" | grep -c host) host entry in hosts.toml"

echo "[precondition] the pull of the question: 'crictl pull $REF' without credentials fails, and the token service saw it anonymous..."
N0=$(tlog | wc -l)
OUT=$(sudo "$CRICTL" pull "$REF" 2>&1) && fail "an anonymous pull worked: $OUT"
echo "$OUT" | grep -qiE "denied|unauthorized|insufficient_scope|authorization failed|authentication required" || fail "the pull failed with another error: $OUT"
tlog | tail -n +$((N0 + 1)) | python3 -c '
import json
import sys

rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert rows, "no token request"
assert all(r["authorization"] == "none" and r["result"] == "anonymous" for r in rows), rows' || fail "the token service did not see an anonymous request"
echo "  anonymous pull refused: $(echo "$OUT" | tail -1 | cut -c1-200)"

echo "[precondition] control: the same pull with the account given on the command line works (the account is valid; the lab does not leave the image behind)..."
PW=$(sudo python3 -c 'import json; print(json.load(open("'"$LIB"'/account.json"))["password"])')
OUT=$(sudo "$CRICTL" pull --creds "hubuser:$PW" "$REF" 2>&1) || fail "the pull with credentials failed: $OUT"
sudo "$CRICTL" rmi "$REF" >/dev/null 2>&1 || fail "could not remove the image again"
sudo "$CRICTL" images -q | grep -q . && fail "an image is left in the node"
tlog | tail -1 | grep -q '"user": "hubuser"' || fail "the token service did not see the account"
echo "  pull with --creds works; image removed again"

echo "[precondition] OK: containerd has no credentials for $REG_HOST, the account is valid, an anonymous pull is refused"
