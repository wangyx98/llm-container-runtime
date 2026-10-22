#!/bin/bash
# Oracle: a program /probe/detect in the container tells, from inside, once, that the client of its exec session is gone - and only then. Five exec sessions run side by side in the container app,
# each is `crictl exec -i [-t] app /probe/detect TOKEN` with a token of its own, the clients are those of the lab (execlab.py):
#   tty-kill   a terminal session (the "person" is a terminal emulator that answers the cursor position query), the client is killed with SIGKILL after 3 to 6 s
#   tty-term   the same, the client is ended with SIGTERM
#   pipe-kill  a session without terminal, stdin a pipe that stays open and silent, the client is killed with SIGKILL
#   tty-ctl    a terminal session whose client stays (control)
#   pipe-ctl   a session without terminal whose client stays (control)
# For the three killed sessions: exactly one report with the token, within 8 s of the kill (and not before it), made by the process of the session itself (the unix socket /out/events.sock, the kernel
# tells who connected: its pid must be the one of the exec process /probe/detect TOKEN). For the two controls: no report during the 22 s the sessions last, and the process is still there. The program may not
# write more than 2 KB to a session in all (a flood of output is a signal of its own: after 126 KB the pseudo terminal fills; it is not a way to ask a person at a terminal). The node and the container app
# are as they were: the lab's files unchanged, the same containerd 1.7.20 and the same container app, still running.

CASE_ID="bench78687277"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files, the node's containerd and the container app..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.7.20" || fail "the node's containerd is not v1.7.20"
read -r POD CID < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container app is not running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container app is not the one setup started"
[ -f "$LIB/probe/detect" ] && [ -x "$LIB/probe/detect" ] || fail "there is no executable $LIB/probe/detect"

echo "[oracle] five exec sessions side by side (about 25 s)..."
sudo python3 -I - "$CID" <<'PYEOF'
import os
import random
import signal
import sys
import time

sys.path.insert(0, "/var/lib/bench78687277/bin")
import execlab as E

cid = sys.argv[1]
WINDOW = 8.0            # seconds after the kill in which the report has to arrive
SESSION = 22.0          # seconds the sessions last (longer than the latest kill plus the window)
QUIET = 2048            # bytes a program may write to its session
rnd = random.Random()
rows = [("tty-kill", True, signal.SIGKILL, rnd.uniform(3, 6)), ("tty-term", True, signal.SIGTERM, rnd.uniform(3, 6)), ("pipe-kill", False, signal.SIGKILL, rnd.uniform(3, 6)),
        ("tty-ctl", True, None, None), ("pipe-ctl", False, None, None)]
token = {name: "%s-%s" % (name, "%08x" % rnd.getrandbits(32)) for name, *_ in rows}
bad = []
clients = {}
col = E.Collector("/run/bench78687277/out/events.sock")


def fail(msg):
    bad.append(msg)
    print("[oracle] FAIL: " + msg)


try:
    t0 = time.time()
    for name, tty, _, _ in rows:
        clients[name] = E.Client(cid, ["/probe/detect", token[name]], tty).start()
    # the host pid of every program (the exec process as the host sees it) and its pid in the container
    host = {}
    nsp = {}
    for _ in range(100):
        for name, *_ in rows:
            if name not in host:
                p = E.probe_pids(["/probe/detect", token[name]])
                if p:
                    host[name] = p[0]
                    nsp[name] = E.nspid(p[0])
        if len(host) == len(rows):
            break
        time.sleep(0.1)
    pending = {name: dl for name, _, _, dl in rows if dl is not None}
    while time.time() - t0 < SESSION:
        for name, sig, dl in [(n, s, d) for n, _, s, d in rows if d is not None]:
            if name in pending and time.time() - t0 >= pending[name]:
                clients[name].kill(sig)
                del pending[name]
        time.sleep(0.05)
    still = {name: bool(E.probe_pids(["/probe/detect", token[name]])) for name, *_ in rows}

    for name, tty, sig, dl in rows:
        ev = [e for e in col.events if e[2] == token[name]]
        other = [e for e in col.events if e[2] != token[name] and e[2] not in token.values()]
        c = clients[name]
        if name not in host:
            if ev:
                fail("%s: the program reported a disconnect %.1f s after the start, before any client was ended, and ended" % (name, ev[0][0] - t0))
            else:
                fail("%s: no process /probe/detect %s in the container 10 s after the exec started (the client printed: %r)" % (name, token[name], clients[name].out[-200:]))
        else:
            if dl is None:
                if ev:
                    fail("%s: the client is connected and the program reported a disconnect (%.1f s after the start)" % (name, ev[0][0] - t0))
                elif not still[name]:
                    fail("%s: the program ended without a word while its client was connected" % name)
                else:
                    print("[oracle] %s: connected for %.0f s, no report, the program is running: ok" % (name, SESSION))
            else:
                if not ev:
                    fail("%s: the client was ended at %.1f s and the program reported nothing within %.0f s" % (name, c.killed_at - t0, SESSION - dl))
                elif len(ev) > 1:
                    fail("%s: the program reported %d times, once is the contract" % (name, len(ev)))
                else:
                    late = ev[0][0] - c.killed_at
                    if late < -0.05:
                        fail("%s: the report came %.1f s BEFORE the client was ended" % (name, -late))
                    elif late > WINDOW:
                        fail("%s: the report came %.1f s after the client was ended, the limit is %.0f s" % (name, late, WINDOW))
                    elif ev[0][1] != host[name]:
                        fail("%s: the report was not made by the exec process itself (the sender is pid %d, the process is pid %d)" % (name, ev[0][1], host[name]))
                    else:
                        print("[oracle] %s: client ended at %.1f s, one report %.1f s later from the exec process itself (pid %s in the container): ok" % (name, c.killed_at - t0, max(0.0, late), nsp[name] or "?"))
        if len(c.out) > QUIET:
            fail("%s: the program wrote %d bytes to its session, 2 KB is the limit" % (name, len(c.out)))
    if [e for e in col.events if e[2] not in token.values()]:
        fail("the socket got a line that is no token of this check: %r" % [e[2] for e in col.events if e[2] not in token.values()][:3])
finally:
    for c in clients.values():
        c.stop()
    for name in token:
        for p in E.probe_pids(["/probe/detect", token[name]]):
            try:
                os.kill(p, signal.SIGKILL)
            except ProcessLookupError:
                pass
    col.close()
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || exit 1

echo "[oracle] the container app after the sessions..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container app is no longer running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container app was restarted"
echo "[oracle] OK: both kinds of session report once, from inside, within 8 s of the client's end; the connected controls report nothing; the container app kept running."
