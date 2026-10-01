#!/bin/bash
set -e

CONTAINER="bench70089899"
WORK_DIR="/tmp/bench70089899"
BUNDLE_DIR="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"
STACKTRACE_FILE="$WORK_DIR/stacktrace.txt"

echo "[oracle] check 0: runc must still be present and working..."
command -v runc >/dev/null || { echo "  -> FAIL: runc missing"; exit 1; }
sudo runc --version >/dev/null || { echo "  -> FAIL: runc not functional"; exit 1; }
echo "  -> OK"

echo "[oracle] check 1: the bundle must be untouched (no editing config.json"
echo "[oracle]          to manufacture a different hang or a different trace)..."
EXPECTED_SHA=$(cat "$STATE_DIR/config.json.sha256" 2>/dev/null || true)
ACTUAL_SHA=$(sha256sum "$BUNDLE_DIR/config.json" 2>/dev/null | awk '{print $1}')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "  -> FAIL: $BUNDLE_DIR/config.json changed or is missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $STACKTRACE_FILE must exist and be non-empty..."
if [ ! -s "$STACKTRACE_FILE" ]; then
    echo "  -> FAIL: $STACKTRACE_FILE missing or empty"
    exit 1
fi
echo "  -> OK ($(wc -l < "$STACKTRACE_FILE") lines)"

echo "[oracle] check 3: it must be a Go runtime SIGQUIT dump ('SIGQUIT: quit'"
echo "[oracle]          header near the top)..."
if ! head -n 5 "$STACKTRACE_FILE" | grep -q '^SIGQUIT: quit'; then
    echo "  -> FAIL: no 'SIGQUIT: quit' header in the first 5 lines"
    echo "  -> first lines: $(head -n 3 "$STACKTRACE_FILE" | tr '\n' '|')"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 4: it must contain a real multi-goroutine dump, not one"
echo "[oracle]          or two hand-written frames..."
GOROUTINES=$(grep -cE '^goroutine [0-9]+ .*\[.*\]:$' "$STACKTRACE_FILE" || true)
if [ "$GOROUTINES" -lt 4 ]; then
    echo "  -> FAIL: only $GOROUTINES goroutine header(s), expected >= 4"
    exit 1
fi
echo "  -> OK ($GOROUTINES goroutines)"

echo "[oracle] check 5: it must come from THIS hang, i.e. runc's init stuck"
echo "[oracle]          running a container hook during rootfs preparation."
echo "[oracle]          A trace pasted from a bug report (e.g. the well-known"
echo "[oracle]          seccomp/ExportBPF one) or taken from some unrelated runc"
echo "[oracle]          process will not have these frames..."
for marker in 'github.com/opencontainers/runc/libcontainer' 'prepareRootfs' 'Hook'; do
    if ! grep -qF "$marker" "$STACKTRACE_FILE"; then
        echo "  -> FAIL: expected frame/marker '$marker' not found"
        exit 1
    fi
done
echo "  -> OK"

echo "[oracle] check 6: the ORIGINAL stuck 'runc init' must be gone (a real"
echo "[oracle]          SIGQUIT dump ends the process; a fabricated file leaves"
echo "[oracle]          it hanging)..."
INIT_PID=$(cat "$STATE_DIR/runc_init.pid" 2>/dev/null || true)
if [ -z "$INIT_PID" ]; then
    echo "  -> FAIL: setup's recorded runc init pid is missing"
    exit 1
fi
# give the process a moment to finish exiting if the solution just signalled it
for _ in $(seq 1 20); do
    sudo kill -0 "$INIT_PID" 2>/dev/null || break
    sleep 0.25
done
if sudo kill -0 "$INIT_PID" 2>/dev/null; then
    CMD=$(sudo cat "/proc/$INIT_PID/cmdline" 2>/dev/null | tr '\0' ' ')
    if [ "${CMD% }" = "runc init" ]; then
        echo "  -> FAIL: the original runc init (pid $INIT_PID) is still alive"
        exit 1
    fi
fi
echo "  -> OK"

echo "[oracle] check 7: no other container may have been created to get a"
echo "[oracle]          trace from (only the original process tree counts)..."
OTHER=$(sudo runc list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vx "$CONTAINER" || true)
STRAY_INIT=$(pgrep -f '^runc init' || true)
if [ -n "$STRAY_INIT" ]; then
    echo "  -> FAIL: another 'runc init' is running (pid(s): $STRAY_INIT)"
    exit 1
fi
if [ -n "$OTHER" ]; then
    echo "  -> NOTE: other runc containers exist on this host ($OTHER);"
    echo "           not failing on that alone, since they may predate this case"
fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
