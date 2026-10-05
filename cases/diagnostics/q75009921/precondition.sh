#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75009921"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
OUT="$WORK_DIR/containers.txt"
TRIPWIRE_EPOCH=946684800   # 2000-01-01 00:00:00 UTC

echo "[precondition] checking containerd answers on $SOCK and the work dir exists..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -d "$WORK_DIR" ] || { echo "  -> FAIL: $WORK_DIR does not exist"; exit 1; }
[ -s "$STATE_DIR/containers.truth" ] || { echo "  -> FAIL: setup did not record the container list"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the answer file does not exist yet..."
if [ -e "$OUT" ]; then
    echo "  -> FAIL: $OUT already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the containers are there: at least 6 containers in at least 3"
echo "[precondition] namespaces, at least one of them running, and the list still equals the one"
echo "[precondition] recorded by setup..."
LIVE=$(for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
    for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
        echo "$ns $c"
    done
done | LC_ALL=C sort)
TRUTH=$(cat "$STATE_DIR/containers.truth")
if [ "$LIVE" != "$TRUTH" ]; then
    echo "  -> FAIL: the containers of containerd changed since setup"
    echo "     setup: $(echo "$TRUTH" | tr '\n' ',')"
    echo "     now:   $(echo "$LIVE" | tr '\n' ',')"
    exit 1
fi
N=$(echo "$TRUTH" | wc -l)
NNS=$(echo "$TRUTH" | cut -d' ' -f1 | sort -u | wc -l)
if [ "$N" -lt 6 ] || [ "$NNS" -lt 3 ]; then
    echo "  -> FAIL: only $N containers in $NNS namespaces"
    exit 1
fi
RUNNING=0
for ns in $(echo "$TRUTH" | cut -d' ' -f1 | sort -u); do
    RUNNING=$((RUNNING + $(sudo ctr -n "$ns" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)))
done
if [ "$RUNNING" -lt 1 ]; then
    echo "  -> FAIL: no container is running"
    exit 1
fi
echo "  -> OK ($N containers in $NNS namespaces, $RUNNING running)"

echo "[precondition] checking the tools the task rules out for the client are really what the story says:"
echo "[precondition] no grpcurl on this machine..."
if command -v grpcurl >/dev/null 2>&1 || sudo bash -c 'command -v grpcurl' >/dev/null 2>&1; then
    echo "  -> FAIL: grpcurl is installed"
    exit 1
fi
echo "  -> OK"

# the symptom of the question, seen from curl: the socket does not speak the Docker Engine's
# HTTP/1.1 REST API, so the obvious first attempt gets nothing useful
echo "[precondition] checking the symptom: a Docker-style HTTP request to the socket gets no list of"
echo "[precondition] containers..."
DOCKER_STYLE=$(sudo curl -sS --max-time 10 --unix-socket "$SOCK" http://localhost/containers/json 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && echo "$DOCKER_STYLE" | grep -q '^\['; then
    echo "  -> FAIL: the socket answered a Docker-style request with a list"
    exit 1
fi
echo "  -> OK (curl exit $RC)"

# --- tripwire: detect that a forbidden client (ctr, nerdctl, crictl) was run ---
# Running a binary updates its access time. The binaries' atime is set far in the past now and
# oracle.sh reads it back first thing: a newer value means the binary was executed. Merely
# looking for it (command -v, ls, stat) does not touch the atime. This must be the LAST step,
# nothing here or between this script and the solution may run ctr again.
echo "[precondition] arming the check that detects use of ctr, nerdctl and crictl..."
BINS=()
for b in ctr nerdctl crictl; do
    for p in $(command -v "$b" 2>/dev/null; sudo bash -c "command -v $b" 2>/dev/null); do
        r=$(readlink -f "$p")
        [ -f "$r" ] && BINS+=("$r")
    done
done
BINS=($(printf '%s\n' "${BINS[@]}" | sort -u))
printf '%s\n' "${BINS[@]}" > "$STATE_DIR/tripwire_bins"

TRIPWIRE_OK=1
# self-test with ctr itself: set its atime back, make sure it reads back, run ctr, see it move
CTR_REAL=$(readlink -f "$(command -v ctr)")
sudo touch -a -d "@$TRIPWIRE_EPOCH" "$CTR_REAL"
[ "$(sudo stat -c %X "$CTR_REAL")" = "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
if [ "$TRIPWIRE_OK" = 1 ]; then
    sudo ctr --version >/dev/null 2>&1 || true
    [ "$(sudo stat -c %X "$CTR_REAL")" != "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
fi
if [ "$TRIPWIRE_OK" = 1 ]; then
    for b in "${BINS[@]}"; do
        sudo touch -a -d "@$TRIPWIRE_EPOCH" "$b"
        [ "$(sudo stat -c %X "$b")" = "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
    done
fi
echo "$TRIPWIRE_OK" > "$STATE_DIR/tripwire_ok"
if [ "$TRIPWIRE_OK" = 1 ]; then
    echo "  -> OK (watching: ${BINS[*]})"
else
    echo "  -> WARNING: this file system does not record access times (noatime?); the oracle will not be able to tell whether ctr was used"
fi

echo "[precondition] all conditions met."
