#!/bin/bash
set -e

CASE_ID="bench55103653"
CID="bench55103653-sub"                 # the id of the subscriber container
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
ROOTFS="$BUNDLE/rootfs"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT="$WORK_DIR/capture_output.py"    # "the script of the Jenkins job"
JENKINS="$WORK_DIR/as_jenkins.sh"       # reproduces how the Jenkins job runs it

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking runc, python3 and setsid are installed (the runtime under test)..."
for b in runc python3 setsid timeout; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
runc --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program is the only file of the container, so"
echo "[setup] nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"
cd "$WORK_DIR"

echo "[setup] building the program of the container: a static program that writes three lines to stdout and one"
echo "[setup] line to stderr, one second apart, each with a per-run random token, and says which pid and"
echo "[setup] host name IT sees (1 and the name set in config.json: only true inside the container)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
    char host[64] = "?";
    gethostname(host, sizeof host);
    printf("sub-start token=" TOKEN " pid=%d host=%s\n", (int)getpid(), host);
    fflush(stdout);
    sleep(1);
    printf("sub-msg 1 token=" TOKEN "\n");
    fflush(stdout);
    fprintf(stderr, "sub-warning token=" TOKEN "\n");
    fflush(stderr);
    sleep(1);
    printf("sub-msg 2 token=" TOKEN "\n");
    fflush(stdout);
    return 0;
}
CEOF
gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"

echo "[setup] creating the OCI bundle: runc's own default config.json (it has \"terminal\": true), with the"
echo "[setup] program as process, a host name and no network namespace..."
sudo mkdir -p "$ROOTFS"/{proc,dev,sys,tmp}
sudo cp "$STATE_DIR/app" "$ROOTFS/app"
sudo chmod 755 "$ROOTFS/app"
(cd "$BUNDLE" && sudo runc spec)
sudo python3 - "$BUNDLE/config.json" "$CID" <<'PYEOF'
import json
import sys

path, cid = sys.argv[1:3]
c = json.load(open(path))
c["process"]["args"] = ["/app"]
c["hostname"] = cid
c["root"]["readonly"] = False
c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "network"]
assert c["process"]["terminal"] is True      # runc's default: a terminal for the process
json.dump(c, open(path, "w"), indent=2)
PYEOF
sudo sh -c 'sha256sum "$1/app"' _ "$ROOTFS" | awk '{print $1}' > "$STATE_DIR/app.sha256"
sudo python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["process"]["args"]))' "$BUNDLE/config.json" > "$STATE_DIR/args.json"
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c"

echo "[setup] writing the script of the Jenkins job ($SCRIPT) and as_jenkins.sh, which runs it the way Jenkins"
echo "[setup] does (as root, in a session without a controlling terminal, stdin from /dev/null)..."
cat > "$SCRIPT" <<PYEOF
#!/usr/bin/env python3
# Step of the Jenkins job: runs the subscriber container with runc, captures what it writes and prints it.
import os
import subprocess
import sys
from subprocess import Popen, PIPE
from threading import Timer

timeout = 20
BUNDLE = "$BUNDLE"
sub_name = "$CID"

tst_subscriber = ["timeout", "-s", "KILL", str(timeout), "runc", "run", "--bundle", BUNDLE, sub_name]
kill_subscriber = lambda process: subprocess.call(["runc", "delete", sub_name, "-f"])

test_env = os.environ.copy()
# workaround for buffering problem which causes no captured output for python subprocesses
test_env["PYTHONUNBUFFERED"] = "1"

sub_pro = Popen(tst_subscriber, stdout=PIPE, stderr=PIPE, env=test_env)

timeout_sub = Timer(timeout, kill_subscriber, [sub_pro])
timeout_sub.start()
(output, err) = sub_pro.communicate()
timeout_sub.cancel()

print("Subscriber stdout:")
print(output.decode(errors="replace"))
print("Subscriber stderr:")
print(err.decode(errors="replace"))
sys.exit(sub_pro.returncode)
PYEOF
chmod 755 "$SCRIPT"
cat > "$JENKINS" <<SHEOF
#!/bin/bash
# runs the step the way the Jenkins job does: as root, in a session of its own (no controlling terminal), with
# stdin from /dev/null
exec sudo setsid -w python3 $SCRIPT </dev/null
SHEOF
chmod 755 "$JENKINS"

echo "[setup] done. The bundle has \"terminal\": true; the script works in a terminal, but not as Jenkins runs it."
