#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there, measured from three sides:
#  - the lab's files are unchanged; the node's containerd is the 1.6.17 of the lab; the container is Running (the one setup started) and its CRI log file grows with `TIMESTAMP stdout F TEXT` lines, one every half
#    second, reachable through the kubelet-style symlink in containers/; Fluent Bit (the lab's 2.0.3, the question's configuration) and the lab's syslog daemon run;
#  - the problem: nothing receives syslog on 127.0.0.1:514/udp (no socket bound to the port, a connected UDP socket is refused), the syslog daemon's log is empty, Fluent Bit's log has `failed to flush chunk`
#    (and `cannot be retried`) for the syslog output and its counters show retries or drops and next to no record sent (the first datagram to a closed UDP port is accepted by the kernel);
#  - the configuration is not the problem: with a throw-away receiver on 127.0.0.1:514 for a few seconds, the same Fluent Bit delivers the container's lines as valid RFC 5424 messages (the text is the
#    record's `message`, the TIMESTAMP is the CRI line's); the receiver is closed again before the task starts.

CASE_ID="bench74310243"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LOGROOT="$LIB/var/log"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node, the container, Fluent Bit and the syslog daemon..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the node's containerd is not v1.6.17"
read -r POD CID < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container is not running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container is not the one setup started"
SPID=$(sudo cat "$RUN/syslogd.pid" 2>/dev/null)
[ -n "$SPID" ] && [ "$(sudo readlink "/proc/$SPID/exe")" = "$(sudo cat "$STATE_DIR/syslogd.exe")" ] && sudo tr '\0' ' ' < "/proc/$SPID/cmdline" | grep -qF "$LIB/syslogd/syslogd" || fail "the lab's syslog daemon is not running"
FPID=$(sudo cat "$RUN/fluent-bit.pid" 2>/dev/null)
[ -n "$FPID" ] && [ "$(sudo readlink "/proc/$FPID/exe")" = "$(sudo cat "$STATE_DIR/fb.exe")" ] || fail "Fluent Bit (the program of the lab) is not running"
grep -q "v2.0.3" <("$LIB/fb/bin/fluent-bit" --version 2>&1) || fail "Fluent Bit is not 2.0.3"

echo "[precondition] the container's log in the kubelet's layout..."
LINK=$(ls "$LOGROOT"/containers/*.log 2>/dev/null)
[ "$(echo "$LINK" | wc -l)" = 1 ] && [ -L "$LINK" ] && [ "$(sudo readlink -f "$LINK")" = "$LOGROOT/pods/default_app-pod_uid74310243/app/0.log" ] || fail "containers/*.log is not one symlink to the container's log file"
TOKEN=$(sudo cat "$STATE_DIR/token")
sudo tail -n 3 "$LINK" | python3 -c "
import re, sys
for l in sys.stdin:
    assert re.match(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+(Z|[+-]\d\d:\d\d) stdout F bench74310243 $TOKEN \d+$', l.rstrip('\n')), repr(l)
" || fail "the container's log lines are not in the CRI format"
A=$(sudo cat "$LINK" | wc -l); sleep 2; B=$(sudo cat "$LINK" | wc -l)
[ "$B" -ge $((A + 3)) ] || fail "the container logs less than a line every half second"

echo "[precondition] nothing receives on 127.0.0.1:514/udp..."
sudo python3 -I - <<'PYEOF' || fail "something listens on udp 514, or a datagram to it is not refused"
import socket, sys
for l in open("/proc/net/udp").readlines()[1:]:
    f = l.split()
    if f[1].endswith(":0202") and f[3] == "07":
        sys.exit("a socket is bound to port 514")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(("127.0.0.1", 514))
refused = False
for _ in range(3):
    try:
        s.send(b"x")
    except ConnectionRefusedError:
        refused = True
    import time; time.sleep(0.05)
sys.exit(0 if refused else "datagrams to 127.0.0.1:514 are not refused")
PYEOF
[ ! -s "$RUN/syslog.jsonl" ] || fail "the syslog daemon has received something already"
sudo tail -n 1 "$RUN/syslogd.err" | grep -q "no network listeners" || fail "the syslog daemon listens on the network"

echo "[precondition] Fluent Bit cannot flush (up to 30 s)..."
ok=0
for _ in $(seq 30); do
    n=$(sudo grep -c "failed to flush chunk .*output=syslog.0" "$RUN/fluent-bit.log")
    [ "$n" -ge 2 ] && { ok=1; break; }
    sleep 1
done
[ "$ok" = 1 ] || fail "Fluent Bit's log has no 'failed to flush chunk' for the syslog output"
M=$(curl -s --max-time 5 "http://127.0.0.1:20310/api/v1/metrics")
echo "$M" | python3 -c "
import json, sys
d = json.load(sys.stdin)
o, n = d['output']['syslog.0'], d['input']['tail.0']['records']
# the first datagram to a closed UDP port is accepted by the kernel (the refusal comes back afterwards), so a record or two may count as sent; what matters: most records are not, and chunks are retried or dropped
assert n >= 6 and o['proc_records'] * 2 < n and o['errors'] + o['retries'] + o['retries_failed'] + o['dropped_records'] > 0, (o, n)
" || fail "Fluent Bit's counters do not show an output that fails and sends next to nothing ($M)"

echo "[precondition] the configuration is fine: a throw-away receiver on 127.0.0.1:514 for 10 s..."
sudo python3 -I - "$TOKEN" <<'PYEOF' || fail "with a receiver on 127.0.0.1:514 Fluent Bit does not deliver valid RFC 5424 messages with the container's lines"
import re, socket, sys, time
tok = sys.argv[1]
RFC = re.compile(r"^<(\d{1,3})>1 (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)) (\S{1,255}) (\S{1,48}) (\S{1,128}) (\S{1,32}) (-|\[.*?\])(?: (.*))?$", re.S)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 514))
s.settimeout(0.5)
got = []
end = time.time() + 10
while time.time() < end:
    try:
        got.append(s.recv(65535).decode("utf-8", "replace"))
    except socket.timeout:
        pass
s.close()
good = 0
for d in got:
    m = RFC.match(d.rstrip("\n"))
    if m and int(m.group(1)) < 192 and re.match(r"^\ufeff?bench74310243 %s \d+$" % tok, m.group(8) or ""):
        good += 1
if good < 3:
    sys.exit("only %d valid messages of %d datagrams (first: %r)" % (good, len(got), got[:1]))
print("  %d valid RFC 5424 messages in 10 s, e.g. %r" % (good, got[0][:120]))
PYEOF
sudo python3 -I - <<'PYEOF' || fail "the throw-away receiver is still bound"
import sys
for l in open("/proc/net/udp").readlines()[1:]:
    f = l.split()
    if f[1].endswith(":0202") and f[3] == "07":
        sys.exit(1)
PYEOF
[ ! -s "$RUN/syslog.jsonl" ] || fail "the lab's syslog daemon received something"

echo "[precondition] OK: the container logs in the CRI format, Fluent Bit cannot flush to 127.0.0.1:514/udp because nothing listens there, and it delivers valid RFC 5424 when something does."
