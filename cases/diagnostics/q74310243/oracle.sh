#!/bin/bash
# Oracle: the container's NEW log lines reach the lab's syslog daemon through Fluent Bit, as valid RFC 5424 messages, each exactly once and in order, and Fluent Bit no longer fails to flush. Measured here:
#  - the lab's files (the daemon, the tools, Fluent Bit, the node's programs, the definitions) are unchanged; containerd, the container, the daemon and Fluent Bit are the lab's processes and keep running
#    the same (no restart during the check); only the two configuration files (syslogd.conf, fluent-bit.conf) are for the task;
#  - for 18 s the container goes on logging; the lines whose CRI timestamp lies in the window [start+4 s, end-2 s] (about 24 lines) are the ones judged, 5 s after the end the daemon's log is read: each such line
#    arrived once (no duplicate anywhere in the log, no datagram that is not a line of the container), in the order of the CRI file, as an RFC 5424 message (PRI, version 1, TIMESTAMP, HOSTNAME, APP-NAME,
#    PROCID, MSGID, STRUCTURED-DATA, then the text with or without a BOM) whose text is the line's text and whose TIMESTAMP is the CRI line's own (to the microsecond);
#  - Fluent Bit's own evidence: its log has no `failed to flush chunk` / `cannot be retried` for the syslog output after the start of the check, and its monitoring counters show at least as many records
#    sent by the syslog output as there are judged lines (a shipper of the solution's own, or a message written with logger, would not move them).
# Lines logged before the receiver was up are not required: Fluent Bit tries a chunk once more and drops it (Retry_Limit 1).

CASE_ID="bench74310243"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LOGROOT="$LIB/var/log"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files, the node, the container, the daemon and Fluent Bit..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
read -r POD CID < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container is not running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container is not the one setup started"
SPID=$(sudo cat "$RUN/syslogd.pid" 2>/dev/null)
[ -n "$SPID" ] && [ "$(sudo readlink "/proc/$SPID/exe")" = "$(sudo cat "$STATE_DIR/syslogd.exe")" ] && sudo tr '\0' ' ' < "/proc/$SPID/cmdline" | grep -qF "$LIB/syslogd/syslogd" || fail "the lab's syslog daemon is not running"
FPID=$(sudo cat "$RUN/fluent-bit.pid" 2>/dev/null)
[ -n "$FPID" ] && [ "$(sudo readlink "/proc/$FPID/exe")" = "$(sudo cat "$STATE_DIR/fb.exe")" ] && [ "$(sudo cat "/proc/$FPID/comm")" = fluent-bit ] || fail "Fluent Bit (the program of the lab) is not running"
LINK=$(ls "$LOGROOT"/containers/*.log 2>/dev/null)
[ "$(echo "$LINK" | wc -l)" = 1 ] && [ -L "$LINK" ] || fail "containers/*.log is not one symlink"
TOKEN=$(sudo cat "$STATE_DIR/token")

echo "[oracle] 18 s of logging, then 5 s for the last lines to arrive..."
sudo python3 -I - "$RUN" "$LINK" "$TOKEN" "$SPID" "$FPID" <<'PYEOF'
import calendar
import json
import re
import sys
import time
import urllib.request

run, link, token, spid, fpid = sys.argv[1:6]
WINDOW, LEAD, TAIL, GRACE = 18.0, 4.0, 2.0, 5.0
bad = []


def micro(ts):
    """epoch microseconds of an RFC 3339 time with a fraction (CRI: up to ns, RFC 5424: up to us), truncated to the microsecond"""
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$", ts)
    if not m:
        return None
    s = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    if m.group(3) != "Z":
        s -= (1 if m.group(3)[0] == "+" else -1) * (int(m.group(3)[1:3]) * 3600 + int(m.group(3)[4:6]) * 60)
    return s * 1000000 + int(((m.group(2) or "") + "000000")[:6])


def metrics():
    try:
        o = json.load(urllib.request.urlopen("http://127.0.0.1:20310/api/v1/metrics", timeout=5))["output"]["syslog.0"]
        return o
    except Exception as e:
        return {"error": str(e)}


def fb_log_size():
    import os
    return os.path.getsize(run + "/fluent-bit.log")


T0 = time.time()
jsonl0 = 0
fb0 = fb_log_size()
m0 = metrics()
time.sleep(WINDOW)
T1 = time.time()
time.sleep(GRACE)

# the same processes, still running
for what, pid in (("the syslog daemon", spid), ("Fluent Bit", fpid)):
    try:
        open("/proc/%s/comm" % pid).read()
    except OSError:
        bad.append("%s (pid %s) was restarted or died during the check" % (what, pid))

# the container's lines
lines = []
for l in open(link, errors="replace"):
    m = re.match(r"^(\S+) stdout F bench74310243 %s (\d+)$" % token, l.rstrip("\n"))
    if m:
        lines.append((micro(m.group(1)), int(m.group(2)), m.group(1)))
lo, hi = (T0 + LEAD) * 1e6, (T1 - TAIL) * 1e6
judged = [x for x in lines if x[0] is not None and lo <= x[0] <= hi]
print("  the container logged %d lines in the window, %d are judged (seq %s..%s)" % (len([x for x in lines if x[0] and T0 * 1e6 <= x[0] <= T1 * 1e6]), len(judged), judged[0][1] if judged else "-", judged[-1][1] if judged else "-"))
if len(judged) < 20:
    bad.append("the container logged only %d judged lines" % len(judged))

# what the daemon received
RFC = re.compile(r"^<(\d{1,3})>1 (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)) (\S{1,255}) (\S{1,48}) (\S{1,128}) (\S{1,32}) (-|\[.*?\])(?: (.*))?$", re.S)
recv = []
try:
    rows = [json.loads(l) for l in open(run + "/syslog.jsonl") if l.strip()]
except OSError:
    rows = []
unexpected = invalid = 0
for r in rows:
    m = RFC.match(r["raw"].rstrip("\n"))
    if not m or int(m.group(1)) >= 192:
        invalid += 1
        continue
    t = re.match(r"^\ufeff?bench74310243 %s (\d+)$" % token, m.group(8) or "")
    if not t:
        unexpected += 1
        continue
    recv.append((int(t.group(1)), micro(m.group(2)), r["t"]))
print("  the daemon's log: %d datagrams, %d are container lines, %d invalid RFC 5424, %d other texts" % (len(rows), len(recv), invalid, unexpected))
if invalid:
    bad.append("%d datagrams are not valid RFC 5424 messages" % invalid)
if unexpected:
    bad.append("%d datagrams are not lines of the container" % unexpected)
seen = {}
for seq, ts, t in recv:
    seen[seq] = seen.get(seq, 0) + 1
dups = sorted(s for s, n in seen.items() if n > 1)
if dups:
    bad.append("delivered more than once: seq %s" % dups[:8])
missing = [x[1] for x in judged if x[1] not in seen]
if missing:
    bad.append("%d of %d judged lines never arrived (seq %s)" % (len(missing), len(judged), missing[:8]))
by_seq = {x[1]: x for x in judged}
wrong_ts = [seq for seq, ts, t in recv if seq in by_seq and (ts is None or abs(ts - by_seq[seq][0]) > 1)]
if wrong_ts:
    bad.append("TIMESTAMP is not the CRI line's own for seq %s" % wrong_ts[:8])
order = [seq for seq, ts, t in recv if seq in by_seq]
if order != sorted(order):
    bad.append("the judged lines arrived out of order: %s" % order[:12])

# Fluent Bit's own evidence
fb_new = open(run + "/fluent-bit.log", errors="replace").read().encode("utf-8", "replace")[fb0:].decode("utf-8", "replace")
fails = [l for l in fb_new.splitlines() if re.search(r"failed to flush chunk|cannot be retried", l) and "output=syslog.0" in l]
if fails:
    bad.append("Fluent Bit still fails to flush after the start of the check (%d lines, e.g. %s)" % (len(fails), fails[0][:160]))
m1 = metrics()
if "error" in m1 or "proc_records" not in m1:
    bad.append("Fluent Bit's monitoring server gives no counters of the syslog output (%s)" % m1)
else:
    base = m0.get("proc_records", 0) if "proc_records" in m0 else 0
    sent = m1["proc_records"] - base if m1["proc_records"] >= base else m1["proc_records"]
    print("  Fluent Bit's counters: syslog.0 proc_records +%d (judged lines: %d)" % (sent, len(judged)))
    if sent < len(judged):
        bad.append("Fluent Bit's syslog output sent %d records in the check, fewer than the %d judged lines" % (sent, len(judged)))

if bad:
    for b in bad:
        print("[oracle] FAIL: " + b)
    sys.exit(1)
print("[oracle] PASS: %d lines of the container logged in the window arrived once, in order, as valid RFC 5424 with their own timestamps; Fluent Bit flushes without failures." % len(judged))
PYEOF
