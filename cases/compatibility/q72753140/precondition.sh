#!/bin/bash
set -e

CASE_ID="bench72753140"
RUN_BASE="/run/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"
NS_OTHER="$CASE_ID-other"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ANSWER="$WORK_DIR/answer.json"
TRIPWIRE_EPOCH=946684800   # 2000-01-01 00:00:00 UTC

# one gRPC call with curl (HTTP/2 over the unix socket) with an empty request message:
# $1 = "Package.Service/Method", $2 = value of the containerd-namespace header (may be empty);
# response headers (with the gRPC status trailer) go to call.hdr, the body to call.body.
# An error answer (e.g. status 12) ends the HTTP/2 stream early, and curl then sometimes reports
# "(92) Stream error in the HTTP/2 framing layer" although the answer arrived complete, so the
# exit code of curl is not what counts: the call worked if a grpc-status line was received.
grpc_call() {
    local hdr=()
    [ -n "$2" ] && hdr=(-H "containerd-namespace: $2")
    rm -f "$STATE_DIR/call.hdr" "$STATE_DIR/call.body"
    printf '\x00\x00\x00\x00\x00' | sudo curl -sS --max-time 10 --http2-prior-knowledge --unix-socket "$SOCK" \
        -H 'content-type: application/grpc' -H 'te: trailers' "${hdr[@]}" -D "$STATE_DIR/call.hdr" \
        --data-binary @- "http://localhost/$1" -o "$STATE_DIR/call.body" || true
    grep -qi '^grpc-status:' "$STATE_DIR/call.hdr" 2>/dev/null
}

echo "[precondition] checking the private containerd answers on $SOCK and the work files exist..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -s "$RUN_BASE/containerd.pid" ] || { echo "  -> FAIL: no containerd pid recorded"; exit 1; }
sudo kill -0 "$(cat "$RUN_BASE/containerd.pid")" 2>/dev/null || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
[ -s "$STATE_DIR/containers.truth" ] || { echo "  -> FAIL: setup did not record the containers"; exit 1; }
[ -f "$WORK_DIR/proto/containerd/services/tasks/v1/tasks.proto" ] || { echo "  -> FAIL: the matching proto files are missing"; exit 1; }
[ -f "$WORK_DIR/proto-old/api/services/tasks/v1/tasks.proto" ] || { echo "  -> FAIL: the outdated proto files are missing"; exit 1; }
echo "  -> OK"

echo "[precondition] checking grpcurl is installed..."
grpcurl -version >/dev/null 2>&1 || { echo "  -> FAIL: grpcurl is not installed"; exit 1; }
echo "  -> OK ($(grpcurl -version 2>&1 | head -1))"

echo "[precondition] checking the answer file does not exist yet..."
if [ -e "$ANSWER" ]; then
    echo "  -> FAIL: $ANSWER already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the containers: two running tasks in $NS, one in $NS_OTHER, and the"
echo "[precondition] list still equals the one recorded by setup..."
LIVE=$(for ns in "$NS" "$NS_OTHER"; do
    for c in $(sudo ctr -a "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do echo "$ns $c"; done
done | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the containers changed since setup"
    exit 1
fi
N=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
M=$(sudo ctr -a "$SOCK" -n "$NS_OTHER" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
if [ "$N" -ne 2 ] || [ "$M" -ne 1 ]; then
    echo "  -> FAIL: expected 2 running tasks in $NS and 1 in $NS_OTHER, found $N and $M"
    exit 1
fi
echo "  -> OK (2 + 1 running tasks)"

echo "[precondition] checking the symptom: the service of the outdated definition is unknown to"
echo "[precondition] the daemon (gRPC status 12, Unimplemented)..."
grpc_call "containerd.api.services.tasks.v1.Tasks/List" "$NS" || { echo "  -> FAIL: no answer from the daemon"; exit 1; }
STATUS=$(tr -d '\r' < "$STATE_DIR/call.hdr" | awk -F': *' 'tolower($1)=="grpc-status"{print $2}')
MSG=$(tr -d '\r' < "$STATE_DIR/call.hdr" | awk -F': *' 'tolower($1)=="grpc-message"{print $2}')
if [ "$STATUS" != "12" ] || ! echo "$MSG" | grep -q "unknown service"; then
    echo "  -> FAIL: expected status 12 'unknown service', got status '$STATUS' message '$MSG'"
    exit 1
fi
echo "  -> OK ($MSG)"

echo "[precondition] checking the daemon does serve the matching Tasks service and lists the"
echo "[precondition] tasks of $NS (and not those of $NS_OTHER)..."
grpc_call "containerd.services.tasks.v1.Tasks/List" "$NS" || { echo "  -> FAIL: no answer from the daemon"; exit 1; }
STATUS=$(tr -d '\r' < "$STATE_DIR/call.hdr" | awk -F': *' 'tolower($1)=="grpc-status"{print $2}')
if [ "$STATUS" != "0" ]; then
    echo "  -> FAIL: Tasks/List answered with gRPC status '$STATUS'"
    exit 1
fi
for id in $(awk -v n="$NS" '$1==n{print $2}' "$STATE_DIR/containers.truth"); do
    grep -aq "$id" "$STATE_DIR/call.body" || { echo "  -> FAIL: the task of $id is not in the answer"; exit 1; }
done
OTHER_ID=$(awk -v n="$NS_OTHER" '$1==n{print $2}' "$STATE_DIR/containers.truth")
if grep -aq "$OTHER_ID" "$STATE_DIR/call.body"; then
    echo "  -> FAIL: the task of $NS_OTHER shows up in the answer for $NS"
    exit 1
fi
rm -f "$STATE_DIR/call.hdr" "$STATE_DIR/call.body"
echo "  -> OK"

# --- tripwires, the LAST step: nothing here or between this script and the solution may run
# ctr, nerdctl, crictl or grpcurl again.
# Running a binary updates its access time. The binaries' atime is set far in the past now and
# oracle.sh reads it back first thing: for ctr, nerdctl and crictl a newer value means one of
# them was run (forbidden), for grpcurl an unchanged value means it was never run (required).
# Merely looking for a binary (command -v, ls, stat) does not touch the atime.
echo "[precondition] arming the checks that detect use of ctr, nerdctl and crictl (forbidden)"
echo "[precondition] and of grpcurl (required)..."
BINS=()
for b in ctr nerdctl crictl; do
    for p in $(command -v "$b" 2>/dev/null; sudo bash -c "command -v $b" 2>/dev/null); do
        r=$(readlink -f "$p")
        [ -f "$r" ] && BINS+=("$r")
    done
done
BINS=($(printf '%s\n' "${BINS[@]}" | sort -u))
printf '%s\n' "${BINS[@]}" > "$STATE_DIR/tripwire_bins"
readlink -f "$(command -v grpcurl)" > "$STATE_DIR/tripwire_grpcurl"

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
    for b in "${BINS[@]}" "$(cat "$STATE_DIR/tripwire_grpcurl")"; do
        sudo touch -a -d "@$TRIPWIRE_EPOCH" "$b"
        [ "$(sudo stat -c %X "$b")" = "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
    done
fi
echo "$TRIPWIRE_OK" > "$STATE_DIR/tripwire_ok"
if [ "$TRIPWIRE_OK" = 1 ]; then
    echo "  -> OK (forbidden: ${BINS[*]}; required: $(cat "$STATE_DIR/tripwire_grpcurl"))"
else
    echo "  -> WARNING: this file system does not record access times (noatime?); the oracle will not be able to tell which clients were run"
fi

echo "[precondition] all conditions met."
