#!/bin/bash
set -e

CASE_ID="bench74677606"
RUN_BASE="/run/$CASE_ID"
DOCKER_SOCK="$RUN_BASE/docker.sock"
A_SOCK="$RUN_BASE/docker/containerd/containerd.sock"    # Docker's containerd
B_SOCK="$RUN_BASE/containerd/containerd.sock"           # the other containerd, the one ctr is pointed to
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

DOCKER="sudo docker -H unix://$DOCKER_SOCK"
truth() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [d := d[k] for k in sys.argv[2].split(".")]; print(d)' "$STATE_DIR/truth.json" "$1"; }
alive_same() {   # $1 = daemon name: still the process recorded by setup (pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[precondition] checking the three daemons run, are the ones setup started, and answer..."
for f in truth.json docker-containerd.id dockerd.id containerd.id api.baseline; do
    [ -s "$STATE_DIR/$f" ] || { echo "  -> FAIL: setup did not record $f"; exit 1; }
done
for d in docker-containerd dockerd containerd; do
    alive_same "$d" || { echo "  -> FAIL: the recorded $d is not running"; exit 1; }
done
sudo ctr -a "$A_SOCK" version >/dev/null 2>&1 || { echo "  -> FAIL: Docker's containerd does not answer"; exit 1; }
sudo ctr -a "$B_SOCK" version >/dev/null 2>&1 || { echo "  -> FAIL: the other containerd does not answer"; exit 1; }
$DOCKER info >/dev/null 2>&1 || { echo "  -> FAIL: dockerd does not answer"; exit 1; }
echo "  -> OK"

TID=$(truth target.id); TPID=$(truth target.pid)
OID=$(truth other.id); OPID=$(truth other.pid)
echo "[precondition] checking Docker's view: both containers run, the target has a 64 character ID..."
[ "${#TID}" -eq 64 ] || { echo "  -> FAIL: the ID of the target is not 64 characters"; exit 1; }
[ "$($DOCKER ps -q --no-trunc --filter "name=^$CASE_ID-app\$" 2>/dev/null)" = "$TID" ] || { echo "  -> FAIL: Docker does not report the recorded target container"; exit 1; }
[ "$($DOCKER ps -q --no-trunc --filter "name=^$CASE_ID-other\$" 2>/dev/null)" = "$OID" ] || { echo "  -> FAIL: Docker does not report the recorded other container"; exit 1; }
echo "  -> OK"

echo "[precondition] checking where the containers really are: all in Docker's containerd, in the"
echo "[precondition] namespace moby, none in its default namespace, with the tasks and PIDs recorded..."
if [ -n "$(sudo ctr -a "$A_SOCK" containers ls -q 2>/dev/null)" ]; then
    echo "  -> FAIL: Docker's containerd has containers in its default namespace"
    exit 1
fi
LIVE=$(sudo ctr -a "$A_SOCK" -n moby tasks ls 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | LC_ALL=C sort)
WANT=$(printf '%s %s RUNNING\n%s %s RUNNING\n' "$TID" "$TPID" "$OID" "$OPID" | LC_ALL=C sort)
[ "$LIVE" = "$WANT" ] || { echo "  -> FAIL: the tasks in the namespace moby are not the recorded ones"; exit 1; }
if ! sudo ctr -a "$A_SOCK" -n moby containers info "$TID" 2>/dev/null | grep -q '"BENCH_NAME=bench74677606-app"'; then
    echo "  -> FAIL: the spec of the target in containerd does not carry its BENCH_NAME"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the symptom: the containerd that ctr is pointed to shows only the decoy,"
echo "[precondition] which carries the same BENCH_NAME but is no Docker container..."
[ "$(sudo ctr -a "$B_SOCK" containers ls -q 2>/dev/null)" = "$(truth decoy.id)" ] || { echo "  -> FAIL: the other containerd does not hold just the decoy"; exit 1; }
if [ -n "$(sudo ctr -a "$B_SOCK" -n moby containers ls -q 2>/dev/null)" ]; then
    echo "  -> FAIL: the other containerd has Docker containers"
    exit 1
fi
sudo ctr -a "$B_SOCK" containers info "$(truth decoy.id)" 2>/dev/null | grep -q '"BENCH_NAME=bench74677606-app"' || { echo "  -> FAIL: the decoy does not carry the BENCH_NAME of the target"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the symptom: crictl asked of the Docker daemon fails (Docker does not"
echo "[precondition] speak CRI)..."
if command -v crictl >/dev/null 2>&1; then
    if sudo crictl --runtime-endpoint "unix://$DOCKER_SOCK" --image-endpoint "unix://$DOCKER_SOCK" --timeout 5s ps >/dev/null 2>&1; then
        echo "  -> FAIL: crictl worked against the Docker socket"
        exit 1
    fi
    echo "  -> OK"
else
    echo "  -> skipped (crictl is not installed)"
fi

echo "[precondition] all conditions met."
# From here on, every request that reaches the Docker daemon counts against the solution: its debug log
# is read from this point (the case's own checks above were the last ones to ask Docker anything).
sudo wc -c < "$RUN_BASE/dockerd.log" > "$STATE_DIR/api.baseline"
