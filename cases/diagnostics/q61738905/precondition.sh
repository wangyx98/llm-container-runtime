#!/bin/bash
set -e

CASE_ID="bench61738905"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
R=$(cat "$STATE_DIR/rand" 2>/dev/null || true)
EXEC="$RUN_BASE/exec-$R"
ROOT="$EXEC/runtime-runc/moby"

DOCKER=(docker -H "unix://$DSOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] Docker's containerd and Docker run, the helpers are as setup copied them, and Docker answers..."
[ -n "$R" ] || fail "setup did not record the random name"
for f in containerd dockerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null || true)
    [ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = "$f" ] || fail "the $f of the case is not running"
done
(cd "$STATE_DIR" && sha256sum app.c mkimg.py patch_config.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker does not get an answer on $DSOCK"
echo "  -> OK: Docker $("${DOCKER[@]}" version -f '{{.Server.Version}}' 2>/dev/null), runc $(runc --version | head -1 | awk '{print $3}')"

echo "[precondition] the daemon's command line has only the socket and a configuration file (no --exec-root, no --runtime-root); the exec root is in the file, with a random name..."
P=$(sudo cat "$RUN_BASE/dockerd.pid")
CMD=$(sudo tr '\0' ' ' < "/proc/$P/cmdline")
case "$CMD" in *"--config-file $LIB_BASE/etc/daemon.json"*) ;; *) fail "the daemon was not started with the configuration file: $CMD" ;; esac
case "$CMD" in *exec-root*|*runtime-root*) fail "the command line of the daemon names a root: $CMD" ;; esac
for pid in $(pgrep -x 'dockerd|containerd|containerd-shim-runc-v2' 2>/dev/null); do     # by process name: the command line of a shell that happens to contain the word proves nothing
    ! sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- '-runtime-root' || fail "the process $pid names a runtime root on its command line"
done
grep -q "\"exec-root\": \"$EXEC\"" "$LIB_BASE/etc/daemon.json" || fail "the configuration file does not hold the exec root"
echo "  -> OK: $(echo "$CMD" | sed 's/ *$//' | cut -c1-160)"

echo "[precondition] Docker has two running containers; the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$DSOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" "$EXEC" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import os
import re
import sys

t = json.load(open(sys.argv[1]))
c = t["containers"]
assert len(c) == 2 and all(re.fullmatch(r"[0-9a-f]{64}", k) for k in c), "two containers with Docker IDs"
assert len({v["pid"] for v in c.values()}) == 2 and all(v["pid"] > 1 for v in c.values()), "two PIDs"
assert t["root"] == sys.argv[2] + "/runtime-runc/moby", "the runtime root"
assert re.fullmatch(r"exec-[0-9a-f]{8}", os.path.basename(sys.argv[2])), "random exec root"
PYEOF
echo "  -> OK"

echo "[precondition] the problem: runc with its default root lists nothing, nor does the root Docker usually has; runc with Docker's root lists the two containers, with the PIDs Docker gives..."
[ "$(sudo runc list -q 2>/dev/null | wc -l)" = 0 ] || fail "runc with its default root lists containers"
[ ! -e /run/docker/runtime-runc/moby ] || [ "$(sudo runc --root /run/docker/runtime-runc/moby list -q 2>/dev/null | wc -l)" = 0 ] || fail "the usual Docker runtime root of this machine holds containers (a daemon other than the lab's runs here)"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "runc with Docker's root does not list what Docker runs"
import json
import subprocess
import sys

t = json.load(open(sys.argv[1]))
r = subprocess.run(["sudo", "runc", "--root", t["root"], "list", "--format", "json"], capture_output=True, text=True, check=True)
got = {c["id"]: (c["pid"], c["status"]) for c in json.loads(r.stdout)}
assert got == {k: (v["pid"], "running") for k, v in t["containers"].items()}, got
PYEOF
[ ! -e "$WORK_DIR/find-runc-root.sh" ] || fail "$WORK_DIR/find-runc-root.sh exists already"
echo "  -> OK: 'runc list' shows 0 containers; 'runc --root <exec-root>/runtime-runc/moby list' shows the 2 containers with Docker's PIDs"

echo "[precondition] ALL CHECKS PASSED: Docker runs two containers whose runtime root has a random name that only its configuration file holds, nothing is visible with the defaults, and there is no find-runc-root.sh."
