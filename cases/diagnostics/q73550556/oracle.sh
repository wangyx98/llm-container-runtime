#!/bin/bash
# Oracle: containerd's spans reach the collector, for operations the check itself performs now, and containerd keeps working. Measured here:
#  - the lab's files (the node's programs, the tools, the collector, its configuration, the definitions) are unchanged; containerd and the collector are the lab's processes and run; the container setup
#    started is the same one (same start time), still Running, and its log still grows: tracing must not cost the workload (only containerd.toml and the restart of containerd are for the task);
#  - the log of containerd's CURRENT start has no `failed to initialize a tracing processor` and no failed otlp plugin, i.e. the question's line is gone because the processor is configured and loaded;
#  - then, with random numbers N1 (2..5) and N2 (2..5) and a random name, the check calls `crictl pods` N1 times, `crictl images` N2 times and runs a new pod `trace-<random>` with a container `app-<random>`
#    (the pod's and the container's ids are known only from these calls); the new container must run and log. A span counts only if it started after the check began. Judged on the spans in the collector's
#    file (the collector is the only way in: a span written some other way would not carry the ids): exactly N1 ListPodSandbox and exactly N2 ListImages spans, one RunPodSandbox span whose events name the pod
#    and return the pod's id, one CreateContainer span for that pod, that container name, returning the container's id, and one StartContainer span for that id; all with gRPC status 0.
#    Spans leave containerd in batches every 5 s: the check waits for them (at most 40 s) and a further 6 s before it counts, to see spans that should not be there.

CASE_ID="bench73550556"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CRICTL="$LIB/bin/crictl"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files, containerd, the collector, the container of setup..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] && [ "$(sudo cat "/proc/$CPID/comm")" = containerd ] || fail "the node's containerd (the program of the lab) is not running"
sudo "$CRICTL" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.8" || fail "containerd does not answer CRI calls"
OPID=$(sudo cat "$RUN/otelcol.pid" 2>/dev/null)
[ -n "$OPID" ] && [ "$(sudo readlink "/proc/$OPID/exe")" = "$(sudo cat "$STATE_DIR/otel.exe")" ] && [ "$(sudo cat "/proc/$OPID/comm")" = otelcol ] || fail "the collector (the program of the lab) is not running"
[ "$OPID" = "$(sudo cat "$STATE_DIR/otel.pid")" ] || fail "the collector was restarted"
read -r POD0 CID0 < <(sudo cat "$STATE_DIR/pod.txt")
[ "$(sudo "$CRICTL" inspect --output go-template --template '{{.status.state}}' "$CID0" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the container of setup is not running"
[ "$(sudo "$CRICTL" inspect --output go-template --template '{{.status.startedAt}}' "$CID0" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/started.txt")" ] || fail "the container is not the one setup started"
TOKEN=$(sudo cat "$STATE_DIR/token")
A=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/app/0.log"); sleep 2; B=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/app/0.log")
[ "$B" -ge $((A + 3)) ] || fail "the container of setup logs less than a line every half second"

echo "[oracle] the log of the current start of containerd..."
sudo python3 -I - "$RUN/containerd.log" <<'PYEOF' || exit 1
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
start = max(i for i, l in enumerate(lines) if 'msg="starting containerd"' in l)
bad = [l for l in lines[start:] if "failed to initialize a tracing processor" in l or "failed to load plugin io.containerd.tracing" in l or "no OpenTelemetry endpoint" in l and "level=error" in l]
if bad:
    print("[oracle] FAIL: containerd's log of its current start still has: " + bad[0][:300])
    sys.exit(1)
PYEOF

NONCE=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
N1=$((2 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 4))
N2=$((2 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 4))
NAME="trace-$NONCE"
CNAME="app-$NONCE"
echo "[oracle] random operations: $N1 x 'crictl pods', $N2 x 'crictl images', pod $NAME with container $CNAME..."
sudo mkdir -p "$RUN/log/$NAME"
sudo tee "$WORK_DIR/pod-$NONCE.json" >/dev/null <<PEOF
{
  "metadata": {"name": "$NAME", "namespace": "default", "uid": "uid$NONCE", "attempt": 1},
  "log_directory": "$RUN/log/$NAME",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
sudo tee "$WORK_DIR/ctr-$NONCE.json" >/dev/null <<CEOF
{
  "metadata": {"name": "$CNAME"},
  "image": {"image": "$CASE_ID.local/app:1"},
  "log_path": "app/0.log",
  "linux": {}
}
CEOF
T0=$(date +%s%N)
for _ in $(seq "$N1"); do sudo "$CRICTL" pods >/dev/null 2>&1 || fail "crictl pods failed"; done
for _ in $(seq "$N2"); do sudo "$CRICTL" images >/dev/null 2>&1 || fail "crictl images failed"; done
POD=$(sudo "$CRICTL" runp "$WORK_DIR/pod-$NONCE.json" 2>&1 | tail -1)
[ ${#POD} = 64 ] || fail "a new pod does not start: $POD"
CID=$(sudo "$CRICTL" create "$POD" "$WORK_DIR/ctr-$NONCE.json" "$WORK_DIR/pod-$NONCE.json" 2>&1 | tail -1)
[ ${#CID} = 64 ] || fail "a new container is not created: $CID"
sudo "$CRICTL" start "$CID" >/dev/null 2>&1 || fail "the new container does not start"
sleep 2
[ "$(sudo "$CRICTL" inspect --output go-template --template '{{.status.state}}' "$CID" 2>/dev/null)" = CONTAINER_RUNNING ] || fail "the new container is not running"
sudo grep -q "bench73550556 $TOKEN " "$RUN/log/$NAME/app/0.log" 2>/dev/null || fail "the new container does not log"
A=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/$NAME/app/0.log"); sleep 2; B=$(sudo grep -c "bench73550556 $TOKEN " "$RUN/log/$NAME/app/0.log")
[ "$B" -gt "$A" ] || fail "the new container does not go on logging"
sudo "$CRICTL" rmp -f "$POD" >/dev/null 2>&1 || fail "the new pod cannot be removed"

echo "[oracle] the spans in the collector's file (up to 40 s, then 6 s more)..."
sudo python3 -I - "$RUN/spans.jsonl" "$T0" "$N1" "$N2" "$NAME" "$CNAME" "$POD" "$CID" <<'PYEOF'
import collections
import json
import sys
import time

path, t0, n1, n2, name, cname, pod, cid = sys.argv[1:9]
t0, n1, n2 = int(t0), int(n1), int(n2)


def spans():
    out = []
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return out
    for l in lines:
        try:
            d = json.loads(l)
        except ValueError:
            continue
        for rs in d.get("resourceSpans", []):
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    try:
                        if int(sp["startTimeUnixNano"]) >= t0:
                            out.append(sp)
                    except (KeyError, ValueError):
                        pass
    return out


def status0(sp):
    for a in sp.get("attributes", []):
        if a["key"] == "rpc.grpc.status_code":
            return a["value"].get("intValue") == "0"
    return False


def events(sp):
    return [e.get("name", "") for e in sp.get("events", [])]


def verdict(sps):
    c = collections.Counter(sp["name"].rsplit("/", 1)[-1] for sp in sps)
    probs = []
    if c["ListPodSandbox"] != n1:
        probs.append("ListPodSandbox spans: %d, the check made %d calls" % (c["ListPodSandbox"], n1))
    if c["ListImages"] != n2:
        probs.append("ListImages spans: %d, the check made %d calls" % (c["ListImages"], n2))
    run = [sp for sp in sps if sp["name"].endswith("/RunPodSandbox") and status0(sp) and any("Name:%s," % name in e and 'returns sandbox id "%s"' % pod in e for e in events(sp))]
    if len(run) != 1:
        probs.append("no RunPodSandbox span for pod %s (id %s...) with status 0" % (name, pod[:12]))
    cre = [sp for sp in sps if sp["name"].endswith("/CreateContainer") and status0(sp) and any('within sandbox "%s"' % pod in e and "Name:%s," % cname in e and 'returns container id "%s"' % cid in e for e in events(sp))]
    if len(cre) != 1:
        probs.append("no CreateContainer span for container %s (id %s...) with status 0" % (cname, cid[:12]))
    sta = [sp for sp in sps if sp["name"].endswith("/StartContainer") and status0(sp) and any('StartContainer for "%s" returns successfully' % cid in e for e in events(sp))]
    if len(sta) != 1:
        probs.append("no StartContainer span for container id %s... with status 0" % cid[:12])
    return c, probs


deadline = time.time() + 40
while time.time() < deadline:
    c, probs = verdict(spans())
    if not probs:
        break
    time.sleep(1)
if not probs:
    time.sleep(6)
    c, probs = verdict(spans())
total = len(spans())
print("  spans received since the check began: %d; by call: %s" % (total, dict(sorted(c.items()))))
if probs:
    for p in probs:
        print("[oracle] FAIL: " + p)
    sys.exit(1)
PYEOF
[ $? = 0 ] || exit 1

echo "[oracle] OK: containerd exports its spans to the collector (the $N1 pod listings, the $N2 image listings and the pod $NAME with container $CNAME are all there) and the workloads run."
