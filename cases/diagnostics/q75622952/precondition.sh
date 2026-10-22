#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there, measured at the registry's side and at the node's:
#  - the lab's files are unchanged, the registry front is the process setup started and is listening, the node's containerd is the 1.6.17 of the lab and has no image of the registry;
#  - the node's effective registry settings are the question's: a CA file, no skipping of the verification, the account admin, and a mirror whose endpoint is "https://<registry>/" (with the slash);
#  - the registry itself is fine (curl with the lab's CA): /v2/ asks for a Bearer token (401), the token service gives one for the account, the manifest of the image is served with the token under the
#    right digest; a path outside /v2/ is the portal page ("200 text/html"); a client that does not trust the certificate (the front's second certificate) cannot talk to it;
#  - the CRI pull fails with the question's message, "unexpected media type text/html for sha256:<digest>", and the digest in it is the digest of the portal page; the front's log shows what the node asked:
#    HEAD and GET of a manifest path WITHOUT /v2 (and without authorization), answered with 200 and text/html.

CASE_ID="bench75622952"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ADDR="10.75.62.29"
HP="$ADDR:8443"
IMAGE="$HP/k8mtest/k8m:v1.0"
CRICTL="$LIB/bin/crictl"
LOG="$RUN/front.log"
fail() { echo "[precondition] FAIL: $*"; sudo sh -c "echo lab > '$RUN/front.mode'" 2>/dev/null; exit 1; }

echo "[precondition] the lab's files, the registry front and the node's containerd..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
FPID=$(sudo cat "$RUN/front.pid" 2>/dev/null)
[ -n "$FPID" ] && [ "$FPID" = "$(sudo cat "$STATE_DIR/front.pid")" ] && [ "$(sudo readlink "/proc/$FPID/exe")" = "$(sudo cat "$STATE_DIR/front.exe")" ] || fail "the registry front is not the process setup started"
sudo python3 -c "
import os, sys
inode = None
for l in open('/proc/net/tcp').readlines()[1:]:
    f = l.split()
    if f[3] == '0A' and f[1].endswith(':%04X' % 8443):
        inode = f[9]
sys.exit(0 if inode and any(os.path.exists('/proc/$FPID/fd/' + d) and os.readlink('/proc/$FPID/fd/' + d) == 'socket:[%s]' % inode for d in os.listdir('/proc/$FPID/fd')) else 1)" || fail "the registry front does not listen on port 8443"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$CRICTL" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the node's containerd is not v1.6.17"
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the node already has the image"

echo "[precondition] the registry settings the node has in effect (crictl info)..."
sudo "$CRICTL" info 2>/dev/null | python3 -c "
import json, sys
r = json.load(sys.stdin)['config']['registry']
hp = '$HP'
c = r['configs'][hp]
assert c['tls']['caFile'] == '$LIB/pki/ca.crt' and c['tls']['insecure_skip_verify'] is False, 'tls'
assert c['auth']['username'] == 'admin' and c['auth']['password'] == 'Harbor12345', 'auth'
assert r['mirrors'][hp]['endpoint'] == ['https://' + hp + '/'], 'mirror endpoint %r' % r['mirrors'][hp]['endpoint']
" 2>&1 || fail "the node's registry settings are not the question's"

echo "[precondition] the registry itself, with the lab's CA..."
CURL=(curl -s --max-time 10 --cacert "$LIB/pki/ca.crt")
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$HP/v2/")" = 401 ] || fail "/v2/ does not answer 401 to an anonymous client"
"${CURL[@]}" -D - -o /dev/null "https://$HP/v2/" | grep -qi '^www-authenticate: Bearer realm="https://'"$HP"'/service/token"' || fail "/v2/ does not offer a Bearer token service"
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u admin:wrong "https://$HP/service/token?service=harbor-registry&scope=repository:k8mtest/k8m:pull")" = 401 ] || fail "the token service accepts a wrong password"
TOK=$("${CURL[@]}" -u admin:Harbor12345 "https://$HP/service/token?service=harbor-registry&scope=repository:k8mtest/k8m:pull" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
[ -n "$TOK" ] || fail "the token service gives no token"
MD=$(sudo cat "$STATE_DIR/manifest.digest")
"${CURL[@]}" -D - -o /dev/null -H "Authorization: Bearer $TOK" "https://$HP/v2/k8mtest/k8m/manifests/v1.0" | tr -d '\r' | grep -qi "^docker-content-digest: $MD$" || fail "the registry does not serve the manifest under the recorded digest"
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$HP/v2/k8mtest/k8m/manifests/v1.0")" = 401 ] || fail "an anonymous client can read the manifest"
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code} %{content_type}' "https://$HP/k8mtest/k8m/manifests/v1.0")" = "200 text/html" ] || fail "a path outside /v2/ is not the portal page"
sudo sh -c "echo rogue > '$RUN/front.mode'"
if "${CURL[@]}" -o /dev/null "https://$HP/v2/" 2>/dev/null; then fail "a client that trusts only the lab's CA talks to the front's second certificate"; fi
sudo sh -c "echo lab > '$RUN/front.mode'"

echo "[precondition] the node pulls the image: the question's error..."
MARK=$(sudo wc -l < "$LOG")
OUT=$(sudo timeout -k 3 90 "$CRICTL" --timeout 60s pull "$IMAGE" 2>&1)
echo "$OUT" | grep -q 'failed to unpack image on snapshotter overlayfs: unexpected media type text/html for sha256:' || fail "the pull does not fail with the question's error: $(echo "$OUT" | tail -1 | cut -c1-300)"
PD=$(sudo cat "$STATE_DIR/portal.digest")
echo "$OUT" | grep -q "unexpected media type text/html for $PD: not found" || fail "the digest in the error is not the digest of the portal page ($PD)"
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the failed pull left an image"
sudo tail -n +$((MARK + 1)) "$LOG" | python3 -c "
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
node = [r for r in rows if r.get('ua', '').startswith('containerd/')]
assert node, 'the front saw no request of the node'
assert all(not r['path'].startswith('/v2/') for r in node), 'the node asked below /v2/: %r' % [r['path'] for r in node]
m = [r for r in node if r['path'] == '/k8mtest/k8m/manifests/v1.0']
assert {r['method'] for r in m} >= {'HEAD', 'GET'}, 'no HEAD and GET of the manifest path'
assert all(r['status'] == 200 and r['ctype'] == 'text/html' and r['auth'] == 'none' for r in m), 'the answers were %r' % [(r['status'], r['ctype'], r['auth']) for r in m]
" 2>&1 || fail "the front's log does not show the node asking a path without /v2 and getting the portal page"

echo "[precondition] OK: the registry is fine (token, manifest, certificate checked), the node asks 'https://$HP/k8mtest/k8m/manifests/v1.0' without /v2 and is given the portal page as the manifest."
