#!/bin/bash
set -e

CASE_ID="bench67480710"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FB_DIR="$WORK_DIR/fluent-bit"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
PORT=19874

fail() { echo "  -> FAIL: $*"; bash "$STATE_DIR/flb.sh" stop >/dev/null 2>&1 || true; exit 1; }
# the end of Fluent Bit's own log: what it complains about (warnings and errors), at the end of a failure message
flb_log() { sudo grep -iE 'error|warn|fail|invalid|unknown' "$STATE_DIR/fb.log" 2>/dev/null | grep -v "no records found" | tail -2 | cut -c1-200; }
keep() { python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"; }

echo "[oracle] the lab is as setup left it (containerd, helpers, main.conf), the runtime's log files and the symlinks to them are intact, and the solution's files exist..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py collector.py flb.sh main.conf initial-pipeline.conf initial-parsers.conf app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
[ "$(sha256sum "$FB_DIR/main.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/main.conf.sha")" ] || fail "$FB_DIR/main.conf was changed"
[ -s "$FB_DIR/pipeline.conf" ] || fail "there is no $FB_DIR/pipeline.conf"
keep
echo "  -> OK"

echo "[oracle] Fluent Bit is started with the lab's main.conf (as root) on the solution's pipeline.conf and parsers.conf; a Fluent Bit the solution left running is stopped first..."
for pid in $(pgrep -x fluent-bit 2>/dev/null); do
    if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$WORK_DIR"; then sudo kill -9 "$pid" 2>/dev/null || true; fi
done
python3 - <<PYEOF
import urllib.request
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:$PORT/reset", data=b"", method="POST"), timeout=3).read()
PYEOF
bash "$STATE_DIR/flb.sh" start "$FB_DIR/main.conf" || fail "see above"
echo "  -> OK: $("$(cat "$STATE_DIR/flb.path")" --version 2>&1 | head -1)"

echo "[oracle] the lines already in the CRI log files, read through the symlinks: each one must reach the collector as ONE record, \`log\` the text as the application wrote it, \`stream\` the stream it was written on..."
python3 "$STATE_DIR/verify.py" "$WORK_DIR" 30 || { flb_log; fail "see above"; }

echo "[oracle] the containers log more, on both streams, while Fluent Bit runs: it must keep following the files..."
python3 "$STATE_DIR/lab.py" more "$T_SOCK" "$WORK_DIR" || fail "the lab could not make the containers log more"
python3 "$STATE_DIR/verify.py" "$WORK_DIR" 30 || { flb_log; fail "after the new lines: see above"; }

P=$(sudo cat "$STATE_DIR/fb.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = fluent-bit ] || fail "Fluent Bit stopped running"
bash "$STATE_DIR/flb.sh" stop
keep
echo "  -> OK: the runtime's log files and the symlinks are still what the runtime and the kubelet made"

echo "[oracle] ALL CHECKS PASSED: the old and the new lines of both containers arrive as one record each, \`log\` byte for byte what the application wrote and \`stream\` as logged, and the runtime still writes the CRI format."
