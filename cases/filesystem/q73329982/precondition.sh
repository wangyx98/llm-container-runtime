#!/bin/bash
set -e

CASE_ID="bench73329982"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CFG="$LIB_BASE/etc/config.toml"
SOCK="$RUN_BASE/containerd.sock"
SMALL_IMG="$LIB_BASE/disks/small.img"; SMALL_MNT="$LIB_BASE/small"
BIG_IMG="$LIB_BASE/disks/big.img";     BIG_MNT="$LIB_BASE/big"
OLD_ROOT="$SMALL_MNT/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="$CASE_ID"
APP_REF="$CASE_ID.local/app:1"
SAVED_ID="$CASE_ID-saved"

CTR="sudo ctr -a $SOCK -n $NS"
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
cfg_value() {   # $1 = key as recorded in config.orig (top.root, top.state, grpc.address, ttrpc.address): the value in the config file NOW
    python3 - "$CFG" "$1" <<'PYEOF'
import re
import sys

want = sys.argv[2]
section = ""
for line in open(sys.argv[1]):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    k = re.match(r"^\s*([A-Za-z_]+)\s*=\s*['\"]?([^'\"]*)['\"]?\s*$", line)
    if k and "%s.%s" % (section or "top", k.group(1)) == want:
        print(k.group(2))
        break
PYEOF
}
daemon_pid() { sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null; }
# the root the RUNNING daemon uses, as the kernel shows it: where the file descriptor of its metadata database points
effective_root() {
    local p
    p=$(sudo ls -l "/proc/$(daemon_pid)/fd" 2>/dev/null | sed -n 's/.* -> \(.*\)\/io\.containerd\.metadata\.v1\.bolt\/meta\.db$/\1/p' | head -1)
    echo "$p"
}
dev_of() { sudo stat -c %d "$1" 2>/dev/null; }

echo "[precondition] checking the two disks: the small partition ($SMALL_MNT) and the big disk ($BIG_MNT) are separate loopback file systems"
echo "[precondition] mounted from their image files, with the sizes setup made them..."
for f in ballast.stat small.blocks big.blocks small.imgsize big.imgsize image.digest marker state.fnv state.size saved.snapshotkey config.orig containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for pair in "$SMALL_MNT:$SMALL_IMG" "$BIG_MNT:$BIG_IMG"; do
    m=${pair%%:*}; i=${pair#*:}
    mountpoint -q "$m" || fail "$m is not a mount point"
    [ "$(findmnt -n -o FSTYPE "$m")" = ext4 ] || fail "$m is not ext4"
    [ "$(sudo losetup -j "$i" -O NAME -n | head -1)" = "$(findmnt -n -o SOURCE "$m")" ] || fail "$m is not mounted from $i"
done
[ "$(dev_of "$SMALL_MNT")" != "$(dev_of "$BIG_MNT")" ] || fail "both mount points are on the same device"
[ "$(stat -f -c %b "$SMALL_MNT")" = "$(st small.blocks)" ] || fail "the small partition has another size"
[ "$(stat -f -c %b "$BIG_MNT")" = "$(st big.blocks)" ] || fail "the big disk has another size"
[ "$(df --output=avail -B1 "$BIG_MNT" | tail -1 | tr -d ' ')" -gt 134217728 ] || fail "the big disk has no room (less than 128 MiB free)"
echo "  -> OK ($(df -h --output=size,avail "$SMALL_MNT" | tail -1 | xargs) on the small one, $(df -h --output=size,avail "$BIG_MNT" | tail -1 | xargs) on the big one: size, free)"

echo "[precondition] checking the small partition is full: nothing can be written to it (the symptom of the thread, ENOSPC)..."
sudo test -f "$SMALL_MNT/ballast.bin" || fail "the ballast file is missing"
[ "$(sudo stat -c '%i %s' "$SMALL_MNT/ballast.bin")" = "$(st ballast.stat)" ] || fail "the ballast file is not the recorded one"
if OUT=$(sudo dd if=/dev/zero of="$SMALL_MNT/.probe" bs=64k count=4 2>&1 >/dev/null); then sudo rm -f "$SMALL_MNT/.probe"; fail "something can still be written to the small partition"; fi
sudo rm -f "$SMALL_MNT/.probe"
echo "     writing to it: $(grep -i 'space' <<<"$OUT" | head -1 | cut -c1-100)"
echo "  -> OK"

echo "[precondition] checking containerd: running on its socket with the recorded config (root on the small partition, state under $RUN_BASE),"
echo "[precondition] its control script untouched..."
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(st containerdctl.sha)" ] || fail "containerdctl was changed"
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || fail "containerd does not answer on $SOCK"
[ "$(sudo tr '\0' ' ' < "/proc/$(daemon_pid)/cmdline")" = "containerd --config $CFG " ] || fail "containerd is not started as 'containerd --config $CFG'"
for k in top.root top.state grpc.address ttrpc.address; do
    [ "$(cfg_value $k)" = "$(grep "^$k=" "$STATE_DIR/config.orig" | cut -d= -f2-)" ] || fail "the config's $k is not the recorded one"
done
[ "$(cfg_value top.root)" = "$OLD_ROOT" ] || fail "the config's root is not $OLD_ROOT"
[ "$(effective_root)" = "$OLD_ROOT" ] || fail "the running daemon does not use $OLD_ROOT (it uses [$(effective_root)])"
[ "$(findmnt -n -o TARGET -T "$OLD_ROOT")" = "$SMALL_MNT" ] || fail "$OLD_ROOT is not on the small partition"
echo "  -> OK (root $OLD_ROOT, state $(cfg_value top.state))"

echo "[precondition] checking what containerd holds: the image $APP_REF with the recorded digest, and the stopped container $SAVED_ID whose"
echo "[precondition] writable layer (a snapshot) holds the data file (known size and FNV-1a); no task, no mount of any container..."
REAL=$($CTR images ls 2>/dev/null | awk -v r="$APP_REF" '$1==r{print $3}')
[ "$REAL" = "$(st image.digest)" ] || fail "containerd shows [$REAL] for $APP_REF, setup recorded $(st image.digest)"
$CTR containers ls -q 2>/dev/null | grep -qxF "$SAVED_ID" || fail "the container $SAVED_ID does not exist"
[ "$($CTR containers info "$SAVED_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])')" = "$(st saved.snapshotkey)" ] || fail "$SAVED_ID has another snapshot"
[ -z "$($CTR tasks ls -q 2>/dev/null)" ] || fail "a task exists"
FOUND=$(sudo find "$OLD_ROOT/io.containerd.snapshotter.v1.overlayfs/snapshots" -path '*/fs/data/state.bin' 2>/dev/null | head -1)
[ -n "$FOUND" ] || fail "no snapshot holds a data file"
[ "$(sudo stat -c %s "$FOUND")" = "$(st state.size)" ] || fail "the data file has not the recorded size"
[ "$(sudo python3 "$STATE_DIR/expect.py" file "$FOUND")" = "$(st state.fnv)" ] || fail "the data file is not the expected one"
if findmnt -rn -o TARGET | grep -E "^($LIB_BASE|$RUN_BASE)/" | grep -vE "^($SMALL_MNT|$BIG_MNT)$" | grep -q .; then fail "a mount of a container is left"; fi
echo "  -> OK ($APP_REF = $REAL; $SAVED_ID: snapshot $(st saved.snapshotkey), data file $(st state.size) bytes, FNV-1a $(st state.fnv))"
