#!/bin/bash
set -e

CASE_ID="bench63515845"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CRIO_SOCK="$RUN_BASE/crio.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" "$@"; }
daemon_ok() {   # the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
state_of() { CRICTL inspect "$1" 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"]; print(s["state"], s.get("exitCode", ""))' 2>/dev/null || true; }
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded and the node's CRI-O..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
daemon_ok crio || fail "the recorded CRI-O is not running"
CRICTL version >/dev/null 2>&1 || fail "CRI-O does not answer on $CRIO_SOCK"
IMG=$(sj img); IMG_ID=$(sj img_id); CRICTL_BIN=$(sj crictl_bin)
[ "$(CRICTL inspecti "$IMG" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])' 2>/dev/null)" = "$IMG_ID" ] || fail "the reporter image of the lab is not the recorded one"
echo "  -> OK"

echo "[precondition] checking the node's two workloads (web, db) run, with the recorded pids, and the pids really are those processes (the nonce in /proc/PID/environ)..."
for t in web db; do
    CTR=$(sj "targets.$t.ctr"); PID=$(sj "targets.$t.pid"); NONCE=$(sj "targets.$t.nonce")
    [ "$(state_of "$CTR" | cut -d' ' -f1)" = "CONTAINER_RUNNING" ] || fail "the $t container is not running"
    [ "$(CRICTL inspect "$CTR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')" = "$PID" ] || fail "the pid of $t is not the recorded one"
    sudo cat "/proc/$PID/environ" 2>/dev/null | tr '\0' '\n' | grep -qx "BENCH_NONCE=$NONCE" || fail "pid $PID is not the process of $t"
done
echo "  -> OK"

echo "[precondition] checking the symptom: the reporter pod's program finished with exit status 0 and printed an empty output (no container id, no pid)..."
RCTR=$(sj reporter.ctr)
set -- $(state_of "$RCTR")
[ "$1" = "CONTAINER_EXITED" ] && [ "$2" = "0" ] || fail "the reporter container is not 'exited with status 0' (it is: $*)"
LOG=$(CRICTL inspect "$RCTR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["logPath"])')
TXT=$(sudo cat "$LOG")
echo "$TXT" | grep -q 'cmdStr is crictl ps --no-trunc -a --quiet' || fail "the reporter's log is not the asker's program: $(echo "$TXT" | head -c 200)"
echo "$TXT" | grep -qE '[0-9a-f]{64}|[0-9a-f]{12}' && fail "the reporter's log already shows container ids"
echo "$TXT" | grep -q 'output is' || fail "the reporter's log has no 'output is' line"
echo "  -> OK (log: $(echo "$TXT" | cut -d' ' -f4- | tr '\n' '|' | cut -c1-120))"

echo "[precondition] checking the node can answer a container that has the client and the socket (control): a container made by hand, as root, with the node's crictl and the CRI-O socket mounted, lists the workloads..."
D="$STATE_DIR/pre-$$"; sudo mkdir -p "$D/logs"
sudo tee "$D/pod.json" >/dev/null <<JEOF
{"metadata":{"name":"pre","namespace":"bench","uid":"u-pre-$$","attempt":1},"log_directory":"$D/logs","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
sudo tee "$D/ctr.json" >/dev/null <<JEOF
{"metadata":{"name":"c"},"image":{"image":"$IMG"},"command":["/bin/sh","-c","crictl --runtime-endpoint unix://$CRIO_SOCK ps -q --no-trunc 2>&1"],
 "mounts":[{"container_path":"/usr/bin/crictl","host_path":"$CRICTL_BIN","readonly":true},{"container_path":"$CRIO_SOCK","host_path":"$CRIO_SOCK"}],
 "log_path":"c.log","linux":{"security_context":{"run_as_user":{"value":0}}}}
JEOF
POD=$(CRICTL runp "$D/pod.json" 2>/dev/null | tail -1) || true
[ -n "$POD" ] || { sudo rm -rf "$D"; fail "CRI-O cannot start a pod sandbox (the lab is broken)"; }
C=$(CRICTL create "$POD" "$D/ctr.json" "$D/pod.json" 2>&1 | tail -1)
CRICTL start "$C" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do [ "$(state_of "$C" | cut -d' ' -f1)" = "CONTAINER_EXITED" ] && break; sleep 1; done
OUT=$(sudo cat "$D/logs/c.log" 2>/dev/null || true)
CRICTL stopp "$POD" >/dev/null 2>&1 || true; CRICTL rmp -f "$POD" >/dev/null 2>&1 || true; sudo rm -rf "$D"
for t in web db; do echo "$OUT" | grep -q "$(sj "targets.$t.ctr")" || fail "the control container's list does not show the $t container: $(echo "$OUT" | tail -2 | cut -c1-150)"; done
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the reporter pod printed nothing; the node itself can answer what the program asks."
