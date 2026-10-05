#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench70105718"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
LOG_DIR="/var/log/$CASE_ID"

# 1. FIRST: put the runc* files of the binary directories back to what setup.sh found. A solution
#    may have replaced the machine's runc with a wrapper (and moved the real one aside); nothing
#    else in this cleanup, and nothing on the machine, may be left running on a wrapper. Only
#    runc* files that were not there at setup are removed.
if [ -f "$STATE_DIR/runc_snapshot.json" ]; then
    echo "[cleanup] putting the runc binary files back to their state from setup..."
    sudo python3 - "$STATE_DIR" <<'PYEOF'
import hashlib, json, os, shutil, sys

state = sys.argv[1]
snap = json.load(open(os.path.join(state, "runc_snapshot.json")))
want = {e["path"]: e for e in snap["entries"]}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


for p, e in want.items():
    if e["type"] == "link":
        ok = os.path.islink(p) and os.readlink(p) == e["target"]
    else:
        ok = (os.path.isfile(p) and not os.path.islink(p) and sha256(p) == e["sha256"]
              and (os.stat(p).st_mode & 0o7777) == e["mode"])
    if ok:
        continue
    tmp = p + ".bench-restore"
    if os.path.lexists(tmp):
        os.remove(tmp)
    if e["type"] == "link":
        os.symlink(e["target"], tmp)
    else:
        shutil.copy2(e["backup"], tmp)
        os.chmod(tmp, e["mode"])
    os.replace(tmp, p)
    print(f"  restored {p}")

for d in snap["dirs"]:
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if name.startswith("runc") and p not in want and (os.path.isfile(p) or os.path.islink(p)):
            os.remove(p)
            print(f"  removed {p} (not there at setup)")
PYEOF
fi

# Containers made from this case's image, or carrying this case's name (any namespace).
# Prints "<namespace> <id>" per container.
list_case_containers() {
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
            sudo ctr -n "$ns" containers info "$c" 2>/dev/null | python3 -c '
import json, sys
ref, cid = sys.argv[1], sys.argv[2]
try:
    info = json.load(sys.stdin)
except Exception:
    sys.exit(1)
name = (info.get("Labels") or {}).get("nerdctl/name", "")
if info.get("Image") == ref or cid.find(sys.argv[3]) >= 0 or name.find(sys.argv[3]) >= 0:
    sys.exit(0)
sys.exit(1)' "$IMAGE_REF" "$c" "$CASE_ID" && echo "$ns $c"
        done
    done
}

# 2. the containers and the image. The work dir (which may hold the runtime wrapper a solution
#    gave a container with --runc-binary; containerd calls it again when the container is
#    deleted) is removed only at the very end.
if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the containers of this case (made from its image, or named after it)"
    echo "[cleanup] and its image from every containerd namespace. Nothing else is touched..."
    list_case_containers | while read -r ns c; do
        timeout -k 5 20 sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
        timeout -k 5 20 sudo ctr -n "$ns" tasks delete --force "$c" >/dev/null 2>&1 || true
        timeout -k 5 20 sudo ctr -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
    done
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$CASE_ID"); do
            timeout -k 5 60 sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
    done
fi

# 3. the log directory, when setup.sh created it
if [ -f "$STATE_DIR/log_dir_created" ]; then
    echo "[cleanup] removing the log directory $LOG_DIR created by setup..."
    sudo rm -rf "$LOG_DIR"
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
