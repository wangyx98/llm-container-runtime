#!/bin/bash
set -e

CASE_ID="bench71379578"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NR="$WORK_DIR/bin/node-run"

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

st "d['pid']" >/dev/null || fail "setup's record is missing"
PID=$(st "d['pid']")
echo "[precondition] the node's containerd is the recorded process in its own mount namespace with the recorded configs; the job's files are unchanged..."
sudo test -d "/proc/$PID" || fail "the node's containerd (pid $PID) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st "d['node_ns']")" ] || fail "the node's mount namespace is not the recorded one"
[ "$(readlink /proc/self/ns/mnt)" != "$(st "d['node_ns']")" ] || fail "this shell is inside the node's mount namespace"
[ "$("$NR" sha256sum /etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['containerd_conf_sha']")" ] || fail "the node's containerd config changed"
[ "$("$NR" sha256sum /etc/docker/daemon.json | awk '{print $1}')" = "$(st "d['daemon_json_sha']")" ] || fail "the node's daemon.json changed"
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a jar, the test classes, the image tar or a wrapper changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the node has containerd and the dockerd of setup (the Docker API exists), the pod is a separate network namespace reaching the node at its IP, and the job's HOME configures nothing..."
"$NR" test -S /run/containerd/containerd.sock || fail "no containerd socket in the node"
"$NR" test -S /var/run/docker.sock || fail "no docker socket in the node"
DPID=$(st "d['dockerd_pid']")
sudo test -d "/proc/$DPID" || fail "the node's dockerd (pid $DPID) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$DPID/stat")" = "$(st "d['dockerd_start']")" ] || fail "pid $DPID is not the recorded dockerd"
POD=$(st "d['pod_pid']"); NODEIP=$(st "d['node_ip']")
[ "$(sudo readlink "/proc/$POD/ns/net")" = "$(st "d['pod_ns']")" ] || fail "the pod's network namespace is not the recorded one"
[ "$(sudo readlink "/proc/$POD/ns/net")" != "$(readlink /proc/self/ns/net)" ] || fail "the pod shares the network namespace of the host"
[ "$("$WORK_DIR/bin/pod-run" ip route show default | awk '{print $3}')" = "$NODEIP" ] || fail "the pod's default gateway is not the node ($NODEIP)"
"$WORK_DIR/bin/pod-run" ip -4 -o addr show | grep -q "$(st "d['pod_ip']")/30" || fail "the pod has not its address"
grep -qE '^[^#[:space:]]' "$WORK_DIR/home/job.env" && fail "job.env has entries already"
[ ! -s "$WORK_DIR/home/.testcontainers.properties" ] || fail "the job's HOME has a .testcontainers.properties already"
echo "  -> OK (node $NODEIP, pod $(st "d['pod_ip']"))"

echo "[precondition] the symptom of the question: the job's test starts the container, but Testcontainers cannot reach its mapped port ('Timed out waiting for container port to open (localhost ports: [N] should be listening)', exit status 5)..."
set +e
OUT=$(timeout -k 5 90 "$WORK_DIR/bin/run-test" 2>&1); RC=$?
set -e
[ "$RC" = "5" ] || fail "the test did not fail the way the question says (exit status $RC): $(echo "$OUT" | tail -2 | cut -c1-200)"
echo "$OUT" | grep -q "Timed out waiting for container port to open (localhost ports: \[[0-9]*\] should be listening)" || fail "the message of the question is missing: $(echo "$OUT" | grep -i exception | tail -1 | cut -c1-200)"
echo "  -> OK (the port is published in the node, but the pod looks for it on its own localhost)"
echo "[precondition] all checks passed."
