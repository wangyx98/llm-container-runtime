#!/bin/bash
set -e

CASE_ID="bench73123230"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FB_DIR="$WORK_DIR/fluent-bit"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
APP_REF="$CASE_ID.local/app:1"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; bash "$STATE_DIR/flb.sh" stop >/dev/null 2>&1 || true; exit 1; }

echo "[precondition] the node's containerd runs, the helpers and the lab's main.conf are as setup left them, and the collector answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py collector.py flb.sh naive.conf naive-parsers.conf main.conf app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
[ "$(sha256sum "$FB_DIR/main.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/main.conf.sha")" ] || fail "$FB_DIR/main.conf was changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:19873/', timeout=3).read()" >/dev/null 2>&1 || fail "the local JSON collector does not answer on 127.0.0.1:19873"
FLB=$(cat "$STATE_DIR/flb.path")
echo "  -> OK: containerd $(containerd --version | awk '{print $3}'), $("$FLB" --version 2>&1 | head -1)"

echo "[precondition] two real CRI containers of one pod log the application events (alpha on stdout, beta on stderr) into CRI log files with a 16384-character line limit..."
for name in alpha beta; do
    st=$("${CRI[@]}" ps -a -o json 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin)['containers']:
    if c['metadata']['name'] == '$name': print(c['state'])" | head -1)
    [ "$st" = CONTAINER_RUNNING ] || fail "the $name container is not running ($st)"
    sudo test -s "$WORK_DIR/logs/${name}_0.log" || fail "$WORK_DIR/logs/${name}_0.log is empty"
done
python3 - "$WORK_DIR" <<'PYEOF' || fail "the CRI log files are not what the workloads were told to log"
import json
import re
import subprocess
import sys

work = sys.argv[1]
for name in ("alpha", "beta"):
    raw = subprocess.run(["sudo", "cat", "%s/logs/%s_0.log" % (work, name)], capture_output=True).stdout
    lines = [l for l in raw.split(b"\n") if l]
    tags = [l.split(b" ", 3)[2] for l in lines]
    streams = {l.split(b" ", 3)[1] for l in lines}
    evs = json.load(open("%s/.bench/%s.events.json" % (work, name)))
    assert streams == ({b"stdout"} if name == "alpha" else {b"stderr"}), "%s logs on %s" % (name, streams)
    assert tags.count(b"P") >= 2 and tags[-1] == b"F", "no partial (P) records for the long line"
    assert sum(len(e) for e in evs) <= len(lines), "fewer records than lines"
    print("  -> %s: %d events, %d CRI records (%d partial, P), stream %s" % (name, len(evs), len(lines), tags.count(b"P"), streams.pop().decode()))
PYEOF

echo "[precondition] the problem, with the real Fluent Bit: read with the Docker parser, every record keeps the CRI timestamp/stream/flag and an event is spread over many records..."
python3 - <<'PYEOF'
import urllib.request
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:19873/reset", data=b"", method="POST"), timeout=3).read()
PYEOF
bash "$STATE_DIR/flb.sh" start "$STATE_DIR/naive.conf" || fail "Fluent Bit does not run with the lab's naive configuration"
NLINES=$(for n in alpha beta; do sudo cat "$WORK_DIR/logs/${n}_0.log"; done | wc -l)
python3 - "$STATE_DIR" "$NLINES" <<'PYEOF' || fail "the naive collection is not the problem the question describes (see above)"
import json
import re
import sys
import time

state, nlines = sys.argv[1], int(sys.argv[2])
env = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d) (stdout|stderr) [FP] ")
recs = []
for _ in range(80):
    recs = []
    for l in open(state + "/records.jsonl", "rb").read().split(b"\n"):
        if l.strip():
            try:
                recs.append(json.loads(l))
            except ValueError:
                pass
    if len(recs) >= nlines:
        break
    time.sleep(0.5)
logs = [r.get("log") for r in recs]
assert all(isinstance(l, str) for l in logs), "a record without a `log` key: %s" % recs[:1]
with_env = [l for l in logs if env.match(l)]
assert len(with_env) == len(logs) == nlines, "%d records, %d with the envelope, %d CRI lines" % (len(logs), len(with_env), nlines)
print("  -> %d records for %d CRI lines: every one of them starts with the CRI envelope, e.g. %r" % (len(logs), nlines, logs[0].replace("\x1b", "<ESC>")[:90]))
nev = sum(len(json.load(open("%s/%s.events.json" % (state, n)))) for n in ("alpha", "beta"))
print("  -> %d application events came out as %d records: no event is one record" % (nev, len(logs)))
PYEOF
bash "$STATE_DIR/flb.sh" stop

echo "[precondition] nothing of the solution exists yet..."
[ ! -e "$FB_DIR/pipeline.conf" ] || fail "$FB_DIR/pipeline.conf exists already"
[ "$(sha256sum "$FB_DIR/parsers.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/parsers.conf.sha")" ] || fail "$FB_DIR/parsers.conf has been written to"
echo "[precondition] ALL CHECKS PASSED: real CRI containers log multi-line events; read the way the question reads them, they come out as one record per CRI line, envelope included."
