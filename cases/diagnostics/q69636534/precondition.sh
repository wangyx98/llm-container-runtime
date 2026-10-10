#!/bin/bash
set -e

CASE_ID="bench69636534"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT="$WORK_DIR/pods.sh"             # what the solution has to write
NS_B="$CASE_ID-team-b"

CTR_T="sudo ctr -a $T_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
cri_snapshot() {   # every pod sandbox and every container the CRI holds: id, state and metadata, one line each, sorted
    {
        "${CRI[@]}" pods -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    m = p["metadata"]
    print("pod", p["id"], p["state"], m["namespace"], m["name"], m["uid"], m["attempt"])'
        "${CRI[@]}" ps -a -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["containers"]:
    m = c["metadata"]
    print("container", c["id"], c["state"], c["podSandboxId"], m["name"], m["attempt"])'
    } | LC_ALL=C sort
}
expected() {   # the right answer from the records (the files given): the pods that are READY, by uid, with the current (highest attempt) container of each name
    python3 - "$@" <<'PYEOF'
import json
import sys

out = {}
for f in sys.argv[1:]:
    for p in json.load(open(f)):
        if not p["ready"]:
            continue
        cur = {}
        for c in p["containers"]:
            if c["name"] not in cur or c["attempt"] > cur[c["name"]]["attempt"]:
                cur[c["name"]] = c
        out[p["uid"]] = {"namespace": p["namespace"], "name": p["name"], "containers": {n: c["id"] for n, c in sorted(cur.items())}}
print(json.dumps(out, sort_keys=True))
PYEOF
}

echo "[precondition] checking the node's containerd (the process of setup), its CRI, and that nothing was changed..."
for f in t.id config.sha pods.json cri.snapshot mkpod.py; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same t || fail "the node's containerd is not running"
[ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
[ "$(cri_snapshot)" = "$(st cri.snapshot)" ] || fail "the CRI does not hold what setup recorded"
echo "  -> OK"

echo "[precondition] checking every pod and container against the records: the metadata (name, namespace, uid, attempt), the states, the kubelet labels..."
sudo python3 - "$STATE_DIR/pods.json" "$T_SOCK" <<'PYEOF' || fail "a pod or container is not as recorded"
import json
import subprocess
import sys

records, sock = json.load(open(sys.argv[1])), sys.argv[2]


def inspect(kind, ident):
    out = subprocess.check_output(["crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, kind, ident])
    return json.loads(out)


uids, names = set(), []
for i, p in enumerate(records):
    s = inspect("inspectp", p["sandbox"])
    m = s["status"]["metadata"]
    assert (m["name"], m["namespace"], m["uid"]) == (p["name"], p["namespace"], p["uid"]), (p["name"], m)
    assert s["status"]["state"] == ("SANDBOX_READY" if p["ready"] else "SANDBOX_NOTREADY"), (p["name"], s["status"]["state"])
    assert s["status"]["labels"]["io.kubernetes.pod.uid"] == p["uid"]
    uids.add(p["uid"]); names.append(p["name"])
    for c in p["containers"]:
        d = inspect("inspect", c["id"])["status"]
        assert d["metadata"]["name"] == c["name"] and d["metadata"]["attempt"] == c["attempt"], (c, d["metadata"])
        want = {"run": ("CONTAINER_RUNNING", 0), "once": ("CONTAINER_EXITED", 0), "fail": ("CONTAINER_EXITED", 1)}[c["mode"]]
        if p["ready"]:
            assert (d["state"], d["exitCode"]) == want, (c, d["state"], d["exitCode"])
        else:
            assert d["state"] == "CONTAINER_EXITED", (c, d["state"])      # the containers of a stopped pod are stopped with it
        assert d["labels"]["io.kubernetes.pod.uid"] == p["uid"] and d["labels"]["io.kubernetes.container.name"] == c["name"]
assert len(uids) == 4 and sorted(names) == ["idle", "old-job", "web", "web"], names
PYEOF
echo "  -> OK"

echo "[precondition] checking what makes the answer more than a listing: the same pod name in two namespaces, a restarted container (attempt 0 exited, attempt 1"
echo "[precondition] running), a finished container as the newest of its name, a pod without any container, a stopped pod..."
python3 - "$STATE_DIR/pods.json" <<'PYEOF' || fail "the node does not have the traps the case is about"
import json
import sys

recs = json.load(open(sys.argv[1]))
web = [p for p in recs if p["name"] == "web"]
assert len(web) == 2 and web[0]["namespace"] != web[1]["namespace"] and web[0]["uid"] != web[1]["uid"]
app = sorted(c["attempt"] for p in web for c in p["containers"] if c["name"] == "app" and p["namespace"].endswith("team-a"))
assert app == [0, 1]
assert any(c["name"] == "proxy" and c["mode"] == "once" for p in web for c in p["containers"])
assert any(not p["containers"] and p["ready"] for p in recs)
assert any(not p["ready"] for p in recs)
PYEOF
[ "$("${CRI[@]}" pods -q | wc -l)" = 4 ] && [ "$("${CRI[@]}" pods --state Ready -q | wc -l)" = 3 ] || fail "the CRI does not list four pods, three of them ready"
[ "$("${CRI[@]}" ps -q | wc -l)" -lt "$("${CRI[@]}" ps -a -q | wc -l)" ] || fail "'crictl ps' does not hide the exited containers"
echo "  -> OK ($("${CRI[@]}" pods -q | wc -l) pods listed, $("${CRI[@]}" pods --state Ready -q | wc -l) ready; $("${CRI[@]}" ps -q | wc -l) running containers of $("${CRI[@]}" ps -a -q | wc -l))"

echo "[precondition] checking the places the thread's answers read do not exist here: no Docker daemon, no kubelet data for these pods..."
if command -v docker >/dev/null 2>&1 && timeout 10 docker info >/dev/null 2>&1; then fail "a Docker daemon answers on this machine"; fi
for u in $(python3 -c 'import json,sys; print(*[p["uid"] for p in json.load(open(sys.argv[1]))])' "$STATE_DIR/pods.json"); do
    sudo test ! -e "/var/lib/kubelet/pods/$u" || fail "the kubelet has a directory for the pod $u"
done
echo "  -> OK"

echo "[precondition] checking nothing of the solution exists yet..."
[ ! -e "$SCRIPT" ] || fail "$SCRIPT exists already"
echo "  -> OK"

echo "[precondition] PASS - a node with four pods (two named web, in different namespaces), restarted and finished containers, an empty pod and a stopped pod, known by"
echo "[precondition]        random uids and ids; the only place that maps them is the CRI."
