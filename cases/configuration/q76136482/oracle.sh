#!/bin/bash
set -e

CASE_ID="bench76136482"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
REG_HOST="hub.registry"
AUTH_HOST="auth.hub.registry"
NS="bench76136482"
CRICTL="$LIB/bin/crictl"
CTR="$LIB/bin/ctr"
TAG="n$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
REF="$REG_HOST/team/app:$TAG"
case "$(uname -m)" in x86_64) KARCH="amd64" ;; *) KARCH="arm64" ;; esac

fail() { echo "[oracle] FAIL: $*"; exit 1; }
tlog() { sudo cat "$RUN/token.log" 2>/dev/null; }
rlog() { sudo cat "$RUN/registry.log" 2>/dev/null; }

echo "[oracle] the lab is as it was: containerd 2.2.x and its configuration, the registry and its token service (files, account), only the hosts file of $REG_HOST changed..."
sudo "$LIB/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$LIB/bin/hubctl" status >/dev/null || fail "the registry or the token service is not running"
sudo "$LIB/libexec/containerd" --version | grep -q "v2\.2\.3" || fail "containerd is not 2.2.3"
grep -q "# $CASE_ID\$" /etc/hosts || fail "the /etc/hosts line of the lab is gone"
( cd "$LIB" && sudo sha256sum -c --quiet "$STATE_DIR/lab.sha" ) >/dev/null 2>&1 || fail "containerd's configuration, the registry's configuration, the token service or the account was changed"
FILES=$(sudo find "$LIB/etc/certs.d" -type f | sort)
[ "$FILES" = "$LIB/etc/certs.d/$REG_HOST/hosts.toml" ] || fail "the hosts directory holds other files than hosts.toml of $REG_HOST: $(echo $FILES)"
HT=$(sudo cat "$LIB/etc/certs.d/$REG_HOST/hosts.toml")
URLS=$(echo "$HT" | grep -oE "https?://[^\"' ]+" | sort -u)
[ "$URLS" = "http://$REG_HOST" ] || fail "hosts.toml names a server or a mirror other than http://$REG_HOST: $(echo $URLS)"
[ "$(echo "$HT" | grep -cE '^[[:space:]]*\[host\."[^"]+"\][[:space:]]*$')" = 1 ] || fail "hosts.toml must keep exactly one host entry"
echo "$HT" | grep -qiE '^[[:space:]]*server[[:space:]]*=[[:space:]]*"http://'"$REG_HOST"'"' || fail "the server line of hosts.toml was changed"
echo "  containerd 2.2.3 with its configuration untouched, the registry and the token service untouched, one host entry (http://$REG_HOST) in hosts.toml"

echo "[oracle] the registry still refuses an anonymous reader: a token without credentials has no access to team/app..."
sudo python3 - "$AUTH_HOST" "$REG_HOST" <<'PYEOF' || fail "an anonymous reader gets in: the token service or the registry no longer needs the account"
import json
import sys
import urllib.error
import urllib.request

auth, reg = sys.argv[1:3]
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
tok = json.load(op.open("http://%s:5001/token?service=%s&scope=repository:team/app:pull" % (auth, reg), timeout=20))["token"]
req = urllib.request.Request("http://%s/v2/team/app/manifests/v1" % reg, headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"})
try:
    op.open(req, timeout=20)
except urllib.error.HTTPError as e:
    sys.exit(0 if e.code in (401, 403) else 1)
sys.exit(1)
PYEOF
echo "  anonymous token: no access, manifest 401"

echo "[oracle] a NEW image (new tag, new digest) is pushed with the account; the lab keeps no copy of it in the node..."
PW=$(sudo python3 -c 'import json; print(json.load(open("'"$LIB"'/account.json"))["password"])')
sudo python3 "$STATE_DIR/mkarchive.py" "$WORK_DIR/new.tar" "$REF" "oracle-$TAG" "$KARCH"
sudo "$CTR" -n "$NS" images import "$WORK_DIR/new.tar" >/dev/null || fail "could not import the new image"
DIGEST=$(sudo "$CTR" -n "$NS" images ls "name==$REF" | awk 'NR==2 {print $3}')
[ -n "$DIGEST" ] || fail "no digest for the new image"
sudo "$CTR" -n "$NS" images push --plain-http --user "hubuser:$PW" "$REF" >/dev/null 2>&1 || fail "could not push the new image"
sudo "$CTR" -n "$NS" images rm --sync "$REF" >/dev/null
sudo rm -f "$WORK_DIR/new.tar"
sudo "$CTR" -n k8s.io images ls -q | grep -q ":$TAG\$" && fail "the node has the new image already"
sudo "$CTR" content ls -q | grep -q "$DIGEST" && fail "the node still has the content of the new image"
echo "  pushed $REF ($DIGEST); not in the node"

echo "[oracle] 'crictl pull $REF' WITHOUT credentials works..."
T0=$(tlog | wc -l); R0=$(rlog | wc -l)
OUT=$(sudo "$CRICTL" pull "$REF" 2>&1) || fail "the pull without credentials failed: $(echo "$OUT" | tail -1 | cut -c1-300)"
sudo "$CRICTL" inspecti "$REF" 2>/dev/null | grep -q "$DIGEST" || fail "the node does not hold the image with the digest $DIGEST after the pull"
echo "  pulled: $(echo "$OUT" | tail -1)"

echo "[oracle] the token service saw the account at its token endpoint and the registry served the image to it..."
tlog | tail -n +$((T0 + 1)) | python3 -c '
import json
import sys

rows = [json.loads(l) for l in sys.stdin if l.strip()]
ok = [r for r in rows if r["authorization"] == "Basic" and r["user"] == "hubuser" and r["result"] == "granted" and any("team/app:pull" in s for s in r["scope"])]
assert ok, "no authenticated token request for the pull: %s" % rows
assert not [r for r in rows if r["result"] == "denied"], "a token request with wrong credentials: %s" % rows' || fail "the token log does not show an authenticated pull"
rlog | tail -n +$((R0 + 1)) | python3 -c '
import re
import sys

tag, digest = sys.argv[1:3]
seen = set()
for line in sys.stdin:
    m = re.search(r"\"(GET|HEAD) (/v2/team/app/(manifests|blobs)/\S+) HTTP/1.1\" (\d+) ", line)
    if m and m.group(4) == "200":
        if m.group(3) == "manifests" and m.group(2).endswith("/" + tag):
            seen.add("tag")
        if m.group(3) == "manifests" and m.group(2).endswith("/" + digest):
            seen.add("manifest")
        if m.group(3) == "blobs":
            seen.add("blob")
    if "authorized request" in line and "auth.user.name=hubuser" in line and "/manifests/" + tag in line:
        seen.add("auth")
sys.exit(0 if seen == {"tag", "manifest", "blob", "auth"} else 1)' "$TAG" "$DIGEST" || fail "the registry log does not show the tag, the manifest and the blobs of the image served to the account"
echo "  token endpoint: Basic, user hubuser, granted; registry: manifest and blobs 200, authorized as hubuser"

echo "[oracle] cleaning the node of the new image..."
sudo "$CRICTL" rmi "$REF" >/dev/null 2>&1 || true

echo "[oracle] PASS: a pull without credentials works through containerd's hosts directory only (no deprecated registry config, no mirror, no secret), the registry still refuses anonymous readers"
