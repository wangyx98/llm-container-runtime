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
echo "[oracle] check 1: the node's containerd, the registry and the web stand-in are the recorded processes (not stopped, not restarted, not replaced); the node's configuration, the stand-ins' programs and the wrappers are unchanged..."
sudo python3 - "$STATE_DIR/state.json" <<'PYEOF' || exit 1
import hashlib, json, os, sys
d = json.load(open(sys.argv[1]))
for n, (pid, start, exe) in d["daemons"].items():
    try:
        s = open("/proc/%d/stat" % pid).read()
        cur, e = int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)
    except OSError:
        print("  -> FAIL: the %s (pid %d) is gone: it was stopped or restarted" % (n, pid)); sys.exit(1)
    if cur != start or e != exe:
        print("  -> FAIL: pid %d is not the recorded %s any more" % (pid, n)); sys.exit(1)
for f, h in d["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        print("  -> FAIL: %s changed" % f); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 2: the front is still nginx (the case's binary, started with the case's configuration), and the configuration it holds is valid..."
sudo python3 - "$NGX_PORT" "$(st "d['nginx_bin']")" "$(st "d['nginx_conf']")" <<'PYEOF' || exit 1
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
if not pids: print("  -> FAIL: nothing listens on the front port %d" % port); sys.exit(1)
if any(os.readlink("/proc/%s/exe" % p) != binary for p in pids): print("  -> FAIL: what listens on the front port is not %s (the front was replaced)" % binary); sys.exit(1)
if not any((" -c " + conf) in open("/proc/%s/cmdline" % p).read().replace("\0", " ") for p in pids): print("  -> FAIL: nginx does not run with -c %s" % conf); sys.exit(1)
PYEOF
"$WORK_DIR/bin/nginxctl" test >/dev/null 2>&1 || fail "nginx does not accept the configuration on disk"
echo "  -> OK"

echo "[oracle] check 3: through the front, a Docker engine still reaches the Docker repository (its manifest, byte for byte the registry's) and a browser still gets the web application of Nexus..."
MANIFEST=$(st "d['image']['manifest']"); REPO=$(st "d['repo']"); TAG=$(st "d['tag']")
H=$(curl -s -D - -o /dev/null -A "$DOCKER_UA" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://127.0.0.1:$NGX_PORT/v2/$REPO/manifests/$TAG")
echo "$H" | head -1 | grep -q " 200" || fail "a Docker engine's manifest request is not answered with 200 any more: $(echo "$H" | head -1)"
echo "$H" | grep -qi "^docker-content-digest: $MANIFEST" || fail "a Docker engine's manifest request does not get the registry's manifest"
curl -s -A "$BROWSER_UA" "http://127.0.0.1:$NGX_PORT/" | grep -q "nexus-ui-$(st "d['token']")" || fail "a browser does not get the web application of Nexus at / (the route to the web application is gone)"
echo "  -> OK"

echo "[oracle] check 4: the pull step of the job on a COLD node (images and content removed first): it has to succeed, and the registry has to have served the manifest and both blobs to containerd through the front..."
$CTR images ls -q 2>/dev/null | while read -r i; do [ -n "$i" ] && $CTR images rm --sync "$i" >/dev/null 2>&1 || true; done
for _ in $(seq 1 40); do [ "$($CTR content ls -q 2>/dev/null | wc -l)" = "0" ] && break; sleep 0.5; done
[ "$($CTR content ls -q 2>/dev/null | wc -l)" = "0" ] || fail "the oracle could not empty the node's content store"
OFFSET=$(sudo wc -c < "$LIB_BASE/registry/requests.log")
set +e
OUT=$("$WORK_DIR/bin/pull" 2>&1); RC=$?
set -e
[ "$RC" = "0" ] || fail "the pull fails: $(echo "$OUT" | tail -2 | cut -c1-300)"
sudo python3 - "$STATE_DIR/state.json" "$LIB_BASE/registry/requests.log" "$OFFSET" <<'PYEOF' || exit 1
import json, re, sys
d = json.load(open(sys.argv[1])); img = d["image"]
log = open(sys.argv[2]).read().encode()[int(sys.argv[3]):].decode().splitlines()
def served(kind, ref):
    return any(re.match(r"^(GET|HEAD) /v2/%s/%s/%s 200 ua=containerd" % (re.escape(d["repo"]), kind, re.escape(ref)), l) for l in log)
for what, kind, refs in (("the manifest", "manifests", (d["tag"], img["manifest"])), ("the config blob", "blobs", (img["config"],)), ("the layer blob", "blobs", (img["layer"],))):
    if not any(served(kind, r) for r in refs):
        print("  -> FAIL: the registry's log shows no 200 for %s to a containerd client since the pull started" % what); sys.exit(1)
if not any(re.match(r"^GET /v2/%s/blobs/%s 200" % (re.escape(d["repo"]), re.escape(img["layer"])), l) for l in log):
    print("  -> FAIL: the layer was not fetched"); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 5: the node holds exactly the registry's image (image id = config digest, repo digest = manifest digest of the front's name)..."
sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" inspecti "$(st "d['ref']")" 2>/dev/null | python3 -c '
import json, sys
j = json.load(sys.stdin); s = j["status"]
want_id, want_rd = sys.argv[1], sys.argv[2] + "@" + sys.argv[3]
if s["id"] != want_id: print("  -> FAIL: the image id is %s, the registry has %s" % (s["id"], want_id)); sys.exit(1)
if want_rd not in s.get("repoDigests", []): print("  -> FAIL: no repo digest %s (has %s)" % (want_rd, s.get("repoDigests"))); sys.exit(1)
' "$(st "d['image']['config']")" "127.0.0.1:$NGX_PORT/$REPO" "$MANIFEST" || exit 1
echo "  -> OK"
echo "[oracle] ALL CHECKS PASSED"
