#!/bin/bash
# Postcondition oracle. The script of the case is RUN, the way Jenkins runs it (as root, in a session without a
# controlling terminal, stdin from /dev/null), while runc is watched; what it prints is then compared line by
# line with what the program of the container writes (the per-run token is only inside that program).
set -e

CASE_ID="bench55103653"
CID="bench55103653-sub"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
ROOTFS="$BUNDLE/rootfs"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT="$WORK_DIR/capture_output.py"
RES_DIR=$(mktemp -d)
trap 'rm -rf "$RES_DIR"' EXIT

# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }
TOKEN=$(sudo cat "$STATE_DIR/token")

echo "[oracle] check 1: the program of the container and its command are the ones of setup (nothing is faked by"
echo "[oracle] replacing them), and the script is still where the Jenkins job runs it..."
[ "$(sudo sha256sum "$ROOTFS/app" 2>/dev/null | awk '{print $1}')" = "$(sudo cat "$STATE_DIR/app.sha256")" ] \
    || fail "the program in $ROOTFS/app was replaced"
[ "$(sudo python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["process"]["args"]))' "$BUNDLE/config.json" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/args.json")" ] \
    || fail "the command of the container in config.json was changed"
[ -f "$SCRIPT" ] || fail "the script $SCRIPT is gone"
sudo runc list -q 2>/dev/null | grep -Fxq "$CID" && fail "a container $CID is already there before the run"
echo "  -> OK"

echo "[oracle] check 2: run the script as Jenkins does, watching runc: a container $CID of this bundle must appear..."
sudo setsid -w python3 "$SCRIPT" </dev/null >"$RES_DIR/out" 2>"$RES_DIR/err" &
SPID=$!
SEEN=""
for _ in $(seq 1 200); do      # up to 40 s
    kill -0 "$SPID" 2>/dev/null || break
    if sudo runc list -f json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin) or []
except ValueError:
    rows = []
sys.exit(0 if any(r.get("id") == sys.argv[1] and r.get("bundle") == sys.argv[2] for r in rows) else 1)' "$CID" "$BUNDLE"; then
        SEEN=yes
    fi
    sleep 0.2
done
if kill -0 "$SPID" 2>/dev/null; then
    sudo pkill -KILL -x python3 -P "$SPID" 2>/dev/null || true
    sudo runc delete -f "$CID" >/dev/null 2>&1 || true
    fail "the script did not finish within 40 s"
fi
RC=0; wait "$SPID" || RC=$?
if [ "$RC" != "0" ]; then
    MSG=$(grep -m1 -E 'level=error|Error|error' "$RES_DIR/out" "$RES_DIR/err" 2>/dev/null | sed 's/^[^:]*://' | cut -c1-200)
    fail "the script exited with code $RC as Jenkins runs it: ${MSG:-no message}"
fi
[ -n "$SEEN" ] || fail "runc never listed a container $CID of the bundle while the script ran"
echo "  -> OK (exit code 0, container seen in runc list)"

echo "[oracle] check 3: what the script printed: the stdout of the container under 'Subscriber stdout:', its stderr"
echo "[oracle] under 'Subscriber stderr:', each separately and nothing else..."
python3 - "$RES_DIR/out" "$TOKEN" "$CID" <<'PYEOF'
import sys

path, token, cid = sys.argv[1:4]
text = open(path, errors="replace").read()
H1, H2 = "Subscriber stdout:", "Subscriber stderr:"
if H1 not in text or H2 not in text or text.index(H1) > text.index(H2):
    print("FAIL: the script no longer prints the headings 'Subscriber stdout:' and 'Subscriber stderr:'")
    sys.exit(1)
out_sec = text.split(H1, 1)[1].split(H2, 1)[0]
err_sec = text.split(H2, 1)[1]
clean = lambda s: [l.strip().replace("\x00", "") for l in s.splitlines() if l.strip().replace("\x00", "")]
out_lines, err_lines = clean(out_sec), clean(err_sec)
want_out = ["sub-start token=%s pid=1 host=%s" % (token, cid),
            "sub-msg 1 token=%s" % token,
            "sub-msg 2 token=%s" % token]
want_err = ["sub-warning token=%s" % token]
if any("sub-warning" in l for l in out_lines):
    print("FAIL: the stderr line of the container is in the stdout section (the two streams are merged)")
    sys.exit(1)
if not out_lines:
    print("FAIL: the stdout section is empty")
    sys.exit(1)
if any("pid=" in l and "pid=1 " not in l + " " for l in out_lines):
    print("FAIL: the container program reports a pid other than 1: it did not run in the container")
    sys.exit(1)
if out_lines != want_out:
    print("FAIL: the stdout section is not the three lines of the container: %r" % out_lines[:4])
    sys.exit(1)
if err_lines != want_err:
    print("FAIL: the stderr section is not the one stderr line of the container: %r" % err_lines[:3])
    sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 4: nothing is left of the container..."
sleep 1
sudo runc list -q 2>/dev/null | grep -Fxq "$CID" && fail "the container $CID is still there after the script finished"
echo "  -> OK"

echo "[oracle] all checks passed."
