#!/bin/bash
set -e

CASE_ID="bench76836830"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NGX_PORT=18076; REG_PORT=15076
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_UA='docker/27.5.1 go/go1.22.10 git-commit/9f9e405 kernel/5.15.0 os/linux arch/arm64 UpstreamClient(Docker-Client/27.5.1 \(linux\))'
BROWSER_UA='Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0'

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"

sudo test -s "$STATE_DIR/state.json" || fail "setup's record is missing"
echo "[precondition] the node's containerd, the registry and the web stand-in are the recorded processes; the node's configuration, the stand-ins' programs and the wrappers are unchanged..."
sudo python3 - "$STATE_DIR/state.json" <<'PYEOF' || fail "a daemon is gone or replaced, or a recorded file changed"
import hashlib, json, os, sys
d = json.load(open(sys.argv[1]))
for n, (pid, start, exe) in d["daemons"].items():
    try:
        s = open("/proc/%d/stat" % pid).read()
        cur, e = int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)
    except OSError:
        print("the %s (pid %d) is gone" % (n, pid)); sys.exit(1)
    if cur != start or e != exe:
        print("pid %d is not the recorded %s" % (pid, n)); sys.exit(1)
for f, h in d["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        print("%s changed" % f); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the node holds no image and no content (a pull is a cold pull); the registry has the image..."
[ "$($CTR images ls -q 2>/dev/null | wc -l)" = "0" ] || fail "the node already holds an image"
[ "$($CTR content ls -q 2>/dev/null | wc -l)" = "0" ] || fail "the node already holds content"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:$REG_PORT/v2/$(st "d['repo']")/manifests/$(st "d['tag']")")" = "200" ] || fail "the registry does not serve the image"
echo "  -> OK"

echo "[precondition] the front is nginx (the case's binary and configuration) and routes by User-Agent: a Docker engine reaches the Docker repository, a browser the web application, and a containerd request is not routed to the Docker repository..."
sudo python3 - "$NGX_PORT" "$(st "d['nginx_bin']")" "$(st "d['nginx_conf']")" <<'PYEOF' || fail "what listens on the front port is not the case's nginx"
import os, sys
port, binary, conf = int(sys.argv[1]), sys.argv[2], sys.argv[3]
inodes = {l.split()[9] for l in open("/proc/net/tcp").read().splitlines()[1:] if l.split()[3] == "0A" and l.split()[1].endswith(":%04X" % port)}
pids = set()
for p in filter(str.isdigit, os.listdir("/proc")):
    try:
        for fd in os.listdir("/proc/%s/fd" % p):
            t = os.readlink("/proc/%s/fd/%s" % (p, fd))
            if t.startswith("socket:[") and t[8:-1] in inodes: pids.add(p)
    except OSError:
        pass
if not pids: print("nothing listens on the front port"); sys.exit(1)
if any(os.readlink("/proc/%s/exe" % p) != binary for p in pids): print("a listener is not %s" % binary); sys.exit(1)
if not any((" -c " + conf) in open("/proc/%s/cmdline" % p).read().replace("\0", " ") for p in pids): print("no listener runs with -c %s" % conf); sys.exit(1)
PYEOF
"$WORK_DIR/bin/nginxctl" test >/dev/null 2>&1 || fail "nginx does not accept its configuration"
[ "$(curl -s -o /dev/null -w '%{http_code}' -A "$DOCKER_UA" "http://127.0.0.1:$NGX_PORT/v2/")" = "200" ] || fail "a Docker engine's request does not reach the Docker repository"
curl -s -A "$BROWSER_UA" "http://127.0.0.1:$NGX_PORT/" | grep -q "nexus-ui-$(st "d['token']")" || fail "a browser does not reach the web application"
[ "$(curl -s -o /dev/null -w '%{http_code}' -A 'containerd/v2.0.0' "http://127.0.0.1:$NGX_PORT/v2/")" != "200" ] || fail "a containerd request already reaches the Docker repository"
echo "  -> OK"

echo "[precondition] the symptom of the question: the node's pull (CRI PullImage through the front) fails, and the registry sees nothing of it..."
BEFORE=$(sudo grep -c 'ua=containerd' "$LIB_BASE/registry/requests.log" || true)
set +e
OUT=$("$WORK_DIR/bin/pull" 2>&1); RC=$?
set -e
[ "$RC" != "0" ] || fail "the pull works already"
echo "$OUT" | grep -q "failed to pull and unpack image" || fail "the pull did not fail the way a pull does: $(echo "$OUT" | tail -2 | cut -c1-200)"
echo "$OUT" | grep -q "not found" || fail "the pull did not end with 'not found': $(echo "$OUT" | tail -2 | cut -c1-200)"
[ "$(sudo grep -c 'ua=containerd' "$LIB_BASE/registry/requests.log" || true)" = "$BEFORE" ] || fail "the registry saw the failing pull"
[ "$($CTR images ls -q 2>/dev/null | wc -l)" = "0" ] || fail "the failing pull left an image"
echo "  -> OK (\"not found\": containerd's requests are answered by the web application of the stand-in, the registry never sees them)"
echo "[precondition] all checks passed."
