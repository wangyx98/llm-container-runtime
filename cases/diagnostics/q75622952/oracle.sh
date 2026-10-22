#!/bin/bash
# Oracle: the node pulls the image from the registry through the CRI, cold, and runs it - and nothing was weakened to get there. Everything is measured here, not taken from what the solution says:
#  - the lab's files (the front, the certificates, the image data, the node's programs, the pod's definitions) are unchanged, the front is the process setup started, the node's containerd is the 1.6.17 of the
#    lab, the machine's own trust store is as before;
#  - the node's effective settings (crictl info): every mirror endpoint of the registry is https on the registry's own address, the verification is not skipped;
#  - cold pull: pods and the image are removed, then `crictl pull` of the image succeeds and its repoDigest is the recorded manifest digest; the front's log of that pull shows the node asking
#    /v2/k8mtest/k8m/manifests/v1.0 (HEAD) and .../manifests/<digest> (GET) with a Bearer token (200) after a token request with the account (Basic, 200), and no answer of the pull was text/html or an unverified TLS handshake;
#  - run: a pod and the container of the image start (hostNetwork), and the container's log has the per-run token that is baked in the image;
#  - verification still counts: with the front showing its second certificate (same name, a CA nobody trusts) a cold pull must fail with "certificate signed by unknown authority";
#  - authentication still counts: the registry gives the manifest to an anonymous client no more.

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
fail() { echo "[oracle] FAIL: $*"; exit 1; }
cr() { sudo timeout -k 3 120 "$CRICTL" --timeout 90s "$@"; }
cleanup_pods() { sudo timeout -k 3 90 "$CRICTL" --timeout 60s rmp -f -a >/dev/null 2>&1 || true; }
trap 'sudo sh -c "echo lab > \"$RUN/front.mode\"" 2>/dev/null; cleanup_pods' EXIT

echo "[oracle] the lab's files, the registry front, the node's containerd and the machine's trust store..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
FPID=$(sudo cat "$RUN/front.pid" 2>/dev/null)
[ -n "$FPID" ] && [ "$FPID" = "$(sudo cat "$STATE_DIR/front.pid")" ] && [ "$(sudo readlink "/proc/$FPID/exe")" = "$(sudo cat "$STATE_DIR/front.exe")" ] || fail "the registry front is not the process setup started"
[ "$(sudo cat "$RUN/front.mode" 2>/dev/null)" = lab ] || fail "the front's certificate was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$CRICTL" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the node's containerd is not v1.6.17"
if [ -s "$STATE_DIR/systemca.sha" ]; then sudo sh -c "sha256sum -c --quiet '$STATE_DIR/systemca.sha'" >/dev/null 2>&1 || fail "the machine's trust store (/etc/ssl/certs/ca-certificates.crt) was changed"; fi

echo "[oracle] the settings the node has in effect (crictl info)..."
sudo "$CRICTL" info 2>/dev/null | python3 -c "
import json, sys
from urllib.parse import urlsplit
r = json.load(sys.stdin)['config']['registry']
hp = '$HP'
for h, c in r['configs'].items():
    assert c['tls']['insecure_skip_verify'] is False, 'the verification of %s is skipped' % h
eps = r['mirrors'].get(hp, {}).get('endpoint', [])
for e in eps:
    u = urlsplit(e)
    assert u.scheme == 'https' and u.netloc == hp, 'the mirror endpoint %r is not https on %s' % (e, hp)
" 2>&1 || fail "the node's registry settings are weakened or point elsewhere"

echo "[oracle] cold pull through the CRI..."
cleanup_pods
for i in $(sudo "$CRICTL" images 2>/dev/null | awk -v p="$HP/k8mtest/k8m" '$1==p {print $3}'); do cr rmi "$i" >/dev/null 2>&1; done
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the image could not be removed from the node for the cold pull"
MARK=$(sudo wc -l < "$LOG")
OUT=$(cr pull "$IMAGE" 2>&1) || fail "the pull fails: $(echo "$OUT" | tail -1 | cut -c1-350)"
MD=$(sudo cat "$STATE_DIR/manifest.digest")
sudo "$CRICTL" inspecti "$IMAGE" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if '$HP/k8mtest/k8m@$MD' in d['status']['repoDigests'] else 1)" || fail "the pulled image is not the one of the registry (digest $MD)"
sudo tail -n +$((MARK + 1)) "$LOG" | python3 -c "
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
assert not any(r.get('tls') == 'failed' for r in rows), 'a TLS handshake with the front failed'
node = [r for r in rows if r.get('ua', '').startswith('containerd/')]
assert node, 'the front saw no request of the node'
assert not any(r['ctype'].startswith('text/html') for r in node), 'the node was given text/html: %r' % [r['path'] for r in node if r['ctype'].startswith('text/html')]
tok = [r for r in node if r['path'].startswith('/service/token') and r['method'] == 'GET']
assert any(r['auth'] == 'basic-ok' and r['status'] == 200 for r in tok), 'the node did not get a token with the account'
for m, p in (('HEAD', '/v2/k8mtest/k8m/manifests/v1.0'), ('GET', '/v2/k8mtest/k8m/manifests/$MD')):
    assert any(r['method'] == m and r['path'] == p and r['status'] == 200 and r['auth'] == 'bearer-ok' for r in node), 'no %s %s with a token' % (m, p)
" 2>&1 || fail "the registry's log does not show a normal authenticated pull"

echo "[oracle] run: a pod and the container of the image..."
POD=$(cr runp "$LIB/pods/pod.json" 2>&1 | tail -1)
[ ${#POD} = 64 ] || fail "the pod does not start: $POD"
CID=$(cr create "$POD" "$LIB/pods/ctr.json" "$LIB/pods/pod.json" 2>&1 | tail -1)
[ ${#CID} = 64 ] || fail "the container is not created: $CID"
cr start "$CID" >/dev/null 2>&1 || fail "the container does not start"
TOKEN=$(sudo cat "$STATE_DIR/token")
ok=0
for _ in $(seq 20); do
    cr logs "$CID" 2>/dev/null | grep -q "bench75622952 $TOKEN" && { ok=1; break; }
    sleep 1
done
[ "$ok" = 1 ] || fail "the container does not print the token of the image"
cleanup_pods

echo "[oracle] the certificate is still verified (the front shows a certificate of a CA nobody trusts)..."
sudo sh -c "echo rogue > '$RUN/front.mode'"
for i in $(sudo "$CRICTL" images 2>/dev/null | awk -v p="$HP/k8mtest/k8m" '$1==p {print $3}'); do cr rmi "$i" >/dev/null 2>&1; done
if OUT=$(cr pull "$IMAGE" 2>&1); then fail "the pull succeeds against a certificate that nothing trusts: the verification is gone"; fi
echo "$OUT" | grep -q "certificate signed by unknown authority" || fail "the pull against the untrusted certificate fails, but not on the certificate: $(echo "$OUT" | tail -1 | cut -c1-300)"
! sudo "$CRICTL" inspecti "$IMAGE" >/dev/null 2>&1 || fail "the image is in the node after a failed pull"
sudo sh -c "echo lab > '$RUN/front.mode'"

echo "[oracle] the registry still asks for authentication..."
[ "$(curl -s --max-time 10 --cacert "$LIB/pki/ca.crt" -o /dev/null -w '%{http_code}' "https://$HP/v2/k8mtest/k8m/manifests/v1.0")" = 401 ] || fail "the registry gives its manifest to an anonymous client"

echo "[oracle] PASS: the node pulls $IMAGE cold (digest $MD, token and account used, certificate verified), runs it, and the registry and the trust were not weakened."
