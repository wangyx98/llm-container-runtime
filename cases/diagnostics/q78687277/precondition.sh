#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there, measured from inside the container with the lab's passive observer (/lab/watch):
#  - the lab's files are unchanged; the node's containerd is the 1.7.20 of the lab; the container app is Running (the one setup started); /probe is read-only in it and /out is writable;
#  - a tty exec session whose client is killed: the process is still there seconds later and nothing at all changed for it: no POLLHUP, no EOF, no EIO, no signal, stdout writes, TIOCGWINSZ and /dev/tty
#    keep working. It "still thinks the terminal is there" (the question's symptom: nothing to read in the node's logs either, the process is just a leaked one);
#  - a non-tty exec session whose client is killed: the process is still there, and its stdin has POLLHUP (0x10) and EOF (read() = 0), its stdout writes still succeed: the signal exists, it is passive;
#  - the way back into a tty process is open: what a terminal emulator types reaches the process through the exec session.

CASE_ID="bench78687277"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node's containerd and the container..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.7.20" || fail "the node's containerd is not v1.7.20"
read -r POD CID < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container app is not running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container app is not the one setup started"

echo "[precondition] three exec sessions into the container, their clients ended or kept, observed from inside (about 12 s)..."
sudo python3 -I - "$CID" <<'PYEOF'
import json
import os
import signal
import sys
import time

sys.path.insert(0, "/var/lib/bench78687277/bin")
import execlab as E

OUT = "/run/bench78687277/out"
cid = sys.argv[1]
bad = []


def fail(msg):
    bad.append(msg)
    print("[precondition] FAIL: " + msg)


def read_log(label):
    """the lines of the observer's log as (t, kind, rest)"""
    rows = []
    for line in open("%s/%s.log" % (OUT, label)):
        t, kind, *rest = line.split(None, 2)
        rows.append((float(t), kind, rest[0] if rest else ""))
    return rows


def epoch(rows):
    return float([r[2] for r in rows if r[1] == "start"][0].split("epoch=")[1].split()[0])


clients = {}
try:
    # the container's own mounts: /probe read-only (the solution writes the program on the host), /out writable (the observer writes its log there, the checker's socket is there)
    spec = json.loads(E.crictl("inspect", "-o", "json", cid).stdout)["info"]["runtimeSpec"]["mounts"]
    mounts = {m["destination"]: m["options"] for m in spec}
    if "ro" not in mounts.get("/probe", []) or "rw" not in mounts.get("/out", []):
        fail("the mounts of the container are not /probe read-only and /out read-write: %s" % {k: v for k, v in mounts.items() if k in ("/probe", "/out")})
    clients["tty-killed"] = E.Client(cid, ["/lab/watch", "tty-killed", "30"], True).start()
    clients["pipe-killed"] = E.Client(cid, ["/lab/watch", "pipe-killed", "30"], False).start()
    clients["tty-typed"] = E.Client(cid, ["/lab/watch", "tty-typed", "30"], True).start()
    time.sleep(3.0)
    clients["tty-typed"].type(b"ping\n")
    clients["tty-killed"].kill(signal.SIGKILL)
    clients["pipe-killed"].kill(signal.SIGKILL)
    time.sleep(7.5)

    for label in clients:
        if not E.probe_pids(["/lab/watch", label, "30"]):
            fail("%s: the process in the container is gone" % label)

    # 1. tty, client killed
    rows = read_log("tty-killed")
    k = clients["tty-killed"].killed_at - epoch(rows)
    after = [r for r in rows if r[0] > k + 0.5 and r[1] != "alive"]
    alive = max(r[0] for r in rows if r[1] == "alive")
    if "tty0=1" not in rows[0][2]:
        fail("tty-killed: the session has no terminal")
    elif after:
        fail("tty-killed: something changed for the process after its client was killed: %s" % after[0][2])
    elif alive < k + 5:
        fail("tty-killed: the process ended %.1f s after its client was killed" % (alive - k))
    else:
        print("[precondition] tty exec, client killed: the process is alive %.1f s later and nothing changed for it (no POLLHUP, EOF, EIO or signal; stdout writes, TIOCGWINSZ, /dev/tty all fine)" % (alive - k))

    # 2. pipes, client killed
    rows = read_log("pipe-killed")
    k = clients["pipe-killed"].killed_at - epoch(rows)
    hup = [r for r in rows if r[1] == "state" and "poll0=0x10" in r[2] and "read=0/" in r[2] and "write=1/-" in r[2]]
    alive = max(r[0] for r in rows if r[1] == "alive")
    if "tty0=0" not in rows[0][2]:
        fail("pipe-killed: the session has a terminal")
    elif not hup:
        fail("pipe-killed: stdin shows no POLLHUP and EOF after the client was killed")
    elif alive < k + 5:
        fail("pipe-killed: the process ended %.1f s after its client was killed" % (alive - k))
    else:
        print("[precondition] exec without tty, client killed: stdin POLLHUP (0x10) and EOF %.1f s after the kill, stdout writes still succeed, the process is alive %.1f s later" % (max(0.0, hup[0][0] - k), alive - k))

    # 3. what is typed reaches a tty process
    rows = read_log("tty-typed")
    got = [r for r in rows if r[1] == "state" and "read=5/-" in r[2]]
    hup = [r for r in rows if r[1] == "state" and ("poll0=0x10" in r[2] or "read=0/" in r[2])]
    if not got:
        fail("tty-typed: the five bytes typed at the terminal did not reach the process")
    elif hup:
        fail("tty-typed: the connected session shows a hang-up")
    else:
        print("[precondition] tty exec, client connected: what the terminal types reaches the process (read = 5 bytes), and nothing hangs up")
finally:
    for c in clients.values():
        c.stop()
    for label in ("tty-killed", "pipe-killed", "tty-typed"):
        for p in E.probe_pids(["/lab/watch", label, "30"]):
            try:
                os.kill(p, signal.SIGKILL)
            except ProcessLookupError:
                pass
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || fail "the exec sessions do not behave as the lab was built to"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container app stopped"
echo "[precondition] OK: the problem is there. A tty exec process gets no passive signal when its client is gone; a non-tty one gets POLLHUP and EOF; typed input reaches the tty process."
