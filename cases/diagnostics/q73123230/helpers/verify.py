"""verify.py WORK SECONDS : compare what the local JSON collector received from Fluent Bit with the application events the containers logged.
Every event must be ONE record whose key `log` is the event exactly as the application wrote it: its lines joined by a newline, nothing else
removed or added (the CRI envelope of each line is the only thing that goes). Polls the collector for up to SECONDS seconds and succeeds as soon as
the records are exactly the events of both containers (each container's events in the order logged); otherwise prints ONE line, the first
thing that is wrong, and exits 1."""
import json
import re
import sys
import time

work, seconds = sys.argv[1], float(sys.argv[2])
NAMES = ("alpha", "beta")
ENVELOPE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d) (stdout|stderr) [FP] ", re.M)
APPTS = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d,\d{3}")
MARKER = re.compile(r"\b(alpha|beta)-(\d{4})-[0-9a-f]{8}\b")
exp = {n: ["\n".join(ev) for ev in json.load(open("%s/.bench/%s.events.json" % (work, n)))] for n in NAMES}
total = sum(len(v) for v in exp.values())


def records():
    out = []
    for line in open(work + "/.bench/records.jsonl", "rb").read().split(b"\n"):
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def short(s, n=70):
    s = s.replace("\x1b", "<ESC>").replace("\n", "\\n").replace("\t", "\\t")
    return s if len(s) <= n else s[:n] + "..."


def diagnose(recs):
    """None when the records are the events; else the first thing wrong"""
    if not recs:
        return "the collector has received no record from Fluent Bit"
    bad = [r for r in recs if not isinstance(r.get("log"), str)]
    if bad:
        return "%d records have no `log` key (their keys: %s)" % (len(bad), ",".join(sorted(bad[0].keys()))[:60])
    logs = [r["log"] for r in recs]
    env = [l for l in logs if ENVELOPE.search(l)]
    if env:
        return "%d of %d records still carry the CRI envelope (timestamp, stream, F/P), e.g. %s" % (len(env), len(logs), short(env[0]))
    mixed = [l for l in logs if len({m.group(1) for m in MARKER.finditer(l)}) > 1]
    if mixed:
        return "%d records mix the lines of the two containers, e.g. %s" % (len(mixed), short(mixed[0]))
    nostart = [l for l in logs if not APPTS.match(l)]
    if nostart and len(logs) > total:
        return "events are not joined: %d records for %d events, %d of them do not begin with an application timestamp, e.g. %s" % (
            len(logs), total, len(nostart), short(nostart[0]))
    if all("\x1b" not in l for l in logs):
        return "the ANSI escape sequences are gone from `log`"
    if any(len(line) == 16384 for l in logs for line in l.split("\n")):
        return "a long line is not one line: its 16384-character partial pieces are separate lines of the event"
    if nostart:
        return "%d records do not begin with an application timestamp, e.g. %s" % (len(nostart), short(nostart[0]))
    for n in NAMES:
        mine = [l for l in logs if (MARKER.search(l) or [None, ""])[1] == n]
        if mine == exp[n]:
            continue
        miss = [e for e in exp[n] if e not in mine]
        extra = [l for l in mine if l not in exp[n]]
        if miss or extra:
            e = (miss or extra)[0]
            return "%s: %d events missing, %d records are not an event, e.g. %s" % (n, len(miss), len(extra), short(e))
        if len(mine) != len(exp[n]):
            return "%s: %d records for %d events (an event twice or lost)" % (n, len(mine), len(exp[n]))
        return "%s: the events are not in the order they were logged" % n
    if len(logs) != total:
        return "%d records for %d events" % (len(logs), total)
    return None


end = time.time() + seconds
while True:
    recs = records()
    why = diagnose(recs)
    if why is None:
        print("alpha: %d events, beta: %d events, %d records: each event one record, byte for byte what the application wrote (the long lines whole)"
              % (len(exp["alpha"]), len(exp["beta"]), len(recs)))
        sys.exit(0)
    if time.time() >= end:
        print(why)
        sys.exit(1)
    time.sleep(0.5)
