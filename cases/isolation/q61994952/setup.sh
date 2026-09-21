#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

WORK_DIR="/tmp/bench61994952"
RUNC_ROOT="$WORK_DIR/runc-root"
ROOTFS="$WORK_DIR/rootfs"
SRC_DIR="$WORK_DIR/src"
VERDICT_FILE="$WORK_DIR/verdict.json"
GROUND_TRUTH_FILE="$WORK_DIR/ground_truth.json"

C1="bench61994952-c1"
C2="bench61994952-c2"
C3="bench61994952-c3"
C4="bench61994952-c4"

echo "[setup] ensuring runc is installed..."
if ! command -v runc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq runc
fi
command -v runc
runc --version | head -1

echo "[setup] ensuring a C toolchain (gcc) is installed..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq build-essential
fi
command -v gcc

echo "[setup] cleaning up any leftover containers from a previous run (idempotency)..."
for c in "$C1" "$C2" "$C3" "$C4"; do
    sudo runc --root "$RUNC_ROOT" delete -f "$c" 2>/dev/null || true
done

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$SRC_DIR" "$ROOTFS/bin" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/tmp"

echo "[setup] building the shared entrypoint binary..."
echo "[setup] (its behavior is irrelevant -- all 4 containers are only ever"
echo "[setup]  put into runc's 'created' state for inspection, never"
echo "[setup]  actually started, so this entrypoint never runs)"
cat > "$SRC_DIR/tiny.c" <<'EOF'
int main(void) { return 0; }
EOF
gcc -o "$SRC_DIR/tiny" "$SRC_DIR/tiny.c"
cp "$SRC_DIR/tiny" "$ROOTFS/bin/tiny"
ldd "$SRC_DIR/tiny" | while read -r line; do
    if echo "$line" | grep -q '=>'; then
        dep_path=$(echo "$line" | awk '{print $3}')
    else
        dep_path=$(echo "$line" | awk '{print $1}')
    fi
    case "$dep_path" in
        /*)
            if [ -f "$dep_path" ]; then
                mkdir -p "$ROOTFS$(dirname "$dep_path")"
                cp -n "$dep_path" "$ROOTFS$dep_path"
            fi
            ;;
    esac
done

echo "[setup] generating the 4 bundles' config.json (roles randomized"
echo "[setup] across container names on every run -- see task.txt)..."
sudo python3 - "$WORK_DIR" "$ROOTFS" "$GROUND_TRUTH_FILE" <<'PYEOF'
import json
import os
import random
import subprocess
import sys

work_dir, rootfs, ground_truth_file = sys.argv[1], sys.argv[2], sys.argv[3]

FULL_CAPS = [
    "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID",
    "CAP_KILL", "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP", "CAP_LINUX_IMMUTABLE",
    "CAP_NET_BIND_SERVICE", "CAP_NET_BROADCAST", "CAP_NET_ADMIN", "CAP_NET_RAW",
    "CAP_IPC_LOCK", "CAP_IPC_OWNER", "CAP_SYS_MODULE", "CAP_SYS_RAWIO", "CAP_SYS_CHROOT",
    "CAP_SYS_PTRACE", "CAP_SYS_PACCT", "CAP_SYS_ADMIN", "CAP_SYS_BOOT", "CAP_SYS_NICE",
    "CAP_SYS_RESOURCE", "CAP_SYS_TIME", "CAP_SYS_TTY_CONFIG", "CAP_MKNOD", "CAP_LEASE",
    "CAP_AUDIT_WRITE", "CAP_AUDIT_CONTROL", "CAP_SETFCAP", "CAP_MAC_OVERRIDE",
    "CAP_MAC_ADMIN", "CAP_SYSLOG", "CAP_WAKE_ALARM", "CAP_BLOCK_SUSPEND",
    "CAP_AUDIT_READ",
]

# Four roles, each toggling a different subset of the 3 independently
# controllable signals (full_caps / open_devices / drop_hardening).
# Exactly one role ("full_priv") turns ALL of them on -- the other three
# turn on at most one, so any classifier keying off a single signal
# alone will misclassify at least one of them.
ROLES = {
    "default":          dict(full_caps=False, open_devices=False, drop_hardening=False),
    "full_priv":        dict(full_caps=True,  open_devices=True,  drop_hardening=True),
    "decoy_devices":    dict(full_caps=False, open_devices=True,  drop_hardening=False),
    "decoy_caps":       dict(full_caps=True,  open_devices=False, drop_hardening=False),
}

names = ["bench61994952-c1", "bench61994952-c2", "bench61994952-c3", "bench61994952-c4"]
roles = list(ROLES.keys())
random.shuffle(roles)  # fresh random assignment every setup run
assignment = dict(zip(names, roles))

ground_truth = {}
for name, role in assignment.items():
    plan = ROLES[role]
    short = name.rsplit("-", 1)[-1]
    bundle_dir = os.path.join(work_dir, f"bundle-{short}")
    os.makedirs(bundle_dir, exist_ok=True)
    subprocess.run(["runc", "spec", "--bundle", bundle_dir], check=True)

    cfg_path = os.path.join(bundle_dir, "config.json")
    with open(cfg_path) as f:
        cfg = json.load(f)

    cfg["process"]["terminal"] = False
    cfg["process"]["args"] = ["/bin/tiny"]
    cfg["root"]["path"] = rootfs
    cfg["root"]["readonly"] = True

    if plan["full_caps"]:
        cfg["process"]["capabilities"] = {
            "bounding": FULL_CAPS, "effective": FULL_CAPS, "inheritable": FULL_CAPS,
            "permitted": FULL_CAPS, "ambient": FULL_CAPS,
        }

    if plan["open_devices"]:
        cfg.setdefault("linux", {}).setdefault("resources", {})["devices"] = [
            {"allow": True, "access": "rwm"}
        ]

    if plan["drop_hardening"]:
        cfg["process"]["noNewPrivileges"] = False
        cfg.setdefault("linux", {})["maskedPaths"] = []
        cfg.setdefault("linux", {})["readonlyPaths"] = []

    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)

    ground_truth[name] = "PRIVILEGED" if role == "full_priv" else "NOT_PRIVILEGED"

with open(ground_truth_file, "w") as f:
    json.dump(ground_truth, f, indent=2)
os.chmod(ground_truth_file, 0o600)
PYEOF

echo "[setup] creating all 4 containers (state 'created', nothing started)..."
echo "[setup] ('create' leaves each container's init process running in the"
echo "[setup]  background, paused, waiting to be inspected -- unlike 'runc"
echo "[setup]  run' it never exits on its own. If that process inherited"
echo "[setup]  this script's own stdout/stderr, it would keep holding those"
echo "[setup]  pipes open forever, and a caller that captures this script's"
echo "[setup]  output via subprocess.communicate() -- as run_single_case.py"
echo "[setup]  does -- would hang waiting for EOF on them long after this"
echo "[setup]  script itself has finished, exactly like the lingering-runc-"
echo "[setup]  process pipe hazard already noted in q62887953/oracle.sh."
echo "[setup]  So each create's own output is redirected to a log file"
echo "[setup]  instead, and only replayed here if it actually fails.)"
for short in c1 c2 c3 c4; do
    case "$short" in
        c1) name="$C1" ;;
        c2) name="$C2" ;;
        c3) name="$C3" ;;
        c4) name="$C4" ;;
    esac
    log="$WORK_DIR/runc-create-$short.log"
    if ! sudo runc --root "$RUNC_ROOT" create --bundle "$WORK_DIR/bundle-$short" "$name" \
            < /dev/null > "$log" 2>&1; then
        echo "[setup] FAILED to create $name -- runc output:"
        cat "$log"
        exit 1
    fi
done

echo "[setup] confirming all 4 exist..."
sudo runc --root "$RUNC_ROOT" list

rm -f "$VERDICT_FILE"

echo "[setup] done. 4 runc containers are in the 'created' state under"
echo "[setup] $RUNC_ROOT: $C1 $C2 $C3 $C4."
