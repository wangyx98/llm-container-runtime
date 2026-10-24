#!/bin/bash
# Precondition oracle: the initial state is the question's, measured here:
#  - the lab's files are as setup left them; the node (the lab's containerd 1.6.17 with the CRI, runc v1.1.12 in the node's directory) runs; the pod lab runs; the container of bad.cid is Created;
#    the "rebuilt" runc of $LIB/patched is another file than the runc the node executes; strace is there; the tool the task asks for does not exist yet;
#  - a container made by newbad (a throwaway one: the container of bad.cid stays Created) does not start: the CRI's error has the question's shape (error mounting "SRC" to rootfs at "DST": mount SRC:DST (via
#    /proc/self/fd/N), flags: 0x5000: <errno text>); its container log stays empty; a /proc watcher sees ONE runc init (stage 2, comm runc:[2:INIT]) and the runc of the node's directory as the program the shim ran.

CASE_ID="bench65981878"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
cr() { sudo timeout -k 3 120 "$LIB/bin/crictl" --timeout 90s "$@"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

echo "[precondition] the lab's files, the node, the pod, the containers..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab is not as setup left it"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
cr version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the CRI of the node does not answer"
cr pods --name '^lab$' --state ready -q | grep -q . || fail "the pod lab does not run"
BAD=$(sudo cat "$LIB/bad.cid")
[ "$(cr inspect -o go-template --template '{{.status.state}}' "$BAD")" = CONTAINER_CREATED ] || fail "the container of bad.cid is not Created"
[ "$("$LIB/node/bin/runc" --version | head -1)" = "runc version 1.1.12" ] || fail "the node's runc is not v1.1.12"
[ "$(sudo sha256sum < "$LIB/node/bin/runc" | cut -c1-64)" != "$(sudo sha256sum < "$LIB/patched/runc" | cut -c1-64)" ] || fail "the rebuilt runc is the node's runc"
command -v strace >/dev/null || fail "strace is missing"
[ ! -e "$LIB/mountfail" ] || fail "mountfail exists before the solution"

echo "[precondition] a container that does not start: the error, the empty log, the init and the runc that ran..."
cat > "$TMPD/watch.py" <<'PYEOF'
import json, os, sys, time
out, stop = sys.argv[1:3]
inits, runcs = set(), {}
while not os.path.exists(stop):
    for n in os.listdir("/proc"):
        if n.isdigit():
            try:
                c = open("/proc/%s/comm" % n).read().strip()
                if c == "runc:[2:INIT]":
                    inits.add(int(n))
                elif c == "runc" and int(n) not in runcs:
                    runcs[int(n)] = [os.readlink("/proc/%s/exe" % n), open("/proc/%s/cmdline" % n, "rb").read().decode(errors="replace").split("\0")[:-1]]
            except OSError:
                pass
json.dump({"inits": sorted(inits), "runcs": runcs}, open(out, "w"))
PYEOF
ok=0
for attempt in 1 2 3; do
    rm -f "$TMPD/stop" "$TMPD/w.json"
    C=$(sudo "$LIB/bin/newbad") || fail "newbad failed"
    sudo python3 "$TMPD/watch.py" "$TMPD/w.json" "$TMPD/stop" & WPID=$!
    sleep 0.5
    MSG=$(cr start "$C" 2>&1); sleep 0.3; touch "$TMPD/stop"; wait $WPID
    echo "$MSG" | grep -qE 'error mounting \\?"[^"]+\\?" to rootfs at \\?"/m/[^"]+\\?": mount [^ ]+:/m/[^ ]+ \(via /proc/self/fd/[0-9]+\), flags: 0x5000: not a directory' || fail "the error of the start is not the question's shape: $(echo "$MSG" | tail -c 300)"
    [ -z "$(sudo cat "$RUN/log/bad-"*.log 2>/dev/null | head -c 1)" ] || fail "the container's log is not empty"
    if python3 - "$TMPD/w.json" "$LIB/node/bin/runc" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
assert len(w["inits"]) == 1, "inits %s" % w["inits"]
assert [v for v in w["runcs"].values() if "create" in v[1] and v[0] == sys.argv[2]], "no runc create from the node's directory"
PYEOF
    then ok=1; break; fi
done
[ "$ok" = 1 ] || fail "the watcher did not see one runc init and the node's runc in three attempts"

echo "[precondition] OK: the start of a container fails in runc init at a bind mount (ENOTDIR); the init and the runc of the node's directory are visible in /proc while it lives; the log is empty."
