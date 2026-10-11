#!/bin/bash
set -e

CASE_ID="bench57009928"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
R=$(cat "$STATE_DIR/rand" 2>/dev/null || true)
EXEC="$RUN_BASE/exec-$R"
CSOCK="$RUN_BASE/ctd-$R/containerd.sock"
ROOT="$EXEC/runtime-runc/moby"

DOCKER=(docker -H "unix://$DSOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] Docker's containerd and Docker run, the helpers are as setup copied them, and both answer..."
[ -n "$R" ] || fail "setup did not record the random names"
for f in containerd dockerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null || true)
    [ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = "$f" ] || fail "the $f of the case is not running"
done
(cd "$STATE_DIR" && sha256sum app.c mkimg.py patch_config.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || fail "ctr does not get an answer on $CSOCK"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker does not get an answer on $DSOCK"
echo "  -> OK: Docker $("${DOCKER[@]}" version -f '{{.Server.Version}}' 2>/dev/null), containerd $(containerd --version | awk '{print $3}'), runc $(runc --version | head -1 | awk '{print $3}')"

echo "[precondition] Docker has two running containers from one image, and the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$DSOCK" "$CSOCK" "$EXEC" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" "$EXEC" "$CSOCK" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import os
import re
import subprocess
import sys

t = json.load(open(sys.argv[1]))
exec_root, csock = sys.argv[2:4]
c = t["containers"]
assert len(c) == 2 and all(re.fullmatch(r"[0-9a-f]{64}", k) for k in c), "two containers with Docker IDs"
assert len({v["pid"] for v in c.values()}) == 2 and all(v["pid"] > 1 for v in c.values()), "two PIDs"

def sudo(*cmd):
    return subprocess.run(["sudo", *cmd], capture_output=True, text=True)    # the exec root is root's


assert t["root"] == exec_root + "/runtime-runc/moby" and sudo("test", "-d", t["root"]).returncode == 0, "the runtime root"
assert sorted(sudo("ls", t["root"]).stdout.split()) == sorted(c), "the runtime root holds the containers"
assert all(sudo("test", "-f", os.path.join(t["root"], k, "state.json")).returncode == 0 for k in c), "state.json"
assert t["socket"] == csock and t["namespace"] == "moby", "socket and namespace"
assert list(t["images"]) == ["docker.io/bench/app:1"] and all(v.startswith("sha256:") for v in t["images"].values()), "one image"
assert re.fullmatch(r"exec-[0-9a-f]{8}", os.path.basename(exec_root)), "random exec root"
PYEOF
echo "  -> OK: runtime root exec-$R/runtime-runc/moby with $(sudo ls "$ROOT" | wc -l) container directories (state.json each); containerd socket ctd-$R/containerd.sock"

echo "[precondition] the problem: runc with its default root lists nothing, nor does the old path of the answer, ctr with the default namespace shows nothing, and runc has no image command..."
[ "$(sudo runc list -q 2>/dev/null | wc -l)" = 0 ] || fail "runc with its default root lists containers"
[ ! -e /run/docker/runtime-runc/moby ] || [ "$(sudo runc --root /run/docker/runtime-runc/moby list -q 2>/dev/null | wc -l)" = 0 ] || fail "the default Docker runtime root of this machine holds containers (a daemon other than the lab's runs here)"
[ -z "$(sudo ctr -a "$CSOCK" containers ls -q 2>/dev/null)" ] || fail "ctr shows containers in the namespace default"
[ -z "$(sudo ctr -a "$CSOCK" images ls -q 2>/dev/null)" ] || fail "ctr shows images in the namespace default"
sudo ctr -a "$CSOCK" namespaces ls -q 2>/dev/null | grep -qx moby || fail "the namespace moby is not listed"
[ "$(sudo ctr -a "$CSOCK" -n moby images ls -q 2>/dev/null | wc -l)" = 1 ] || fail "the namespace moby does not hold the image"
[ "$(sudo runc --root "$ROOT" list -q 2>/dev/null | wc -l)" = 2 ] || fail "runc with the right root does not list the two containers"
[ "$(runc --help 2>&1 | grep -ci image)" = 0 ] || fail "runc has something about images"
[ ! -e "$WORK_DIR/find-runtime.sh" ] || fail "$WORK_DIR/find-runtime.sh exists already"
echo "  -> OK: 'runc list' shows 0 containers, 'runc --root <exec-root>/runtime-runc/moby list' shows 2; 'ctr images ls' (default) shows 0, '-n moby' shows the image; runc has no image command"

echo "[precondition] ALL CHECKS PASSED: Docker runs two containers whose runtime root and containerd socket have random names, nothing is visible with the defaults, and there is no find-runtime.sh."
