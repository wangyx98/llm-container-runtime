#!/bin/bash
set -e

CASE_ID="bench76980610"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NR="$WORK_DIR/bin/node-run"

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

st "d['pid']" >/dev/null || fail "setup's record is missing"
PID=$(st "d['pid']")
echo "[precondition] the node's containerd and engine proxy are the recorded processes in their own mount namespace with the recorded configs; the job's files are unchanged..."
sudo test -d "/proc/$PID" || fail "the node's containerd (pid $PID) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st "d['node_ns']")" ] || fail "the node's mount namespace is not the recorded one"
[ "$(readlink /proc/self/ns/mnt)" != "$(st "d['node_ns']")" ] || fail "this shell is inside the node's mount namespace"
[ "$("$NR" sha256sum /etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['containerd_conf_sha']")" ] || fail "the node's containerd config changed"
[ "$("$NR" sha256sum /etc/docker/daemon.json | awk '{print $1}')" = "$(st "d['daemon_json_sha']")" ] || fail "the node's daemon.json changed"
PPID_=$(st "d['proxy_pid']")
sudo test -d "/proc/$PPID_" || fail "the node's engine proxy (pid $PPID_) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PPID_/stat")" = "$(st "d['proxy_start']")" ] || fail "pid $PPID_ is not the recorded engine proxy"
[ "$(sudo readlink "/proc/$PPID_/ns/mnt")" = "$(st "d['node_ns']")" ] || fail "the engine proxy is not in the node"
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a jar, the test classes, the image tar or a wrapper changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the node has containerd (a gRPC socket) and a dockerd binary; /var/run/docker.sock is the engine proxy's, nothing listens behind it (no /run/docker.raw.sock) and no dockerd runs..."
"$NR" test -S /run/containerd/containerd.sock || fail "no containerd socket in the node"
"$NR" sh -c 'test -S /var/run/docker.sock && test ! -e /run/docker.raw.sock' || fail "the node's docker sockets are not as expected (docker.sock of the proxy present, docker.raw.sock absent)"
"$NR" "$(st "d['dockerd']")" --version >/dev/null || fail "dockerd cannot be run in the node"
for d in /proc/[0-9]*; do
    [ "$(sudo readlink "$d/ns/mnt" 2>/dev/null)" = "$(st "d['node_ns']")" ] && [ "$(basename "$(sudo readlink "$d/exe" 2>/dev/null)")" = dockerd ] && fail "a dockerd runs in the node"
done
[ ! -s "$WORK_DIR/home/.testcontainers.properties" ] || fail "the job's HOME has a .testcontainers.properties already"
echo "  -> OK"

echo "[precondition] the symptom of the question: the Spring Boot test (@Testcontainers) cannot get a Docker client: Testcontainers gets 'Status 502: Bad response from Docker engine' from the docker.sock and finds no valid Docker environment; the test fails..."
set +e
OUT=$(timeout -k 5 120 "$WORK_DIR/bin/run-test" 2>&1); RC=$?
set -e
[ "$RC" != "0" ] || fail "the test passed although the node has no Docker engine"
echo "$OUT" | grep -q "Status 502: Bad response from Docker engine" || fail "the test did not fail with the 502 of the engine proxy: $(echo "$OUT" | grep -v '^\[main\]' | tail -3 | cut -c1-200 | tr '\n' ' ')"
echo "$OUT" | grep -q "Could not find a valid Docker environment" || fail "Testcontainers did not say that it found no Docker environment"
echo "  -> OK (Testcontainers: Could not find a valid Docker environment; Status 502: Bad response from Docker engine)"
echo "[precondition] all checks passed."
