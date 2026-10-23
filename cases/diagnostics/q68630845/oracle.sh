#!/bin/bash
# Oracle: the node pulls the image through the CRI, cold, from the registry, with the deploy token, and runs it - and nothing was weakened to get there. Everything is measured here:
#  - the lab's files (the registry and its data, the web application, the certificates and keys, the node's programs, the pod's definitions) are unchanged; the registry and the web application are the processes
#    setup started; the node's containerd is the lab's 1.6.17; the machine's trust store is as before;
#  - the node's effective settings (crictl info): no verification is skipped, every mirror endpoint of the registry is https on the registry's own address WITH its port (or there is no mirror);
#  - cold pull: pods and the project's images are removed, then `crictl pull` with the deploy token succeeds and the image's repoDigest is the recorded manifest digest; the registry's log shows the node
#    asking the manifest by tag and then by that digest (200), and its blobs; the web application's log shows of that pull nothing but the token requests of the registry's realm (Basic with the deploy token, 200)
#    and no /v2/ request and no sign-in page;
#  - run: a pod and the container of the image start (hostNetwork), the container's log has the per-run token baked into the image;
#  - authentication still counts: cold pulls with a wrong password and without credentials fail and leave no image, and the registry gives its manifest to nobody without a token.

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
fail() { echo "[oracle] FAIL: $*"; exit 1; }
cr() { sudo timeout -k 3 120 "$CRICTL" --timeout 90s "$@"; }
cleanup_pods() { sudo timeout -k 3 90 "$CRICTL" --timeout 60s rmp -f -a >/dev/null 2>&1 || true; }
remove_images() { for i in $(sudo "$CRICTL" images 2>/dev/null | awk -v p="$HP/$REPO" '$1==p {print $3}'); do cr rmi "$i" >/dev/null 2>&1; done; }
trap cleanup_pods EXIT

echo "[oracle] the lab's files, the registry, the web application, the node's containerd and the machine's trust store..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
for p in web registry; do
    PID=$(sudo cat "$RUN/$p.pid" 2>/dev/null)
    [ -n "$PID" ] && [ "$PID" = "$(sudo cat "$STATE_DIR/$p.pid")" ] && [ "$(sudo readlink "/proc/$PID/exe")" = "$(sudo cat "$STATE_DIR/$p.exe")" ] || fail "the $p process is not the one setup started"
done
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$CRICTL" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the node's containerd is not v1.6.17"
if [ -s "$STATE_DIR/systemca.sha" ]; then sudo sh -c "sha256sum -c --quiet '$STATE_DIR/systemca.sha'" >/dev/null 2>&1 || fail "the machine's trust store (/etc/ssl/certs/ca-certificates.crt) was changed"; fi

echo "[oracle] the settings the node has in effect (crictl info)..."
sudo "$CRICTL" info 2>/dev/null | python3 -I -c "
import json, sys
from urllib.parse import urlsplit
r = json.load(sys.stdin)['config']['registry']
problems = []
for h, c in r['configs'].items():
    if c.get('tls', {}).get('insecure_skip_verify'):
        problems.append('the verification of %s is skipped' % h)
for e in r['mirrors'].get('$HP', {}).get('endpoint', []):
    u = urlsplit(e)
    if u.scheme != 'https' or u.hostname != '$ADDR':
        problems.append('the mirror endpoint %r is not https on $ADDR' % e)
open('$WORK_DIR/config_path.txt', 'w').write(r.get('configPath', ''))
print('; '.join(problems))
sys.exit(1 if problems else 0)" 2>&1 || fail "the node's registry settings are weakened or point elsewhere"
CP=$(cat "$WORK_DIR/config_path.txt" 2>/dev/null); rm -f "$WORK_DIR/config_path.txt"
if [ -n "$CP" ] && [ -d "$CP" ]; then
    ! sudo grep -rIEq 'skip_verify[[:space:]]*=[[:space:]]*true|"http://|server[[:space:]]*=[[:space:]]*"http://' "$CP" || fail "a registry configuration file under $CP skips the verification or uses plain http"
fi

echo "[oracle] cold pull through the CRI with the deploy token..."
cleanup_pods
remove_images
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the image could not be removed from the node for the cold pull"
WMARK=$(sudo wc -l < "$RUN/web.log"); RMARK=$(sudo wc -l < "$RUN/registry.log")
OUT=$(cr pull --creds "$CREDS" "$IMAGE" 2>&1) || fail "the pull fails: $(echo "$OUT" | tail -1 | cut -c1-350)"
MD=$(sudo cat "$STATE_DIR/manifest.digest")
sudo "$CRICTL" inspecti "$IMAGE" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if '$HP/$REPO@$MD' in d['status']['repoDigests'] else 1)" || fail "the pulled image is not the one of the registry (digest $MD)"
sudo tail -n +$((RMARK + 1)) "$RUN/registry.log" | python3 -I -c "
import re, sys
acc = [re.match(r'^\S+ - - \[[^]]*\] \"(\S+) (\S+) [^\"]*\" (\d+) \d+ \"[^\"]*\" \"(containerd/[^\"]*)\"', l) for l in sys.stdin]
acc = [(m.group(1), m.group(2), int(m.group(3))) for m in acc if m]
for m, p in (('HEAD', '/v2/$REPO/manifests/v1'), ('GET', '/v2/$REPO/manifests/$MD')):
    assert (m, p, 200) in acc, 'the registry did not serve %s %s to the node: %r' % (m, p, acc)
assert any(m == 'GET' and '/blobs/sha256:' in p and s == 200 for m, p, s in acc), 'no blob was served to the node'
" 2>&1 || fail "the registry's log does not show the node pulling the image"
sudo tail -n +$((WMARK + 1)) "$RUN/web.log" | python3 -I -c "
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
node = [r for r in rows if r.get('ua', '').startswith('containerd/')]
assert any(r['path'].startswith('/jwt/auth?') and r['method'] == 'GET' and r['auth'] == 'basic-ok' and r['status'] == 200 for r in node), 'the node did not get a token with the deploy token'
bad = [(r['method'], r['path']) for r in node if r['path'].startswith('/v2/') or r['path'].startswith('/users/')]
assert not bad, 'the node went to the web application for: %r' % bad
" 2>&1 || fail "the web application's log shows more than the token requests of the node"

echo "[oracle] run: a pod and the container of the image..."
POD=$(cr runp "$LIB/pods/pod.json" 2>&1 | tail -1)
[ ${#POD} = 64 ] || fail "the pod does not start: $POD"
CID=$(cr create "$POD" "$LIB/pods/ctr.json" "$LIB/pods/pod.json" 2>&1 | tail -1)
[ ${#CID} = 64 ] || fail "the container is not created: $CID"
cr start "$CID" >/dev/null 2>&1 || fail "the container does not start"
TOKEN=$(sudo cat "$STATE_DIR/token")
ok=0
for _ in $(seq 20); do
    cr logs "$CID" 2>/dev/null | grep -q "bench68630845 $TOKEN" && { ok=1; break; }
    sleep 1
done
[ "$ok" = 1 ] || fail "the container does not print the token of the image"
cleanup_pods

echo "[oracle] authentication still counts: a wrong password, and no credentials..."
remove_images
if OUT=$(cr pull --creds "gitlab+deploy-token-1:wrong" "$IMAGE" 2>&1); then fail "the pull succeeds with a wrong password"; fi
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the image is in the node after a pull with a wrong password"
if OUT=$(cr pull "$IMAGE" 2>&1); then fail "the pull succeeds without credentials"; fi
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the image is in the node after a pull without credentials"
[ "$(curl -s --max-time 10 --cacert "$LIB/pki/ca.crt" -o /dev/null -w '%{http_code}' "https://$HP/v2/$REPO/manifests/v1")" = 401 ] || fail "the registry gives its manifest to a client without a token"

echo "[oracle] PASS: the node pulls $IMAGE cold from the registry (digest $MD, the deploy token's token from the web application, the registry's own responses), runs it, and authentication and verification were not weakened."
