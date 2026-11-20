#!/bin/bash
set -e

CASE_ID="bench73971174"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
daemon_ok() {   # the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
PODLOG=$(sj podlog); IMG=$(sj img)
lab_unchanged() {
    daemon_ok containerd || fail "the node's containerd is not the one of the setup (stopped or replaced)"
    local f
    for f in $(sj files | python3 -c 'import json,sys; print(*json.load(sys.stdin))'); do
        [ "$(sudo sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "$(sj "files" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$f")" ] || fail "$f was changed (the node's configuration and the wrapper stay as they are)"
    done
    local t
    for t in web db; do
        [ "$(CRICTL inspect "$(sj "targets.$t.ctr")" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the $t workload is not the running container of the setup"
    done
}

echo "[oracle] checking the lab is as the setup left it: the node's containerd and its configuration, the wrapper, the web and db containers (same ids, running)..."
lab_unchanged
echo "  -> OK"

echo "[oracle] making new workloads that no solution has seen: a pod with two containers (alpha, beta) now, and a second pod (gamma) a few seconds later; each prints to stdout and stderr from its first instant; alpha prints one line of 20000 characters (the CRI cuts it into pieces)..."
T0=$(python3 -c 'import time; print(time.time())')
RN=$(python3 -c 'import secrets; print(secrets.token_hex(5))')
D="$STATE_DIR/new-$$"; sudo mkdir -p "$D"
mkctr() {   # $1 pod name  $2 container  $3 log path (relative)  $4 script  -> the container id on stdout
    sudo python3 - "$D/$2.json" "$IMG" "$2" "$3" "$4" <<'PYEOF'
import json, sys
out, img, name, log, script = sys.argv[1:6]
json.dump({"metadata": {"name": name}, "image": {"image": img}, "command": ["/bin/sh", "-c", script], "log_path": log, "linux": {}}, open(out, "w"))
PYEOF
}
mkpod() {   # $1 pod name  -> the pod id
    local uid="u-$1-$$"
    sudo mkdir -p "$PODLOG/bench_$1_$uid"
    sudo tee "$D/$1-pod.json" >/dev/null <<JEOF
{"metadata":{"name":"$1","namespace":"bench","uid":"$uid","attempt":0},"log_directory":"$PODLOG/bench_$1_$uid","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
    CRICTL runp "$D/$1-pod.json" 2>/dev/null | tail -1
}
N_A="a$RN"; N_B="b$RN"; N_G="g$RN"
mkctr late alpha "alpha/0.log" "i=0; while [ \$i -lt 4 ]; do i=\$((i+1)); echo \"alpha $N_A out \$i \$(date +%s)\"; echo \"alpha $N_A err \$i \$(date +%s)\" >&2; sleep 0.5; done; echo \"alpha $N_A big \$(date +%s) \$(head -c 20000 /dev/zero | tr '\\0' 'x')\"; echo \"alpha $N_A done\""
mkctr late beta "beta/0.log" "echo \"beta $N_B out 1 \$(date +%s)\"; printf '%s\\n' 'beta $N_B odd =key=value= \"quoted\" \$HOME \\back\\slash   three  spaces'; echo \"beta $N_B err 1 \$(date +%s)\" >&2; sleep 1; echo \"beta $N_B out 2 \$(date +%s)\"; echo \"beta $N_B done\""
mkctr late2 gamma "gamma/2.log" "echo \"gamma $N_G out 1 \$(date +%s)\"; echo \"gamma $N_G err 1 \$(date +%s)\" >&2; echo \"gamma $N_G out 2 \$(date +%s)\"; sleep 1; echo \"gamma $N_G done\""
PA=$(mkpod late); [ -n "$PA" ] || fail "the node cannot start a pod (the lab is broken)"
CA=$(CRICTL create "$PA" "$D/alpha.json" "$D/late-pod.json" 2>&1 | tail -1); CB=$(CRICTL create "$PA" "$D/beta.json" "$D/late-pod.json" 2>&1 | tail -1)
CRICTL start "$CA" >/dev/null 2>&1 && CRICTL start "$CB" >/dev/null 2>&1 || fail "the node cannot start the oracle's containers (the lab is broken)"
waitexit() { local i; for i in $(seq 1 40); do [ "$(CRICTL inspect "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null)" = "CONTAINER_EXITED" ] && return 0; sleep 1; done; return 1; }
waitexit "$CA" && waitexit "$CB" || fail "the oracle's containers did not finish"
sleep 6
PG=$(mkpod late2); [ -n "$PG" ] || fail "the node cannot start the second pod"
CG=$(CRICTL create "$PG" "$D/gamma.json" "$D/late2-pod.json" 2>&1 | tail -1)
CRICTL start "$CG" >/dev/null 2>&1 || fail "the node cannot start the second pod's container"
waitexit "$CG" || fail "the second pod's container did not finish"
echo "  -> OK (containers ${CA:0:12} ${CB:0:12} ${CG:0:12})"

echo "[oracle] waiting up to 25 s for the journal to hold the lines of the new containers..."
echo "$CA $CB $CG" | sudo tee "$D/ids" >/dev/null
for _ in $(seq 1 25); do
    N=0; for c in $CA $CB $CG; do N=$((N + $(sudo journalctl -o cat -a --no-pager -q "CONTAINER_ID_FULL=$c" 2>/dev/null | wc -l))); done
    [ "$N" -ge 19 ] && break
    sleep 1
done
sleep 2

echo "[oracle] reading the CRI log files (the truth) and the journal, and comparing: every line once, with its stream as PRIORITY, the container id, the whole text, live..."
TEND=$(python3 -c 'import time; print(time.time())')
sudo env CASE_ID="$CASE_ID" STATE_DIR="$STATE_DIR" D="$D" T0="$T0" TEND="$TEND" CA="$CA" CB="$CB" CG="$CG" N_A="$N_A" N_B="$N_B" N_G="$N_G" python3 - <<'PYEOF' || exit 1
import collections, datetime, json, os, re, subprocess, sys
E = os.environ
S = json.load(open(E["STATE_DIR"] + "/state.json"))
T0, TEND, DELAY = float(E["T0"]), float(E["TEND"]), 15.0

def fail(msg):
    print("  -> FAIL: " + msg[:380]); sys.exit(1)

def cri_time(s):
    # 2026-11-19T21:51:09.370847298-06:00 | 2026-11-19T22:42:04.699504001Z | ...+00:00 : nanoseconds cut to microseconds, the zone kept
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$", s)
    if not m: raise ValueError("not a CRI time stamp: %r" % s)
    return datetime.datetime.fromisoformat("%s.%s%s" % (m.group(1), (m.group(2) or "0")[:6].ljust(6, "0"), "+00:00" if m.group(3) == "Z" else m.group(3))).timestamp()

def truth(path):
    """[(time of the last piece, stream, text)] of a CRI log: pieces tagged P are joined to the F piece that ends the line."""
    out, part = [], b""
    for raw in open(path, "rb").read().split(b"\n")[:-1] if open(path, "rb").read().endswith(b"\n") else open(path, "rb").read().split(b"\n"):
        if not raw: continue
        try: t, stream, tag, text = raw.split(b" ", 3)
        except ValueError: continue
        part += text
        if tag == b"F":
            out.append((cri_time(t.decode()), stream.decode(), part.decode("utf-8", "replace"))); part = b""
    return out

def ctr_log(cid):
    st = json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + S["ctd_sock"], "--image-endpoint", "unix://" + S["ctd_sock"], "inspect", "-o", "json", cid], capture_output=True, text=True).stdout)["status"]
    return st["logPath"]

targets = {"web": (S["targets"]["web"]["ctr"], S["targets"]["web"]["log"], S["targets"]["web"]["nonce"], True),
           "db": (S["targets"]["db"]["ctr"], S["targets"]["db"]["log"], S["targets"]["db"]["nonce"], True),
           "alpha": (E["CA"], ctr_log(E["CA"]), E["N_A"], False), "beta": (E["CB"], ctr_log(E["CB"]), E["N_B"], False), "gamma": (E["CG"], ctr_log(E["CG"]), E["N_G"], False)}

# the files of the lab are as they were (not truncated, moved or rewritten)
for n in ("web", "db"):
    t = S["targets"][n]
    try: st = os.stat(t["log"]); first = open(t["log"], "rb").readline()
    except OSError: fail("the log file of %s is gone" % n)
    if st.st_ino != t["inode"]: fail("the log file of %s was replaced (another inode)" % n)
    if st.st_size < t["size"] or __import__("hashlib").sha256(first).hexdigest() != t["first_line_sha"]: fail("the log file of %s was truncated or rewritten" % n)
exp_lines = {"alpha": 10, "beta": 5, "gamma": 4}
tr = {}
for n, (cid, path, nonce, live) in targets.items():
    if not os.path.isfile(path): fail("the log file of %s is gone: %s" % (n, path))
    tr[n] = truth(path)
    if not live and len(tr[n]) != exp_lines[n]: fail("the CRI log file of %s has %d lines, the workload wrote %d (the file was changed, or the CRI log format is not the one assumed)" % (n, len(tr[n]), exp_lines[n]))
big = [x for x in tr["alpha"] if " big " in x[2]]
if len(big) != 1 or len(big[0][2]) < 20000: fail("the CRI log file of alpha does not hold the 20000-character line in one piece (internal)")
log_of = subprocess.run(["crictl", "--runtime-endpoint", "unix://" + S["ctd_sock"], "--image-endpoint", "unix://" + S["ctd_sock"], "logs", E["CA"]], capture_output=True, text=True).stdout
if "alpha %s done" % E["N_A"] not in log_of: fail("`crictl logs` of the new container no longer shows its output")

# the journal since the setup
j = subprocess.run(["journalctl", "-o", "json", "-a", "--no-pager", "-q", "--since", "@%d" % int(S["setup_epoch"] - 1)], capture_output=True, text=True).stdout
entries = []
for l in j.splitlines():
    try: entries.append(json.loads(l))
    except Exception: pass
ids = {v[0]: n for n, v in targets.items() for v in [(v[0],)]}
by_id = collections.defaultdict(list)
for e in entries:
    cid = e.get("CONTAINER_ID_FULL")
    if isinstance(cid, str) and cid in ids: by_id[cid].append(e)
# lines that are in the journal with their text but not under their container's id (no field, a short id, another container's id)
for n, (cid, path, nonce, live) in targets.items():
    for e in entries:
        m = e.get("MESSAGE")
        if isinstance(m, str) and m.startswith("%s %s " % (n, nonce)) and e.get("CONTAINER_ID_FULL") != cid:     # a line of this container (a message that merely contains the nonce, like sudo's log of a command, is not)
            fail("an entry with the line of %s has %s (the container's CONTAINER_ID_FULL is %s...): %s" % (n, "CONTAINER_ID_FULL=" + str(e.get("CONTAINER_ID_FULL"))[:12] + "..." if e.get("CONTAINER_ID_FULL") else "no CONTAINER_ID_FULL field", cid[:12], m[:50]))

prio = {"stdout": "6", "stderr": "3"}
for n, (cid, path, nonce, live) in targets.items():
    want = collections.Counter(); wtime = {}
    for (t, stream, text) in tr[n]:
        if live and t < T0 + 1: continue          # the lines of the setup's time: a forwarder may forward them or not
        want[(prio[stream], text)] += 1; wtime.setdefault((prio[stream], text), t)
    got = collections.Counter(); late = []
    for e in by_id.get(cid, []):
        m = e.get("MESSAGE")
        if not isinstance(m, str): fail("an entry of %s has a MESSAGE that is not text (%r)" % (n, type(m).__name__))
        key = (str(e.get("PRIORITY")), m)
        got[key] += 1
        if not (live and key not in want): pass
    allt = {(prio[s], x): t for (t, s, x) in tr[n]}
    for key, c in got.items():
        if key not in allt:
            same = [k for k in allt if k[1] == key[1]]
            if same: fail("%s: PRIORITY=%s for a line the container wrote to %s (%.60s)" % (n, key[0], "stderr" if same[0][0] == "3" else "stdout", key[1]))
            ends = [k for k in allt if len(k[1]) > 20 and key[1].endswith(k[1]) and len(key[1]) > len(k[1])]
            if ends: fail("%s: MESSAGE holds more than the line (%.50s ... the CRI prefix?)" % (n, key[1]))
            piece = [k for k in allt if len(key[1]) < len(k[1]) and k[1].startswith(key[1])]
            if piece: fail("%s: an entry holds a piece of a line (%d of %d characters), not the whole line" % (n, len(key[1]), len(piece[0][1])))
            fail("%s: an entry that is no line of the container (PRIORITY=%s, MESSAGE=%.70s...)" % (n, key[0], key[1]))
        if c > sum(1 for (t, s, x) in tr[n] if (prio[s], x) == key): fail("%s: the line appears %d times in the journal (once in the container's log): %.70s" % (n, c, key[1]))
    for key, c in want.items():
        t = wtime[key]
        if live and t > TEND - DELAY: continue     # too recent to hold against the forwarder
        if got.get(key, 0) < c:
            other = [k for k in got if k[1] == key[1]]
            if other: fail("%s: a line has PRIORITY=%s, the container wrote it to %s (%.60s)" % (n, other[0][0], "stderr" if key[0] == "3" else "stdout", key[1]))
            part = [k for k in got if key[1].startswith(k[1][:200]) and len(k[1]) < len(key[1])] if len(key[1]) > 1000 else []
            if part: fail("%s: the %d-character line is in the journal cut into pieces (an entry of %d characters)" % (n, len(key[1]), len(part[0][1])))
            fail("%s: missing in the journal: PRIORITY=%s MESSAGE=%.70s%s" % (n, key[0], key[1], "..." if len(key[1]) > 70 else ""))
    # live: the journal's own time of each entry against the time the container's log recorded the line
    for e in by_id.get(cid, []):
        key = (str(e.get("PRIORITY")), e["MESSAGE"])
        t = allt[key]
        if live and t < T0: continue
        d = int(e["__REALTIME_TIMESTAMP"]) / 1e6 - t
        if d > DELAY: fail("%s: the entry is %d s after the line was written (not live; at most %d s): %.60s" % (n, d, DELAY, key[1]))
print("  -> OK (%s)" % ", ".join("%s %d lines" % (n, sum(1 for e in by_id.get(v[0], []))) for n, v in targets.items()))
PYEOF

echo "[oracle] checking the lab once more (the node's containerd, its configuration, the web and db workloads, the wrapper)..."
lab_unchanged
echo "  -> OK"
CRICTL stopp "$PA" >/dev/null 2>&1 || true; CRICTL rmp -f "$PA" >/dev/null 2>&1 || true; CRICTL stopp "$PG" >/dev/null 2>&1 || true; CRICTL rmp -f "$PG" >/dev/null 2>&1 || true
sudo rm -rf "$D"
echo "[oracle] PASS: the output of the node's containers reaches the systemd journal live, line by line, with the stream, the container id and the whole text, and the CRI files are intact."
