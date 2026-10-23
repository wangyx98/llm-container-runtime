#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it, the question's message is there, and it is only a message:
#  - the lab's files are unchanged; the node's containerd is the lab's 1.6.8 with the default configuration (the otlp processor has no endpoint); its log of this start has the question's line
#    `failed to initialize a tracing processor "otlp"` ... `no OpenTelemetry endpoint: skip plugin`; the container setup started is Running and its CRI log grows, so containerd is working;
#  - the collector (the lab's OpenTelemetry Collector 0.91.0) runs and listens on 127.0.0.1:4317 (gRPC) and :4318 (HTTP) and its HTTP receiver accepts an (empty) OTLP request;
#  - the problem as the goal sees it: after containerd served CRI calls (version, pods, images) for 8 s, the collector has received no span at all.

CASE_ID="bench73550556"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node, the container, the collector..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.8" || fail "the node's containerd is not v1.6.8"
read -r POD CID < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container is not running"
[ "$(sudo "$LIB/bin/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$CID" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container is not the one setup started"
TOKEN=$(sudo cat "$STATE_DIR/token")
A=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/app/0.log"); sleep 2; B=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/app/0.log")
[ "$B" -ge $((A + 3)) ] || fail "the container logs less than a line every half second"
OPID=$(sudo cat "$RUN/otelcol.pid" 2>/dev/null)
[ -n "$OPID" ] && [ "$(sudo readlink "/proc/$OPID/exe")" = "$(sudo cat "$STATE_DIR/otel.exe")" ] && [ "$(sudo cat "/proc/$OPID/comm")" = otelcol ] || fail "the collector (the program of the lab) is not running"
"$LIB/otelcol/otelcol" --version 2>&1 | grep -q "0.91.0" || fail "the collector is not 0.91.0"

echo "[precondition] the configuration is containerd's default and the question's line is in the log..."
sudo python3 -I - "$LIB/etc/containerd.toml" <<'PYEOF' || fail "the otlp processor of the node's configuration is not the default (no endpoint, protocol unset, insecure false)"
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\[plugins\."io\.containerd\.tracing\.processor\.v1\.otlp"\]\n((?:[ \t]+\w+ = .*\n)+)', s)
sys.exit(0 if m and 'endpoint = ""' in m.group(1) and 'protocol = ""' in m.group(1) and "insecure = false" in m.group(1) else 1)
PYEOF
sudo grep -q 'level=error msg="failed to initialize a tracing processor \\"otlp\\"" error="no OpenTelemetry endpoint: skip plugin"' "$RUN/containerd.log" || fail "the question's line is not in containerd's log"
[ "$(sudo grep -c 'msg="starting containerd"' "$RUN/containerd.log")" = 1 ] || fail "containerd was started more than once"

echo "[precondition] the collector listens on 4317 and 4318 and takes an empty OTLP request..."
sudo python3 -I - <<'PYEOF' || fail "the collector does not listen on 127.0.0.1:4317 and :4318 as an OTLP receiver"
import sys, urllib.request
ports = set()
for l in open("/proc/net/tcp").readlines()[1:]:
    f = l.split()
    if f[3] == "0A" and f[1].startswith("0100007F:"):
        ports.add(int(f[1].split(":")[1], 16))
if not {4317, 4318} <= ports:
    sys.exit("listening: %s" % sorted(ports))
r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:4318/v1/traces", data=b'{"resourceSpans":[]}', headers={"Content-Type": "application/json"}), timeout=5)
sys.exit(0 if r.status == 200 else 1)
PYEOF

echo "[precondition] with no endpoint containerd serves, the collector gets nothing (8 s)..."
sudo "$LIB/bin/crictl" version >/dev/null 2>&1; sudo "$LIB/bin/crictl" pods >/dev/null 2>&1; sudo "$LIB/bin/crictl" images >/dev/null 2>&1
sleep 8
sudo python3 -I - "$RUN/spans.jsonl" <<'PYEOF' || fail "the collector has received spans although containerd has no tracing endpoint"
import json, sys
n = 0
for l in open(sys.argv[1]):
    if l.strip():
        for rs in json.loads(l).get("resourceSpans", []):
            for ss in rs.get("scopeSpans", []):
                n += len(ss.get("spans", []))
sys.exit(1 if n else 0)
PYEOF

echo "[precondition] OK: containerd logs the 'no OpenTelemetry endpoint' error and works normally; the collector is up and has received no span, because tracing is not configured."
