#!/bin/bash
set -e

CASE_ID="bench55103653"
CID="bench55103653-sub"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
ROOTFS="$BUNDLE/rootfs"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT="$WORK_DIR/capture_output.py"
JENKINS="$WORK_DIR/as_jenkins.sh"

fail() { echo "  -> FAIL: $*"; exit 1; }
TOKEN=$(sudo cat "$STATE_DIR/token" 2>/dev/null) || fail "setup did not record the token"

echo "[precondition] checking the bundle: runc's default config (\"terminal\": true), the program as process, the"
echo "[precondition] recorded program in the rootfs, no container of that id yet..."
[ -f "$BUNDLE/config.json" ] && [ -x "$ROOTFS/app" ] || fail "bundle or program missing"
[ "$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["process"]["terminal"])' "$BUNDLE/config.json")" = "True" ] \
    || fail "config.json has not \"terminal\": true"
[ "$(sudo sha256sum "$ROOTFS/app" | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/app.sha256")" ] || fail "the program in the rootfs is not the recorded one"
[ -z "$(sudo runc list -q 2>/dev/null | grep -Fx "$CID")" ] || fail "a container $CID already exists"
[ -x "$SCRIPT" ] && [ -x "$JENKINS" ] || fail "the script or as_jenkins.sh is missing"
echo "  -> OK"

echo "[precondition] checking the script works in a terminal (a pty is its controlling terminal, as when the engineer"
echo "[precondition] runs it by hand): the lines of the container are captured..."
OUT=$(sudo python3 - "$SCRIPT" <<'PYEOF'
import os
import pty
import sys

pid, fd = pty.fork()             # the child is a session leader whose controlling terminal is the pty
if pid == 0:
    os.execvp("python3", ["python3", sys.argv[1]])
data = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
os.waitpid(pid, 0)
sys.stdout.write(data.decode(errors="replace"))
PYEOF
) || true
echo "$OUT" | grep -qF "sub-msg 2 token=$TOKEN" || fail "even in a terminal the script does not capture the lines of the container: $(echo "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-200)"
sudo runc list -q 2>/dev/null | grep -Fxq "$CID" && fail "the container is still there after the run in the terminal"
echo "  -> OK"

echo "[precondition] checking the script does NOT work the way Jenkins runs it (no controlling terminal): the"
echo "[precondition] captured stdout has none of the lines of the container..."
set +e
OUT=$(timeout -k 5 60 "$JENKINS" 2>&1)
RC=$?
set -e
echo "$OUT" | grep -qF "token=$TOKEN" && fail "as Jenkins runs it the script already captures the lines"
echo "$OUT" | grep -q "Subscriber stdout:" || fail "the script did not even print its headings ($(echo "$OUT" | head -2 | tr '\n' ' '))"
sudo runc list -q 2>/dev/null | grep -Fxq "$CID" && fail "the container is still there after the run as Jenkins"
echo "  -> OK (exit code $RC: $(echo "$OUT" | grep -m1 -E 'level=error' | sed 's/.*msg=//' | cut -c1-120))"

echo "[precondition] all conditions met."
