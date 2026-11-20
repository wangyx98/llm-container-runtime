#!/bin/bash
set -e

CASE_ID="bench73971174"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
daemon_ok() {   # the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
state_of() { CRICTL inspect "$1" 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"]; print(s["state"])' 2>/dev/null || true; }
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded and the node's containerd..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
daemon_ok containerd || fail "the recorded containerd is not running"
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

echo "[precondition] checking the node's two workloads (web, db) run and write to their CRI log files (the same files, still growing)..."
for t in web db; do
    CTR=$(sj "targets.$t.ctr"); LOG=$(sj "targets.$t.log"); INO=$(sj "targets.$t.inode")
    [ "$(state_of "$CTR")" = "CONTAINER_RUNNING" ] || fail "the $t container is not running"
    [ "$(sudo stat -c %i "$LOG" 2>/dev/null)" = "$INO" ] || fail "the log file of $t is not the recorded one"
    S1=$(sudo stat -c %s "$LOG"); sleep 3; S2=$(sudo stat -c %s "$LOG")
    [ "$S2" -gt "$S1" ] || fail "the log file of $t does not grow"
    sudo tail -n 1 "$LOG" | grep -qE "^[0-9T:.+Z-]+ (stdout|stderr) [PF] $t $(sj "targets.$t.nonce") " || fail "the last line of $t's log is not a CRI line of the workload: $(sudo tail -n 1 "$LOG" | cut -c1-120)"
done
echo "  -> OK"

echo "[precondition] checking the symptom: not one line of the two workloads, and no entry that names one of their containers, is in the systemd journal..."
T0=$(sj setup_epoch)
PAIRS="web:$(sj targets.web.nonce) db:$(sj targets.db.nonce)"
NJ=$(sudo journalctl -o json -a --no-pager -q --since "@${T0%.*}" 2>/dev/null | PAIRS="$PAIRS" CTRS="$(sj targets.web.ctr) $(sj targets.db.ctr)" python3 -c '
import json, os, sys
pairs = [tuple(x.split(":")) for x in os.environ["PAIRS"].split()]
ctrs = os.environ["CTRS"].split()
n = 0
for l in sys.stdin:
    try: e = json.loads(l)
    except Exception: continue
    m = str(e.get("MESSAGE")).split(" ", 2)
    # an entry of the workloads: names a container by CONTAINER_ID_FULL, or is a line of a workload ("<name> <nonce> out|err <n> <time>");
    # a message that merely contains a nonce or an id (sudo logs the commands of the setup, with their environment) is not
    if (isinstance(e.get("CONTAINER_ID_FULL"), str) and e["CONTAINER_ID_FULL"] in ctrs) or (len(m) > 1 and tuple(m[:2]) in pairs): n += 1
print(n)')
[ "$NJ" = "0" ] || fail "the journal already has '$NJ' entries of the workloads"
echo "  -> OK (journalctl shows none; the lines are only in the CRI files)"

echo "[precondition] checking nothing forwards yet: no process but containerd and its shims has a log file of the pods open..."
HOLD=$(sudo python3 - "$(sj podlog)" <<'PYEOF'
import os, sys
base = sys.argv[1] + "/"
out = set()
for d in os.listdir("/proc"):
    if not d.isdigit(): continue
    try:
        comm = open("/proc/%s/comm" % d).read().strip()
        for fd in os.listdir("/proc/%s/fd" % d):
            try:
                if os.readlink("/proc/%s/fd/%s" % (d, fd)).startswith(base) and not comm.startswith("containerd"): out.add(comm)
            except Exception: pass
    except Exception: pass
print(" ".join(sorted(out)))
PYEOF
)
[ -z "$HOLD" ] || fail "something already reads the logs: $HOLD"
echo "  -> OK"

echo "[precondition] checking the control: the journal takes an entry with the fields the task asks for (MESSAGE, PRIORITY 3, CONTAINER_ID_FULL) and returns it by that field..."
PROBE="pre-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
printf 'MESSAGE=probe %s\nPRIORITY=3\nCONTAINER_ID_FULL=%s\n' "$PROBE" "$PROBE" | logger --journald
GOT=""
for _ in $(seq 1 10); do
    GOT=$(sudo journalctl -o json -a --no-pager -q "CONTAINER_ID_FULL=$PROBE" 2>/dev/null | python3 -c 'import json,sys
for l in sys.stdin:
    e = json.loads(l); print(e.get("PRIORITY"), e.get("MESSAGE"))' | head -1)
    [ -n "$GOT" ] && break
    sleep 0.5
done
[ "$GOT" = "3 probe $PROBE" ] || fail "the journal did not return the probe entry (got: '$GOT')"
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the node's containers write to their CRI files, the journal has none of it, and it would take the entries."
