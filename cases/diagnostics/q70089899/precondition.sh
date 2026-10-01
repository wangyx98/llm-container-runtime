#!/bin/bash
set -e

CONTAINER="bench70089899"
WORK_DIR="/tmp/bench70089899"
BUNDLE_DIR="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"
STACKTRACE_FILE="$WORK_DIR/stacktrace.txt"

echo "[precondition] checking setup recorded the stuck processes..."
for f in runc_create.pid runc_init.pid stderr_holder.pid config.json.sha256; do
    if [ ! -s "$STATE_DIR/$f" ]; then
        echo "  -> FAIL: $STATE_DIR/$f missing (did setup.sh run?)"
        exit 1
    fi
done
CREATE_PID=$(cat "$STATE_DIR/runc_create.pid")
INIT_PID=$(cat "$STATE_DIR/runc_init.pid")
echo "  -> OK (runc create=$CREATE_PID, runc init=$INIT_PID)"

echo "[precondition] checking 'runc init' (pid $INIT_PID) is alive and is the"
echo "[precondition] child of this container's 'runc create'..."
if ! sudo kill -0 "$INIT_PID" 2>/dev/null; then
    echo "  -> FAIL: runc init pid $INIT_PID is not running"
    exit 1
fi
INIT_CMD=$(sudo cat "/proc/$INIT_PID/cmdline" | tr '\0' ' ' | sed 's/ *$//')
INIT_PPID=$(sudo cat "/proc/$INIT_PID/stat" | awk '{print $4}')
if [ "$INIT_CMD" != "runc init" ] || [ "$INIT_PPID" != "$CREATE_PID" ]; then
    echo "  -> FAIL: pid $INIT_PID is '$INIT_CMD' with ppid $INIT_PPID" \
         "(expected 'runc init' with ppid $CREATE_PID)"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking it is genuinely stuck, not just slow: same pid,"
echo "[precondition] still there, still sleeping, a few seconds later..."
sleep 3
if ! sudo kill -0 "$INIT_PID" 2>/dev/null; then
    echo "  -> FAIL: runc init exited on its own; it was supposed to hang"
    exit 1
fi
STATE=$(sudo cat "/proc/$INIT_PID/stat" | awk '{print $3}')
case "$STATE" in
    S|D) echo "  -> OK (state=$STATE)" ;;
    *)   echo "  -> FAIL: unexpected process state '$STATE'"; exit 1 ;;
esac
if ! sudo kill -0 "$CREATE_PID" 2>/dev/null; then
    echo "  -> FAIL: the top-level 'runc create' (pid $CREATE_PID) already exited"
    exit 1
fi

echo "[precondition] checking runc's stderr is NOT a regular file anyone can"
echo "[precondition] just read (it must be the pipe nobody drains)..."
FD2_TARGET=$(sudo readlink "/proc/$INIT_PID/fd/2")
if [ -f "$FD2_TARGET" ]; then
    echo "  -> FAIL: runc init's stderr is a regular file ($FD2_TARGET)"
    exit 1
fi
echo "  -> OK (fd 2 -> $FD2_TARGET)"

echo "[precondition] checking no stack trace has been captured yet..."
if [ -e "$STACKTRACE_FILE" ]; then
    echo "  -> FAIL: $STACKTRACE_FILE already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the container is not listed as created..."
if sudo runc list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CONTAINER"; then
    STATUS=$(sudo runc list 2>/dev/null | awk -v c="$CONTAINER" '$1==c {print $3}')
    if [ "$STATUS" = "created" ] || [ "$STATUS" = "running" ]; then
        echo "  -> FAIL: '$CONTAINER' is already $STATUS, it should be stuck before that"
        exit 1
    fi
fi
echo "  -> OK"

echo "[precondition] PASS - runc is hung inside the bench70089899 container's"
echo "[precondition]        'runc init', its stderr goes to an undrained pipe,"
echo "[precondition]        and no stack trace exists yet."
