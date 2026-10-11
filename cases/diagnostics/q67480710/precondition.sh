#!/bin/bash
set -e

CASE_ID="bench67480710"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
FB_DIR="$WORK_DIR/fluent-bit"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
PORT=19874

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; bash "$STATE_DIR/flb.sh" stop >/dev/null 2>&1 || true; exit 1; }

echo "[precondition] the node's containerd runs, the helpers and the lab's main.conf are as setup left them, and the collector answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py collector.py flb.sh main.conf initial-pipeline.conf initial-parsers.conf app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
[ "$(sha256sum "$FB_DIR/main.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/main.conf.sha")" ] || fail "$FB_DIR/main.conf was changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:$PORT/', timeout=3).read()" >/dev/null 2>&1 || fail "the local JSON collector does not answer on 127.0.0.1:$PORT"
FLB=$(cat "$STATE_DIR/flb.path")
echo "  -> OK: containerd $(containerd --version | awk '{print $3}'), $("$FLB" --version 2>&1 | head -1)"

echo "[precondition] two real CRI containers of one pod log lines on stdout and stderr; the runtime writes CRI log files in the kubelet layout, and var/log/containers has a symlink to each..."
for name in app sidecar; do
    st=$("${CRI[@]}" ps -a -o json 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin)['containers']:
    if c['metadata']['name'] == '$name': print(c['state'])" | head -1)
    [ "$st" = CONTAINER_RUNNING ] || fail "the $name container is not running ($st)"
done
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$WORK_DIR" <<'PYEOF' || fail "the logs are not what the workloads were told to log"
import json
import os
import re
import sys

work = sys.argv[1]
t = json.load(open(work + "/.bench/truth.json"))
for name, c in t["containers"].items():
    assert re.match(r"^web-0_default_%s-[0-9a-f]{64}\.log$" % name, os.path.basename(c["link"])), "name of the symlink"
    assert os.path.dirname(c["link"]) == work + "/var/log/containers", "directory of the symlink"
    assert c["target"] == "%s/var/log/pods/default_web-0_%s/%s/0.log" % (work, t["uid"], name), "the log file is not in the kubelet layout"
    ls = json.load(open("%s/.bench/%s.lines.json" % (work, name)))
    streams = {s for s, _ in ls}
    assert streams == {"stdout", "stderr"}, "%s logs on %s" % (name, streams)
    print("  -> %s: %d lines (%d on stderr) in %s, a symlink to it in var/log/containers" % (name, len(ls), sum(1 for s, _ in ls if s == "stderr"), os.path.relpath(c["target"], work)))
PYEOF

echo "[precondition] the problem, with the real Fluent Bit: the pipeline the node has today reads the files with the Docker JSON parser; what reaches the collector keeps the CRI timestamp/stream/flag in front of every text..."
python3 - <<PYEOF
import urllib.request
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:$PORT/reset", data=b"", method="POST"), timeout=3).read()
PYEOF
[ "$(sha256sum "$FB_DIR/pipeline.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/pipeline.conf.sha")" ] || fail "$FB_DIR/pipeline.conf is not the node's pipeline of today"
[ "$(sha256sum "$FB_DIR/parsers.conf" | awk '{print $1}')" = "$(cat "$STATE_DIR/parsers.conf.sha")" ] || fail "$FB_DIR/parsers.conf is not the node's parsers file of today"
grep -q "Parser *docker" "$FB_DIR/pipeline.conf" || fail "the node's pipeline does not use the docker parser"
bash "$STATE_DIR/flb.sh" start "$FB_DIR/main.conf" || fail "Fluent Bit does not run with the node's configuration of today"
NLINES=$(python3 -c "import json; print(sum(len(json.load(open('$STATE_DIR/%s.lines.json' % n))) for n in ('app', 'sidecar')))")
python3 - "$STATE_DIR" "$NLINES" <<'PYEOF' || fail "the collection of today is not the problem the question describes (see above)"
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
assert len(with_env) == len(logs) == nlines, "%d records, %d with the envelope, %d lines logged" % (len(logs), len(with_env), nlines)
assert not any("stream" in r for r in recs), "the records have a stream key"
print("  -> %d records for %d lines: every `log` starts with the CRI envelope, e.g. %r, and no record has a `stream`" % (len(logs), nlines, logs[0][:90]))
PYEOF
bash "$STATE_DIR/flb.sh" stop

echo "[precondition] ALL CHECKS PASSED: real CRI containers log on both streams; read with the Docker parser, every record is a whole CRI line with its envelope and no stream."
