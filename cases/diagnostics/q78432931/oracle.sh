#!/bin/bash
set -e

CASE_ID="bench78432931"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_DIR="$WORK_DIR/app"               # the Go program the solution had to change
REG_ADDR="127.0.0.1:43293"
NS="k8s.io"
BIN="$APP_DIR/pull.oracle"            # built here, from the sources the solution left: not a binary it may have left lying around

CTR_T="sudo ctr -a $T_SOCK -n $NS"
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
daemons_intact() {
    alive_same containerd || fail "the private containerd is not the process of setup any more (restarted or killed)"
    alive_same registry || fail "the registry is not the process of setup any more"
    [ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
    (cd "$STATE_DIR" && sha256sum registry.py mkimage.py patch_config.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the oracle was changed"
    $CTR_T version >/dev/null 2>&1 || fail "containerd does not answer on $T_SOCK"
}

echo "[oracle] check 0: the containerd and the registry of setup are still the same processes, config and helpers unchanged..."
daemons_intact
echo "  -> OK"

echo "[oracle] check 1: the program's sources ($APP_DIR) use the containerd Go client, not the Docker client of the thread's answer, and do not run other programs..."
[ -f "$APP_DIR/main.go" ] || fail "$APP_DIR/main.go does not exist"
GOFILES=$(find "$APP_DIR" -maxdepth 1 -name '*.go')
grep -l 'github.com/docker/docker' $GOFILES >/dev/null 2>&1 && fail "the program uses the Docker client (github.com/docker/docker): it pulls from a Docker daemon, which this node does not have; the question is about the containerd client"
grep -lE '"os/exec"|syscall\.Exec' $GOFILES >/dev/null 2>&1 && fail "the program runs other programs (os/exec): the progress has to come from the containerd client itself"
grep -q 'containerd/v2/client' $GOFILES || fail "the program does not import the containerd Go client (github.com/containerd/containerd/v2/client)"
grep -q '\.Pull(' $GOFILES || fail "the program does not pull with the client (client.Pull)"
echo "  -> OK"

echo "[oracle] check 2: the sources build ('go build' in $APP_DIR, the Go modules are downloaded if the solution added some)..."
cd "$APP_DIR"
rm -f "$BIN"
if ! GOFLAGS=-mod=mod timeout -k 5 600 go build -o "$BIN" . > "$WORK_DIR/build.log" 2>&1; then
    tail -15 "$WORK_DIR/build.log"
    fail "go build failed"
fi
rm -f "$WORK_DIR/build.log"
[ -x "$BIN" ] || fail "go build made no program"
cd "$WORK_DIR"
echo "  -> OK"

echo "[oracle] check 3: two NEW images, made now with random layers (a solution cannot know their digests or sizes): one good, one with a layer whose bytes do not match its digest..."
python3 - "$STATE_DIR" <<'PYEOF'
import json
import random
import subprocess
import sys

state = sys.argv[1]
MiB = 1024 * 1024
r = random.SystemRandom()
h = "%08x" % r.getrandbits(32)


def mk(repo, tag, layers, corrupt=None):
    cmd = ["python3", state + "/mkimage.py", state + "/registry", repo, tag, "--layers", ",".join("%d:%.1f" % l for l in layers)]
    if corrupt is not None:
        cmd += ["--corrupt", str(corrupt)]
    return json.loads(subprocess.check_output(cmd))


good = mk("bench/app", "oracle" + h, [(r.randint(5 * MiB, 6 * MiB), r.uniform(7.5, 8.5)),
                                      (r.randint(int(4.3 * MiB), 5 * MiB), r.uniform(6.0, 8.0)),
                                      (r.randint(int(4.3 * MiB), 5 * MiB), r.uniform(6.0, 8.0))])
bad = mk("bench/bad", "oracle" + h, [(r.randint(2 * MiB, 3 * MiB), r.uniform(6.0, 7.0)),
                                     (r.randint(2 * MiB, 3 * MiB), r.uniform(6.0, 7.0))], corrupt=1)
json.dump(good, open(state + "/oracle-good.json", "w"))
json.dump(bad, open(state + "/oracle-bad.json", "w"))
print("  -> bench/app:oracle%s (%s) and bench/bad:oracle%s (layer 1 corrupt)" % (
      h, " + ".join("%.1f MiB" % (l["size"] / MiB) for l in good["layers"]), h))
PYEOF

cat > "$STATE_DIR/check_pull.py" <<'PYEOF'
"""check_pull.py MODE STATE BIN SOCK NS ADDR : run the program on the oracle's image and check what it printed against what the registry sent.
MODE good: a pull that succeeds; MODE bad: a pull that must fail."""
import hashlib
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request

mode, state, binary, sock, ns, addr = sys.argv[1:7]
img = json.load(open("%s/oracle-%s.json" % (state, mode)))
ref = "%s/%s:%s" % (addr, img["repo"], img["tag"])
CTR = ["sudo", "ctr", "-a", sock, "-n", ns]


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


# ---- run the program, stamping every line of stdout with the time it arrived ------------------------------------------------------
lines = []
proc = subprocess.Popen([binary, "--address", sock, "--namespace", ns, "--ref", ref], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, cwd=os.path.dirname(state), start_new_session=True)


def reader():
    for raw in proc.stdout:
        lines.append((time.time(), raw.decode("utf-8", "replace")))


err_chunks = []
threads = [threading.Thread(target=reader, daemon=True),
           threading.Thread(target=lambda: err_chunks.append(proc.stderr.read()), daemon=True)]
for t in threads:
    t.start()
t_start = time.time()
try:
    rc = proc.wait(timeout=100)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    fail("the program did not finish in 100 s (a pull of this image takes about 10 s)")
for t in threads:
    t.join(5)
t_exit = time.time()
stderr = b"".join(err_chunks).decode("utf-8", "replace")

events = []
for t, text in lines:
    s = text.strip()
    if not s.startswith("{"):
        continue                    # a log line, not a record
    try:
        ev = json.loads(s)
    except ValueError:
        fail("a line of stdout starts with '{' but is not JSON: %r" % s[:120])
    if not isinstance(ev, dict) or ev.get("event") not in ("progress", "done"):
        fail("a record of stdout is neither a progress nor a done record: %r" % s[:120])
    events.append((t, ev))
progress = [(t, e) for t, e in events if e["event"] == "progress"]
done = [(t, e) for t, e in events if e["event"] == "done"]

# ---- the failing pull: it must say so ------------------------------------------------------------------------------------------
if mode == "bad":
    if rc == 0:
        fail("the pull of %s FAILED (a layer does not match its digest: containerd refuses it), but the program exited 0" % ref)
    if done:
        fail("the pull of %s FAILED, but the program printed a done record: %r" % (ref, done[0][1]))
    out = subprocess.run(CTR + ["images", "ls", "-q"], capture_output=True, text=True).stdout.split()
    if ref in out:
        fail("the image %s is in the namespace although its pull failed" % ref)
    print("  -> OK: exit code %d, no done record, the image is not in the namespace (%d progress records were printed on the way)" % (rc, len(progress)))
    sys.exit(0)

# ---- the good pull ----------------------------------------------------------------------------------------------------------------
if rc != 0:
    fail("the program exited %d on the pull of %s; stderr: %s" % (rc, ref, stderr.strip()[-400:]))
if not progress:
    fail("the program printed no progress record at all (stdout: %d lines; a record is a line {\"event\":\"progress\",\"digest\":...,\"offset\":...,\"total\":...})" % len(lines))

size = {img["manifest"]["digest"]: img["manifest"]["size"], img["config"]["digest"]: img["config"]["size"]}
for l in img["layers"]:
    size[l["digest"]] = l["size"]
layers = [l["digest"] for l in img["layers"]]
name = {d: "layer %d (%.1f MiB)" % (i, size[d] / 1048576) for i, d in enumerate(layers)}

reg = json.loads(urllib.request.build_opener(urllib.request.ProxyHandler({})).open("http://%s/_bench/log" % addr, timeout=10).read())
chunks, ends = {}, {}
for e in reg:
    if e["d"] not in size:
        continue
    if e["ev"] == "chunk":
        chunks.setdefault(e["d"], []).append((e["t"], e["pos"]))
    elif e["ev"] == "end":
        ends[e["d"]] = e["t"]
for d in layers:
    if d not in chunks or d not in ends:
        fail("the registry saw no complete transfer of %s (the pull did not download it?)" % name[d])


def sent_at(d, t):
    best = 0
    for tt, pos in chunks.get(d, ()):
        if tt <= t and pos > best:
            best = pos
    return best


def rel(t):
    return "%.1f s" % (t - t_start)


last = {}
during = {d: set() for d in layers}
for t, e in progress:
    for k in ("digest", "offset", "total"):
        if k not in e:
            fail("a progress record has no '%s': %r" % (k, e))
    d, off, tot = e["digest"], e["offset"], e["total"]
    if not isinstance(off, int) or not isinstance(tot, int) or isinstance(off, bool) or isinstance(tot, bool):
        fail("offset and total must be integers (bytes): %r" % e)
    if d not in size:
        fail("a progress record for %s, which is no blob of the image" % d)
    if tot != size[d]:
        fail("%s: total is %d but the blob has %d bytes" % (name.get(d, d[:19]), tot, size[d]))
    if off < 0 or off > tot:
        fail("%s: offset %d is outside 0..%d" % (name.get(d, d[:19]), off, tot))
    if off < last.get(d, 0):
        fail("%s: offset went backwards, %d after %d (a pulled-bytes counter only grows)" % (name.get(d, d[:19]), off, last[d]))
    last[d] = off
    if d in layers:
        ahead = sent_at(d, t + 0.05)
        if off > ahead:
            fail("%s: at %s the program reported %d bytes, but the registry had sent only %d by then: that is not what was downloaded" % (
                 name[d], rel(t), off, ahead))
        behind = sent_at(d, t - 1.0)
        if off < behind - 1.1 * 1048576:
            # containerd's content store counts a download in steps of 1 MiB; and a second for the polling: that much it may stay behind
            fail("%s: at %s the program reported %d bytes, but the registry had already sent %d bytes a second earlier: the progress does not follow the download" % (
                 name[d], rel(t), off, behind))
        if 0 < off < tot and t <= ends[d] + 0.3:
            during[d].add(off)

for d in layers:
    if len(during[d]) < 3:
        fail("%s: %d progress records with a partial offset while it was being downloaded (3 needed); the registry served it from %s to %s" % (
             name[d], len(during[d]), rel(chunks[d][0][0]), rel(ends[d])))
    if last.get(d) != size[d]:
        fail("%s: the last progress record says %s of %d bytes: it never reports the blob complete" % (name[d], last.get(d), size[d]))

if len(done) != 1:
    fail("expected one done record, found %d" % len(done))
t_done, dn = done[0]
if events[-1][1] is not dn:
    fail("the done record must be the last record: progress records come after it")
if dn.get("name") != ref:
    fail("done.name is %r, expected %r" % (dn.get("name"), ref))
if dn.get("digest") != img["manifest"]["digest"]:
    fail("done.digest is %r: it must be the digest of the image (its manifest, %s)" % (dn.get("digest"), img["manifest"]["digest"]))
if dn.get("size") != img["manifest"]["size"]:
    fail("done.size is %r, the manifest has %d bytes" % (dn.get("size"), img["manifest"]["size"]))
print("  -> OK: %d progress records, %s; the done record names %s" % (
      len(progress), "; ".join("%s: %d samples during the download" % (name[d], len(during[d])) for d in layers), dn["digest"][:19]))

# ---- what the pull left in containerd ---------------------------------------------------------------------------------------------
rows = subprocess.run(CTR + ["images", "ls"], capture_output=True, text=True).stdout.splitlines()
row = [r.split() for r in rows if r.split()[:1] == [ref]]
if not row or row[0][2] != img["manifest"]["digest"]:
    fail("the image %s is not in the namespace with the digest %s" % (ref, img["manifest"]["digest"]))
for d in list(size):
    data = subprocess.run(CTR + ["content", "get", d], capture_output=True).stdout
    if "sha256:" + hashlib.sha256(data).hexdigest() != d or len(data) != size[d]:
        fail("the content store has not the blob %s (%d bytes) the registry sent" % (d[:19], size[d]))
chain = ""
for diff in [l["diff_id"] for l in img["layers"]]:
    chain = diff if not chain else "sha256:" + hashlib.sha256(("%s %s" % (chain, diff)).encode()).hexdigest()
snaps = subprocess.run(CTR + ["snapshots", "ls"], capture_output=True, text=True).stdout.split()
if chain not in snaps:
    fail("the image was not unpacked (no snapshot %s): the pull must still unpack, as the starter does" % chain[:19])
print("  -> OK: %s is an image of %s with the right digest, its blobs are in the content store byte for byte, and it is unpacked" % (ref, ns))
PYEOF

echo "[oracle] check 4: pull the good image with the program built from the sources: stdout is read as it comes, and compared with what the registry sent and when..."
echo "[oracle]          a progress record: {\"event\":\"progress\",\"digest\":\"sha256:<blob>\",\"offset\":<bytes so far>,\"total\":<bytes of the blob>}; at the end {\"event\":\"done\",\"name\":...,\"digest\":...,\"size\":...}"
python3 "$STATE_DIR/check_pull.py" good "$STATE_DIR" "$BIN" "$T_SOCK" "$NS" "$REG_ADDR" || exit 1

echo "[oracle] check 5: pull the image with the corrupt layer: the program must fail, not report success..."
python3 "$STATE_DIR/check_pull.py" bad "$STATE_DIR" "$BIN" "$T_SOCK" "$NS" "$REG_ADDR" || exit 1

echo "[oracle] check 6: the containerd and the registry are still those of setup..."
daemons_intact
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
