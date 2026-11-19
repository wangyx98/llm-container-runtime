#!/bin/bash
set -e

CASE_ID="bench76666855"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
D="sudo docker -H unix://$DOCKER_SOCK"
HITS="$LIB_BASE/endpoint/hits.log"
TARGET_ID=$(st "d['target']['id']"); CONTROL_ID=$(st "d['control']['id']")
TTAG=$(st "d['target_tag']"); CTAG=$(st "d['control_tag']"); LOAD_BIN=$(st "d['load_bin']")
hits() { awk -v o="$1" -v t="$2" 'NR>o && $2==t' "$HITS" | wc -l; }          # requests tagged $2 after line $1 of the log
lines() { wc -l < "$HITS"; }
# wait (up to $3 s) until at least $2 requests tagged $1 arrived after line $4
wait_hits() { local i; for i in $(seq 1 $(( $3 * 2 ))); do [ "$(hits "$4" "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1; }
# host processes of the load generator with tag $1: "pid ppid" lines (argv[0] is the program of the image, the tag one of its arguments)
procs() { python3 - "$LOAD_BIN" "$1" <<'XEOF'
import os, sys
binary, tag = sys.argv[1], sys.argv[2]
for p in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open("/proc/%s/cmdline" % p).read().split("\0")
        if argv[0] == binary and tag in argv:
            print(p, open("/proc/%s/stat" % p).read().split(")")[1].split()[1])
    except OSError:
        pass
XEOF
}
running() { [ "$($D inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

echo "[precondition] the lab as recorded: the staging API stand-in is the recorded process, the scripts and configuration are unchanged, containerd and dockerd of the lab run..."
sudo test -s "$STATE_DIR/state.json" || fail "setup's record is missing"
sudo python3 - "$STATE_DIR/state.json" "$RUN_BASE" <<'PYEOF' || exit 1
import hashlib, json, os, sys
d = json.load(open(sys.argv[1])); run = sys.argv[2]
pid, start, exe = d["endpoint"]
try:
    s = open("/proc/%d/stat" % pid).read()
    ok = int(s[s.rindex(")") + 2:].split()[19]) == start and os.readlink("/proc/%d/exe" % pid) == exe
except OSError:
    ok = False
if not ok: print("  -> FAIL: the staging API stand-in is not the recorded process"); sys.exit(1)
for f, h in d["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h: print("  -> FAIL: %s changed" % f); sys.exit(1)
for name, comm in (("containerd", "containerd"), ("dockerd", "dockerd")):
    try:
        p = int(open("%s/%s.pid" % (run, name)).read()); c = open("/proc/%d/comm" % p).read().strip()
    except (OSError, ValueError):
        c = ""
    if c != comm: print("  -> FAIL: the lab's %s does not run" % name); sys.exit(1)
    if name == "dockerd" and os.path.realpath("/proc/%d/exe" % p) != d["dockerd_bin"]: print("  -> FAIL: dockerd is not the recorded program"); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[precondition] the two containers: the load generator (restart policy always) and its healthy neighbour (unless-stopped) run; the load generator's process hangs below a containerd-shim of namespace moby..."
$D inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' "$TARGET_ID" | grep -qx "true always" || fail "the load generator's container is not running with the policy always"
$D inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' "$CONTROL_ID" | grep -qx "true unless-stopped" || fail "the neighbour is not running with the policy unless-stopped"
PIDS=$(procs "$TTAG"); [ "$(echo "$PIDS" | grep -c .)" = "1" ] || fail "expected exactly one host process of the load generator, found: $PIDS"
PPID_=$(echo "$PIDS" | awk '{print $2}')
sudo tr '\0' ' ' < /proc/$PPID_/cmdline | grep -q "containerd-shim-runc-v2 -namespace moby " || fail "its parent is not a containerd-shim of the namespace moby: $(sudo tr '\0' ' ' < /proc/$PPID_/cmdline | cut -c1-120)"
echo "  -> OK"

echo "[precondition] the default ctr namespace shows nothing; the containers are in the namespace moby (what docker ps shows is what dockerd keeps; the shim's namespace says where containerd keeps it)..."
CTR="sudo ctr -a $CTD_SOCK"
[ -z "$($CTR containers ls -q 2>/dev/null)" ] || fail "ctr lists containers in its default namespace"
$CTR -n moby containers ls -q 2>/dev/null | grep -qx "$TARGET_ID" || fail "the load generator is not a container of the namespace moby"
echo "  -> OK"

echo "[precondition] both containers call the staging API (requests tagged $TTAG and $CTAG arrive)..."
O=$(lines); wait_hits "$TTAG" 2 10 "$O" || fail "the staging API sees no $TTAG requests"; wait_hits "$CTAG" 2 10 "$O" || fail "the staging API sees no $CTAG requests"
echo "  -> OK"

echo "[precondition] control 1: the symptom of the thread: kill -9 of the process, and it is back (a new process, requests again)..."
OLD=$(echo "$PIDS" | awk '{print $1}'); sudo kill -KILL "$OLD"
for _ in $(seq 1 40); do NEW=$(procs "$TTAG" | awk '{print $1}'); [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break; sleep 0.5; done
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] || fail "after kill -9 the load generator did not come back"
O=$(lines); wait_hits "$TTAG" 2 10 "$O" || fail "after kill -9 the requests did not resume"
echo "  -> OK (pid $OLD -> $NEW)"

echo "[precondition] control 2: stopping the container is not enough: it is stopped (no process, no requests), and a restart of the services brings it back..."
$D stop "$TARGET_ID" >/dev/null || fail "docker stop failed"
[ -z "$(procs "$TTAG")" ] || fail "the process is still there after docker stop"
O=$(lines); sleep 3; [ "$(hits "$O" "$TTAG")" = "0" ] || fail "requests continue after docker stop"
sudo "$STATE_DIR/stack" restart >/dev/null 2>&1 || fail "the stack did not restart"
O=$(lines)
wait_hits "$CTAG" 2 25 "$O" || fail "the neighbour is not back after the restart of the services"
wait_hits "$TTAG" 2 25 "$O" || fail "the stopped load generator did not come back with the services (the thread's behaviour)"
running "$TARGET_ID" && running "$CONTROL_ID" || fail "a container is not running after the restart"
$D inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$TARGET_ID" | grep -qx always || fail "the policy of the load generator changed"
$D inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTROL_ID" | grep -qx unless-stopped || fail "the policy of the neighbour changed"
echo "  -> OK"
echo "[precondition] ALL PRECONDITIONS PASSED"
