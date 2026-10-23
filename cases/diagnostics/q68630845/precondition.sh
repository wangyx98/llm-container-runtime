#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there, measured on the registry's side, on the web application's side and on the node's:
#  - the lab's files are unchanged; the registry (the real distribution 2.8.3) and the web application's stand-in are the processes setup started and listen on 5050 and 443; the node's containerd is the
#    lab's 1.6.17 and has no image of the project;
#  - the node's effective registry settings are the question's: the CA for the host and for the host with the port, verification on, and a mirror of "<host>:5050" whose endpoint is "https://<host>" (no port);
#  - the registry is fine: anonymous /v2/ asks for a token (the realm is the web application's /jwt/auth), the deploy token gets one for the project's repository, the manifest is served under the recorded digest
#    with it and is refused without it; the web application answers a /v2/ path of the registry with a redirect to a sign-in page that differs at every request; and `ctr images pull` (the question's "ctr works")
#    pulls the image with the CA and the deploy token and is removed again;
#  - the CRI pull fails with the question's message, `failed commit on ref "unknown-sha256:D1": unexpected commit digest sha256:D2, expected sha256:D1`; D1 and D2 are the sha256 of two different sign-in pages
#    that the web application's log shows it served to the node (the manifest request first, then the request for D1 as a blob), and the registry's log shows nothing of this pull.

CASE_ID="bench68630845"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ADDR="10.68.63.45"
HP="$ADDR:5050"
REPO="lab-user/webapp/nginx"
IMAGE="$HP/$REPO:v1"
CRICTL="$LIB/bin/crictl"
CREDS="gitlab+deploy-token-1:k8s-pull-secret"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
listens() {   # $1 = pid, $2 = port: the process has the listening socket of that port
    sudo python3 -I - "$1" "$2" <<'PYEOF'
import os, sys
pid, port = sys.argv[1], int(sys.argv[2])
inodes = {f[9] for l in open("/proc/net/tcp").readlines()[1:] for f in [l.split()] if f[3] == "0A" and f[1].endswith(":%04X" % port)}
fds = ["/proc/%s/fd/%s" % (pid, d) for d in os.listdir("/proc/%s/fd" % pid)]
sys.exit(0 if any(os.path.islink(p) and os.readlink(p) in {"socket:[%s]" % i for i in inodes} for p in fds) else 1)
PYEOF
}

echo "[precondition] the lab's files, the registry, the web application and the node's containerd..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
for p in web registry; do
    PID=$(sudo cat "$RUN/$p.pid" 2>/dev/null)
    [ -n "$PID" ] && [ "$PID" = "$(sudo cat "$STATE_DIR/$p.pid")" ] && [ "$(sudo readlink "/proc/$PID/exe")" = "$(sudo cat "$STATE_DIR/$p.exe")" ] || fail "the $p process is not the one setup started"
done
listens "$(sudo cat "$RUN/web.pid")" 443 || fail "the web application does not listen on port 443"
listens "$(sudo cat "$RUN/registry.pid")" 5050 || fail "the registry does not listen on port 5050"
"$LIB/registry/registry" --version | grep -q "2.8.3" || fail "the registry is not 2.8.3"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$CRICTL" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the node's containerd is not v1.6.17"
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the node already has the image"

echo "[precondition] the registry settings the node has in effect (crictl info)..."
sudo "$CRICTL" info 2>/dev/null | python3 -c "
import json, sys
r = json.load(sys.stdin)['config']['registry']
for h in ('$ADDR', '$HP'):
    c = r['configs'][h]
    assert c['tls']['caFile'] == '$LIB/pki/ca.crt' and c['tls']['insecure_skip_verify'] is False, 'tls of ' + h
assert r['mirrors']['$HP']['endpoint'] == ['https://$ADDR'], 'mirror endpoint %r' % r['mirrors']['$HP']['endpoint']
" 2>&1 || fail "the node's registry settings are not the question's"

echo "[precondition] the registry and the web application, with the lab's CA..."
CURL=(curl -s --max-time 10 --cacert "$LIB/pki/ca.crt")
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$HP/v2/")" = 401 ] || fail "/v2/ does not answer 401 to an anonymous client"
"${CURL[@]}" -D - -o /dev/null "https://$HP/v2/" | tr -d '\r' | grep -qi '^www-authenticate: Bearer realm="https://'"$ADDR"'/jwt/auth",service="container_registry"' || fail "the registry does not point to the web application's token service"
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -u "gitlab+deploy-token-1:wrong" "https://$ADDR/jwt/auth?service=container_registry&scope=repository:$REPO:pull")" = 401 ] || fail "the token service accepts a wrong password"
TOK=$("${CURL[@]}" -u "$CREDS" "https://$ADDR/jwt/auth?service=container_registry&scope=repository:$REPO:pull" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
[ -n "$TOK" ] || fail "the token service gives no token for the deploy token"
MD=$(sudo cat "$STATE_DIR/manifest.digest")
"${CURL[@]}" -D - -o /dev/null -I -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.oci.image.manifest.v1+json" "https://$HP/v2/$REPO/manifests/v1" | tr -d '\r' | grep -qi "^docker-content-digest: $MD$" || fail "the registry does not serve the manifest under the recorded digest with the token"
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$HP/v2/$REPO/manifests/v1")" = 401 ] || fail "an anonymous client can read the manifest"
ANON=$("${CURL[@]}" "https://$ADDR/jwt/auth?service=container_registry&scope=repository:$REPO:pull" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
[ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ANON" "https://$HP/v2/$REPO/manifests/v1")" = 401 ] || fail "an anonymous token reads the manifest"
P1=$("${CURL[@]}" -L -w ' %{http_code} %{content_type}' "https://$ADDR/v2/$REPO/manifests/v1" | sha256sum | cut -c1-64)
P2=$("${CURL[@]}" -L -w ' %{http_code} %{content_type}' "https://$ADDR/v2/$REPO/manifests/v1" | sha256sum | cut -c1-64)
[ "$("${CURL[@]}" -L -o /dev/null -w '%{http_code} %{content_type}' "https://$ADDR/v2/$REPO/manifests/v1")" = "200 text/html; charset=utf-8" ] && [ "$P1" != "$P2" ] || fail "the web application does not answer a /v2/ path with a sign-in page that differs at every request"
echo "[precondition] the question's ctr pull (the CA and the deploy token) works..."
sudo "$LIB/bin/ctr" -n precond images pull --tlscacert "$LIB/pki/ca.crt" --user "$CREDS" "$IMAGE" >/dev/null 2>&1 || fail "ctr cannot pull the image from the registry with the deploy token"
[ "$(sudo "$LIB/bin/ctr" -n precond images ls -q | grep -c "^$IMAGE$")" = 1 ] && sudo "$LIB/bin/ctr" -n precond images ls | grep -q "$IMAGE.*$MD" || fail "ctr did not pull the recorded image"
sudo "$LIB/bin/ctr" -n precond images rm --sync "$IMAGE" >/dev/null 2>&1
for _ in $(seq 20); do [ -z "$(sudo "$LIB/bin/ctr" -n precond content ls -q)" ] && break; sleep 0.5; done
[ -z "$(sudo "$LIB/bin/ctr" -n precond content ls -q)" ] || fail "the content of the ctr pull is still in the store"

echo "[precondition] the node pulls the image through the CRI: the question's error..."
WMARK=$(sudo wc -l < "$RUN/web.log"); RMARK=$(sudo wc -l < "$RUN/registry.log")
OUT=$(sudo timeout -k 3 90 "$CRICTL" --timeout 60s pull --creds "$CREDS" "$IMAGE" 2>&1)
printf '%s' "$OUT" | python3 -I -c '
import re, sys
m = re.search("unknown-sha256:([0-9a-f]{64}).{1,6}: unexpected commit digest sha256:([0-9a-f]{64}), expected sha256:([0-9a-f]{64}): failed precondition", sys.stdin.read())
assert m and m.group(1) == m.group(3) and m.group(1) != m.group(2), "no match"
print(m.group(1), m.group(2))' > "$WORK_DIR/digests.txt" 2>/dev/null || fail "the pull does not fail with the question's message: $(echo "$OUT" | tail -1 | cut -c1-300)"
read -r D1 D2 < "$WORK_DIR/digests.txt"; rm -f "$WORK_DIR/digests.txt"
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the failed pull left an image"
sudo tail -n +$((WMARK + 1)) "$RUN/web.log" | python3 -I -c "
import json, sys
d1, d2 = sys.argv[1:3]
rows = [json.loads(l) for l in sys.stdin if l.strip()]
node = [r for r in rows if r.get('ua', '').startswith('containerd/')]
repo = '/v2/$REPO/'
asked = [(r['method'], r['path'].split('?')[0], r['status']) for r in node]
assert ('HEAD', repo + 'manifests/v1', 302) in asked and ('GET', repo + 'manifests/v1', 302) in asked, 'no manifest request redirected: %r' % asked
assert ('GET', repo + 'blobs/sha256:' + d1, 302) in asked, 'D1 was not asked for as a blob: %r' % asked
pages = [r['sha'] for r in node if r['path'] == '/users/sign_in' and r['status'] == 200 and r['method'] == 'GET']
assert pages and pages[0] == 'sha256:' + d1, 'the first page the node got is not D1'
assert pages[-1] == 'sha256:' + d2 and d1 != d2, 'the last page the node got is not D2'
assert not any(r['path'].startswith('/jwt/auth') and r['auth'] == 'basic-ok' for r in node), 'the node fetched a token'
" "$D1" "$D2" 2>&1 || fail "the web application's log does not show the node getting two different sign-in pages (D1 $D1, D2 $D2) in place of the manifest"
! sudo tail -n +$((RMARK + 1)) "$RUN/registry.log" | grep -q "containerd/" || fail "the registry saw the node's request: the pull did not go to the web application"

echo "[precondition] OK: the registry is fine (token, manifest, ctr pull), and the node's pull fails with 'unexpected commit digest' because its mirror endpoint sends it to the web application on port 443, which gives a sign-in page that is different at every request."
