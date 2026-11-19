#!/bin/bash
set -e

CASE_ID="bench76666855"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DOCKER_SOCK="$RUN_BASE/docker.sock"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
D="sudo docker -H unix://$DOCKER_SOCK"
HITS="$LIB_BASE/endpoint/hits.log"
TTAG=$(st "d['target_tag']"); CTAG=$(st "d['control_tag']"); LOAD_BIN=$(st "d['load_bin']")
hits() { awk -v o="$1" -v t="$2" 'NR>o && $2==t' "$HITS" | wc -l; }          # requests tagged $2 after line $1 of the log
lines() { wc -l < "$HITS"; }
wait_hits() { local i; for i in $(seq 1 $(( $3 * 2 ))); do [ "$(hits "$4" "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1; }
procs() { python3 - "$LOAD_BIN" "$1" <<'XEOF'
import os, sys
binary, tag = sys.argv[1], sys.argv[2]
for p in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open("/proc/%s/cmdline" % p).read().split("\0")
        if argv[0] == binary and tag in argv:
            print(p)
    except OSError:
        pass
XEOF
}

# what the docker of the lab keeps: the neighbour is the recorded container (same id, image, command, creation time), still unless-stopped and running; every other container is stopped
# and has no restart policy (the load generator is removed, or stopped with the policy "no"; a re-created one would run or carry a policy)
state_check() {   # $1 = label for the messages
    local ids; ids=$($D ps -aq --no-trunc 2>/dev/null) || fail "$1: the docker of the lab does not answer"
    [ -n "$ids" ] || fail "$1: the lab's docker has no container at all (the neighbour is gone)"
    $D inspect $ids 2>/dev/null | sudo python3 -c '
import json, sys
d = json.load(open(sys.argv[1] + "/state.json")); j = json.load(sys.stdin); ctl = d["control"]; label = sys.argv[2]
byid = {c["Id"]: c for c in j}
c = byid.get(ctl["id"])
if c is None: print("  -> FAIL: %s: the neighbour container %s is gone" % (label, ctl["name"])); sys.exit(1)
cur = {"id": c["Id"], "name": c["Name"], "image": c["Image"], "args": c["Args"], "path": c["Path"], "created": c["Created"], "policy": c["HostConfig"]["RestartPolicy"]["Name"]}
for k in ("id", "name", "image", "args", "path", "created"):
    if cur[k] != ctl[k]: print("  -> FAIL: %s: the neighbour was re-created or changed (%s)" % (label, k)); sys.exit(1)
if cur["policy"] != ctl["policy"]: print("  -> FAIL: %s: the restart policy of the neighbour is now %r, it was %r" % (label, cur["policy"], ctl["policy"])); sys.exit(1)
if not c["State"]["Running"]: print("  -> FAIL: %s: the neighbour is not running" % label); sys.exit(1)
for i, o in byid.items():
    if i == ctl["id"]: continue
    if o["State"]["Running"]: print("  -> FAIL: %s: another container is running: %s (%s)" % (label, o["Name"], " ".join(o["Args"]))); sys.exit(1)
    if o["HostConfig"]["RestartPolicy"]["Name"] not in ("", "no"): print("  -> FAIL: %s: %s is stopped but keeps the restart policy %r: it comes back with the services" % (label, o["Name"], o["HostConfig"]["RestartPolicy"]["Name"])); sys.exit(1)
' "$STATE_DIR" "$1" || exit 1
}

# the load generator is not there: no process, no request tagged with its name during a window of $2 s after line $1 of the log; the neighbour keeps calling the API
window() {   # $1 = log line to count from, $2 = seconds, $3 = label
    wait_hits "$CTAG" 2 25 "$1" || fail "$3: the neighbour does not call the staging API"
    sleep "$2"
    [ -z "$(procs "$TTAG")" ] || fail "$3: a process of the load generator runs (pid $(procs "$TTAG" | head -1))"
    local n; n=$(hits "$1" "$TTAG"); [ "$n" = "0" ] || fail "$3: the staging API received $n request(s) tagged $TTAG"
}

sudo test -s "$STATE_DIR/state.json" || fail "setup's record is missing"
echo "[oracle] check 1: the staging API stand-in is the recorded process (not restarted, not replaced), the scripts and configuration of the lab are unchanged, containerd and dockerd run (dockerd is the recorded program)..."
sudo python3 - "$STATE_DIR/state.json" "$RUN_BASE" <<'PYEOF' || exit 1
import hashlib, json, os, sys
d = json.load(open(sys.argv[1])); run = sys.argv[2]
pid, start, exe = d["endpoint"]
try:
    s = open("/proc/%d/stat" % pid).read()
    ok = int(s[s.rindex(")") + 2:].split()[19]) == start and os.readlink("/proc/%d/exe" % pid) == exe
except OSError:
    ok = False
if not ok: print("  -> FAIL: the staging API stand-in is not the recorded process any more"); sys.exit(1)
for f, h in d["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h: print("  -> FAIL: %s changed" % f); sys.exit(1)
for name in ("containerd", "dockerd"):
    try:
        p = int(open("%s/%s.pid" % (run, name)).read()); c = open("/proc/%d/comm" % p).read().strip()
    except (OSError, ValueError):
        c = ""
    if c != name: print("  -> FAIL: the lab's %s does not run (the services were left stopped)" % name); sys.exit(1)
    if name == "dockerd" and os.path.realpath("/proc/%d/exe" % p) != d["dockerd_bin"]: print("  -> FAIL: dockerd is not the recorded program"); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 2: as the job left it: the load generator is gone (no process, no request during 5 s), nothing but the neighbour runs or carries a restart policy, the neighbour is the recorded container..."
state_check "as left"
O=$(lines); window "$O" 5 "as left"
echo "  -> OK"

for round in 1 2; do
    echo "[oracle] check $((round + 2)): restart $round of the services (stack restart: dockerd and containerd stopped, then started): the load generator does not come back (no process, no request during 5 s); the neighbour does, unchanged..."
    O=$(lines)
    sudo "$STATE_DIR/stack" restart >/dev/null 2>&1 || fail "the oracle could not restart the services"
    wait_hits "$CTAG" 2 30 "$O" || fail "after restart $round the neighbour does not call the staging API"
    window "$O" 5 "after restart $round"
    state_check "after restart $round"
    echo "  -> OK"
done
echo "[oracle] ALL CHECKS PASSED"
