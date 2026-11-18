#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

CASE_ID="bench40403025"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
CID="$CASE_ID"                           # the id of the container that setup creates

echo "[setup] checking what the case needs (runc of this host is the runtime under test)..."
for c in runc python3 sudo sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
if ! command -v gcc >/dev/null 2>&1; then
    echo "[setup] gcc is missing, installing it (apt)..."
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold gcc libc6-dev
fi
runc --version | head -1; echo "  arch $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] the work dir and the root-only record directory..."
mkdir -p "$WORK_DIR" "$BUNDLE/rootfs"
chmod 755 "$WORK_DIR"
sudo install -d -m 0700 "$STATE_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the program of the container: a static C program that prints one line per second with the nonce of this run (from its environment) and a tick counter..."
cat > "$BUILD/app.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(void) {
    const char *nonce = getenv("NONCE");
    if (!nonce) nonce = "unknown";
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (long tick = 1;; tick++) {
        printf("bench40403025-ok nonce=%s tick=%ld\n", nonce, tick);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$BUNDLE/rootfs/app" "$BUILD/app.c"
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')

echo "[setup] the bundle: config.json made by 'runc spec', then the process (args /app, no terminal, NONCE and BENCH_CASE in the environment) and a read-only rootfs..."
(cd "$BUNDLE" && runc spec)
python3 - "$BUNDLE/config.json" "$NONCE" "$CASE_ID" <<'PYEOF'
import json, sys
p, nonce, case = sys.argv[1:4]
c = json.load(open(p))
c["process"]["terminal"] = False
c["process"]["args"] = ["/app"]
c["process"]["env"] = [e for e in c["process"]["env"] if not e.startswith(("NONCE=", "BENCH_CASE="))] + ["NONCE=" + nonce, "BENCH_CASE=" + case]
c["root"]["readonly"] = True
c["hostname"] = case
json.dump(c, open(p, "w"), indent=2)
PYEOF
touch -d '2020-01-01 00:00:00' "$BUNDLE/config.json" "$BUNDLE/rootfs/app"
chmod -R a+rX "$BUNDLE"
: > "$WORK_DIR/container.log"

echo "[setup] the container $CID: 'runc create' (state created, its init process waits for 'runc start'); its stdout/stderr go to $WORK_DIR/container.log..."
sudo runc create --bundle "$BUNDLE" --pid-file "$STATE_DIR/init.pid" "$CID" >"$WORK_DIR/container.log" 2>&1 </dev/null \
    || { echo "[setup] ERROR: runc create failed:"; cat "$WORK_DIR/container.log"; exit 1; }
STATUS=$(sudo runc state "$CID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
[ "$STATUS" = "created" ] || { echo "[setup] ERROR: the container is '$STATUS', not created"; exit 1; }

echo "[setup] recording the state (root-only): init pid and start time, the nonce, the hashes of config.json and /app..."
sudo env STATE_DIR="$STATE_DIR" BUNDLE="$BUNDLE" NONCE="$NONCE" CID="$CID" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
st = json.loads(subprocess.check_output(["runc", "state", E["CID"]]))
pid = int(st["pid"])
start = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
d = {"pid": pid, "start": start, "nonce": E["NONCE"],
     "files": {E["BUNDLE"] + "/config.json": sha(E["BUNDLE"] + "/config.json"), E["BUNDLE"] + "/rootfs/app": sha(E["BUNDLE"] + "/rootfs/app")}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. Container $CID is created (not started); bundle: $BUNDLE"
