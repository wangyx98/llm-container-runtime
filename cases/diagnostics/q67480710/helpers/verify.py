"""verify.py WORK SECONDS : compare what the local JSON collector received from Fluent Bit with the lines the containers logged.

Every line a container wrote must arrive as ONE record whose key `log` is the text of the line exactly as the application wrote it (the CRI
envelope, the timestamp, the stream and the F/P flag, is the only thing that goes) and whose key `stream` is stdout or stderr, the stream the
application wrote it on. The lines are told apart by their marker (NAME-SEQ-HEX, the first thing of the text). Polls the collector for up to SECONDS
seconds and succeeds as soon as the records are exactly the lines of both containers (each container's lines in the order logged); otherwise prints
ONE line, the first thing that is wrong, and exits 1."""
import json
import re
import sys
import time

work, seconds = sys.argv[1], float(sys.argv[2])
NAMES = ("app", "sidecar")
ENVELOPE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d) (stdout|stderr) [FP] ")
MARKER = re.compile(r"\b(app|sidecar)-(\d{4})-[0-9a-f]{8}\b")
want = {n: [tuple(x) for x in json.load(open("%s/.bench/%s.lines.json" % (work, n)))] for n in NAMES}
total = sum(len(v) for v in want.values())


def records():
    out = []
    for line in open(work + "/.bench/records.jsonl", "rb").read().split(b"\n"):
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def short(s, n=80):
    s = s.replace("\x1b", "<ESC>").replace("\n", "\\n").replace("\t", "\\t")
    return s if len(s) <= n else s[:n] + "..."


def diagnose(recs):
    """None when the records are the lines; else the first thing wrong"""
    if not recs:
        return "the collector has received no record from Fluent Bit"
    bad = [r for r in recs if not isinstance(r.get("log"), str)]
    if bad:
        return "%d records have no `log` key (their keys: %s)" % (len(bad), ",".join(sorted(bad[0].keys()))[:60])
    got = {n: [] for n in NAMES}
    nomark = []
    for r in recs:
        m = MARKER.search(r["log"])
        if m:
            got[m.group(1)].append((m.group(0), r))
        else:
            nomark.append(r)
    env = [r["log"] for n in NAMES for _, r in got[n] if ENVELOPE.match(r["log"])]
    if env:
        return "%d of %d records still carry the CRI envelope (timestamp, stream, flag) in `log`, e.g. %s" % (len(env), len(recs), short(env[0]))
    index = {}
    for n in NAMES:
        for i, (stream, text) in enumerate(want[n]):
            index[text.split(" ", 1)[0]] = (n, i, stream, text)
    for n in NAMES:
        for marker, r in got[n]:
            if marker in index and r["log"] != index[marker][3]:
                return "the log of %s is not the text the application wrote; it is: %s" % (marker, short(r["log"], 100))
    for n in NAMES:
        for marker, r in got[n]:
            if marker in index and r.get("stream") != index[marker][2]:
                return "the stream of %s is %s, not %s" % (marker, json.dumps(r.get("stream")), index[marker][2])
    seen = {}
    for n in NAMES:
        for marker, r in got[n]:
            seen.setdefault(marker, []).append(r)
    twice = [m for m, rs in seen.items() if len(rs) > 1]
    if twice:
        return "%d lines arrived more than once, e.g. %s" % (len(twice), twice[0])
    missing = [t.split(" ", 1)[0] for n in NAMES for _, t in want[n] if t.split(" ", 1)[0] not in seen]
    if missing:
        return "%d of the %d lines never reached the collector, e.g. %s" % (len(missing), total, missing[0])
    unknown = [m for m in seen if m not in index]
    if unknown or nomark:
        return "%d records are none of the lines logged, e.g. %s" % (len(unknown) + len(nomark), short((nomark[0]["log"] if nomark else unknown[0]), 60))
    for n in NAMES:
        order = [m for m, _ in got[n]]
        if order != [t.split(" ", 1)[0] for _, t in want[n]]:
            return "the lines of %s did not arrive in the order they were logged" % n
    return None


end = time.time() + seconds
while True:
    recs = records()
    why = diagnose(recs)
    if why is None:
        print("app: %d lines, sidecar: %d lines, %d records: one record per line, `log` byte for byte what the application wrote, `stream` as logged"
              % (len(want["app"]), len(want["sidecar"]), len(recs)))
        sys.exit(0)
    if time.time() >= end:
        print(why)
        sys.exit(1)
    time.sleep(0.5)
