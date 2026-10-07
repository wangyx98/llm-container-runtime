#!/bin/bash
set -e

CASE_ID="bench59393496"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
IMAGE="docker.io/library/$CASE_ID-app:1"
CONTAINER="$CASE_ID-app"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
RESULT="$WORK_DIR/out/result.txt"
MSG="hello-from-ctr"
ARG="ping"
EXIT_CODE=17

CTR="sudo ctr -a $CTD_SOCK"
DOCKER="sudo docker -H unix://$DOCKER_SOCK"
alive_same() {   # $1 = daemon name: still the process recorded by setup (pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }
fail() { echo "  -> FAIL: $*"; exit 1; }

# The state of the task of $CONTAINER, asked from containerd's own API (ctr does not show exit codes):
# Tasks.Get in the namespace default. Prints "<status> <exit_status> <exited_at>" (status 2 = RUNNING, 3 = STOPPED) or
# "none" when there is no task. The third value is the time the task exited, in seconds since the epoch.
cat > "$STATE_DIR/task_state.py" <<'PYEOF'
import struct
import subprocess
import sys

sock, ns, cid = sys.argv[1:4]
cid_b = cid.encode()
msg = b"\x0a" + bytes([len(cid_b)]) + cid_b          # GetRequest { container_id = 1 }
frame = b"\x00" + struct.pack(">I", len(msg)) + msg
r = subprocess.run(
    ["sudo", "curl", "-sS", "--max-time", "20", "--http2-prior-knowledge", "--unix-socket", sock,
     "-H", "content-type: application/grpc", "-H", "te: trailers", "-H", "containerd-namespace: " + ns,
     "-D", "-", "--data-binary", "@-", "http://localhost/containerd.services.tasks.v1.Tasks/Get"],
    input=frame, capture_output=True)
head, _, body = r.stdout.partition(b"\r\n\r\n")
if b"grpc-status: 0" not in r.stdout or len(body) < 5:
    print("none")
    sys.exit(0)


def varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7f) << s
        s += 7
        if not c & 0x80:
            return v, i


def fields(b):
    i = 0
    while i < len(b):
        tag, i = varint(b, i)
        wt = tag & 7
        if wt == 0:
            v, i = varint(b, i)
        elif wt == 2:
            n, i = varint(b, i)
            v = b[i:i + n]
            i += n
        elif wt == 1:
            v = b[i:i + 8]
            i += 8
        elif wt == 5:
            v = b[i:i + 4]
            i += 4
        else:
            return
        yield tag >> 3, v


n = struct.unpack(">I", body[1:5])[0]
resp = body[5:5 + n]                                  # GetResponse { process = 1 }
proc = next((v for f, v in fields(resp) if f == 1), b"")
status = exit_status = 0
exited = 0.0
for f, v in fields(proc):
    if f == 4:
        status = v
    elif f == 9:
        exit_status = v
    elif f == 10:                                     # google.protobuf.Timestamp { seconds = 1, nanos = 2 }
        ts = dict(fields(v))
        exited = ts.get(1, 0) + ts.get(2, 0) / 1e9
print(status, exit_status, "%.3f" % exited)
PYEOF

echo "[oracle] check 1: both daemons must be the very processes of the setup (a restarted or"
echo "[oracle]          reconfigured daemon proves nothing)..."
alive_same containerd && $CTR version >/dev/null 2>&1 || fail "the containerd of this task was restarted, stopped or replaced"
alive_same dockerd && $DOCKER info >/dev/null 2>&1 || fail "the dockerd of this task was restarted, stopped or replaced"
echo "  -> OK"

echo "[oracle] check 2: the image must still be in containerd, unchanged (same digest, still a Docker"
echo "[oracle]          format image)..."
$CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r' | grep -q "$(truth manifest)" \
    || fail "containerd no longer holds $IMAGE with the original digest"
$CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r' | grep -q 'application/vnd.docker.distribution.manifest.v2+json' \
    || fail "$IMAGE is no longer a Docker format image"
echo "  -> OK"

echo "[oracle] check 3: containerd (namespace default, the one ctr uses) must have the container"
echo "[oracle]          $CONTAINER, created from that image..."
if ! $CTR containers ls -q 2>/dev/null | grep -qx "$CONTAINER"; then
    # Docker's containers live in the namespace moby of containerd, and only while they run; Docker itself
    # remembers the finished ones
    if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        fail "there is no container $CONTAINER in the namespace default of containerd; there is one in Docker, which does not count: it has to be a ctr container"
    fi
    fail "there is no container $CONTAINER in the namespace default of containerd"
fi
CIMG=$($CTR containers info "$CONTAINER" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Image",""))' 2>/dev/null || true)
[ "$CIMG" = "$IMAGE" ] || fail "the container $CONTAINER was created from '$CIMG', not from $IMAGE"
echo "  -> OK"

echo "[oracle] check 4: the task of the container must be there, finished (STOPPED) with exit status $EXIT_CODE,"
echo "[oracle]          as containerd's API reports it (not deleted, not run with --rm)..."
STATE="none"
for _ in $(seq 1 40); do
    STATE=$(python3 "$STATE_DIR/task_state.py" "$CTD_SOCK" default "$CONTAINER" 2>/dev/null || echo none)
    [ "${STATE%% *}" = "3" ] && break
    [ "$STATE" = "none" ] && break
    sleep 0.5
done
if [ "$STATE" = "none" ]; then
    fail "the container $CONTAINER has no task: it was never started, or its task was deleted"
fi
read -r ST EX EXITED_AT <<< "$STATE"
[ "$ST" = "3" ] || fail "the task of $CONTAINER is not STOPPED (status code $ST); it should have run to its end"
[ "$EX" = "$EXIT_CODE" ] || fail "the task exited with status $EX, not $EXIT_CODE (2 = /out is not mounted into the container; the program also exits with other codes on errors)"
$CTR tasks ls 2>/dev/null | awk -v c="$CONTAINER" '$1==c && $3=="STOPPED"' | grep -q . \
    || fail "ctr tasks ls does not list the stopped task of $CONTAINER"
echo "  -> OK (exit status $EX)"

echo "[oracle] check 5: the program must have written its line into the mounted directory, with what"
echo "[oracle]          it was given (the environment variable and the first argument), and not touched after"
echo "[oracle]          the task exited..."
TOKEN=$(sudo cat "$STATE_DIR/token")
GOT=$(sudo cat "$RESULT" 2>/dev/null || true)
EXPECTED="$TOKEN|msg=$MSG|arg=$ARG|argv0=/app"
if [ "$GOT" != "$EXPECTED" ]; then
    SHOWN=$(printf '%s' "$GOT" | sed "s/$TOKEN/TOKEN/")
    fail "result.txt holds '$SHOWN', expected 'TOKEN|msg=$MSG|arg=$ARG|argv0=/app'"
fi
# the program writes the file and then exits: a file that is newer than the exit of the task was
# written by somebody else
MTIME=$(sudo stat -c '%.3Y' "$RESULT" 2>/dev/null || echo 0)
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) + 0.05 else 1)' "$MTIME" "$EXITED_AT" \
    || fail "result.txt was modified after the task had exited: it was not (only) written by the program of the container"
echo "  -> OK"

echo "[oracle] all checks passed."
