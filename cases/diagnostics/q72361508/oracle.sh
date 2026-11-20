#!/bin/bash
set -e

CASE_ID="bench72361508"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
NODE_LOG="$RUN_BASE/containerd.log"
RAW="$STATE_DIR/raw.log"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
fail() { echo "  -> FAIL: $*"; exit 1; }
# the number of lines of each level in the raw stream of containerd after byte $1 (text and json format): "info=3 warning=1 "
levels() { sudo tail -c +"$(($1 + 1))" "$RAW" | grep -oE 'level=[a-z]+|"level":"[a-z]+"' | sed -E 's/.*level"?[=:]"?([a-z]+).*/\1/' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }
lv() { local n; n=$(echo "$1" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2); echo "${n:-0}"; }
PODLOG=$(sj podlog); IMG=$(sj img); WCTR=$(sj web.ctr)
D="$STATE_DIR/replay-$$"; sudo mkdir -p "$D"

state_of() { CRICTL inspect "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null || true; }
lab_ok() {
    local f
    for f in $(sj files | python3 -c 'import json,sys; print(*json.load(sys.stdin))'); do
        [ "$(sudo sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "$(sj files | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$f")" ] || fail "$f was changed (node-ctl and node-crictl stay as they are)"
    done
    "$WORK_DIR/bin/node-ctl" status >/dev/null 2>&1 || fail "the node's containerd is not running; the end of its log: $(sudo tail -n 2 "$NODE_LOG" | tr '\n' ' ' | cut -c1-240)"
    CRICTL version >/dev/null 2>&1 || fail "containerd or its CRI does not answer on its socket (crictl version fails)"
}
web_ok() {   # the workload web: the same container, running, its CRI log the same file with every number once, in order, and still growing
    [ "$(state_of "$WCTR")" = "CONTAINER_RUNNING" ] || fail "the web container is not running (removed, stopped or replaced)"
    sudo env LOG="$(sj web.log)" INO="$(sj web.inode)" FIRST="$(sj web.first_line_sha)" NONCE="$(sj web.nonce)" python3 - <<'PYEOF' || exit 1
import hashlib, os, re, sys, time
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
try: st = os.stat(E["LOG"])
except OSError: fail("the CRI log file of web is gone")
if st.st_ino != int(E["INO"]): fail("the CRI log file of web was replaced")
data = open(E["LOG"], "rb").read()
if hashlib.sha256(data.split(b"\n")[0] + b"\n").hexdigest() != E["FIRST"]: fail("the CRI log file of web was truncated or rewritten")
nums = []
for l in data.decode("utf-8", "replace").splitlines():
    m = re.match(r"^\S+ stdout F web %s out (\d+) (\d+)$" % E["NONCE"], l)
    if m: nums.append((int(m.group(1)), int(m.group(2))))
if len(nums) < 5: fail("the CRI log file of web has %d lines" % len(nums))
for (a, _), (b, _) in zip(nums, nums[1:]):
    if b != a + 1: fail("the output of web has a gap or a repeat in its log: line %d is followed by %d" % (a, b))
if time.time() - nums[-1][1] > 10: fail("the log of web is not growing (its last line is %d s old)" % (time.time() - nums[-1][1]))
PYEOF
}
replay() {   # $1 = number of pods; each runs a container that prints a line and ends, then the pod is removed; then one image pull that fails (an error line)
    local i P C
    for i in $(seq 1 "$1"); do
        sudo mkdir -p "$PODLOG/bench_replay_$i"
        sudo tee "$D/pod.json" >/dev/null <<JEOF
{"metadata":{"name":"replay$i","namespace":"bench","uid":"u-replay-$i-$RANDOM","attempt":0},"log_directory":"$PODLOG/bench_replay_$i","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
        sudo tee "$D/ctr.json" >/dev/null <<JEOF
{"metadata":{"name":"c"},"image":{"image":"$IMG"},"command":["/bin/sh","-c","echo hi"],"log_path":"c/0.log","linux":{}}
JEOF
        P=$(CRICTL runp "$D/pod.json" 2>/dev/null | tail -1); [ -n "$P" ] || fail "the node cannot start a pod (the lab is broken)"
        C=$(CRICTL create "$P" "$D/ctr.json" "$D/pod.json" 2>&1 | tail -1); CRICTL start "$C" >/dev/null 2>&1 || fail "the node cannot start the container of a pod"
        sleep 1
        CRICTL stopp "$P" >/dev/null 2>&1 || true; CRICTL rmp -f "$P" >/dev/null 2>&1 || true
        sudo rm -rf "$PODLOG/bench_replay_$i"
    done
    CRICTL pull 127.0.0.1:1/none:1 >/dev/null 2>&1 || true
    sleep 1
}
check_segment() {   # $1 = label, $2 = byte offset of the raw stream where the replay began
    local L; L=$(levels "$2")
    [ "$(( $(lv "$L" info) + $(lv "$L" debug) + $(lv "$L" trace) ))" -eq 0 ] || fail "$1: containerd still writes info lines while it works ($L): $(sudo tail -c +"$(($2 + 1))" "$RAW" | grep -E 'level=(info|debug)|"level":"(info|debug)"' | head -1 | cut -c1-110)"
    [ "$(lv "$L" error)" -ge 1 ] || fail "$1: the failing image pull left no error line in the node's log ($L): errors must still be logged"
    echo "     $1: $L"
}

echo "[oracle] checking the lab is as the setup left it: node-ctl and node-crictl unchanged, the node's containerd running, the web workload running with its CRI log..."
lab_ok; web_ok
echo "  -> OK"

echo "[oracle] restarting the node's containerd with node-ctl (it reads the configuration again) and reading what containerd writes while it starts..."
O1=$(sudo stat -c %s "$RAW")
OUT=$("$WORK_DIR/bin/node-ctl" restart 2>&1) || fail "node-ctl restart failed, the node does not come up: $(echo "$OUT" | tail -3 | tr '\n' ' ' | cut -c1-260)"
sleep 3
L=$(levels "$O1")
[ "$(lv "$L" info)" -le 10 ] || fail "the restarted containerd wrote $(lv "$L" info) info lines while starting (at most 10: a few come before it reads the configuration) ($L)"
[ "$(lv "$L" warning)" -ge "$(sj baseline.warning)" ] || fail "the restarted containerd wrote $(lv "$L" warning) warning lines while starting, it wrote $(sj baseline.warning) before: warnings must be kept ($L)"
echo "  -> OK ($L)"

echo "[oracle] the node works, its pods and containers run: 5 pods (a container that prints a line and ends, then the pod is removed) and one image pull that fails; every operation is logged at info by default..."
lab_ok
O2=$(sudo stat -c %s "$RAW")
replay 5
check_segment "after the restart" "$O2"
echo "  -> OK"

echo "[oracle] the node's log is what containerd wrote (the file was not filtered or edited), and the web workload kept running, with every line of its CRI log..."
sudo cmp -s "$NODE_LOG" "$RAW" || fail "the node's log ($NODE_LOG) is not what containerd wrote (lines were removed or changed after containerd wrote them)"
web_ok
echo "  -> OK"

echo "[oracle] a cold start (stop, then start), and the same work again: the level must hold for a node that starts later..."
"$WORK_DIR/bin/node-ctl" stop >/dev/null 2>&1 || fail "node-ctl stop failed"
O3a=$(sudo stat -c %s "$RAW")
OUT=$("$WORK_DIR/bin/node-ctl" start 2>&1) || fail "node-ctl start failed, the node does not come up: $(echo "$OUT" | tail -3 | tr '\n' ' ' | cut -c1-260)"
sleep 3
L=$(levels "$O3a")
[ "$(lv "$L" info)" -le 10 ] || fail "the containerd of the cold start wrote $(lv "$L" info) info lines while starting (at most 10) ($L)"
[ "$(lv "$L" warning)" -ge "$(sj baseline.warning)" ] || fail "the containerd of the cold start wrote $(lv "$L" warning) warning lines while starting, it wrote $(sj baseline.warning) before: warnings must be kept ($L)"
lab_ok
O3=$(sudo stat -c %s "$RAW")
replay 3
check_segment "after the cold start" "$O3"
sudo cmp -s "$NODE_LOG" "$RAW" || fail "the node's log ($NODE_LOG) is not what containerd wrote (lines were removed or changed after containerd wrote them)"
web_ok
sudo rm -rf "$D"
echo "  -> OK"
echo "[oracle] PASS: containerd's own log has no info lines while the node works, warnings and errors are still logged, the node's log is what containerd wrote, web ran on with every line of its container log, and the setting holds after a restart and a cold start."
