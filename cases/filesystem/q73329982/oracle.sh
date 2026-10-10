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
CTRT="sudo timeout -k 5 90 ctr -a $SOCK -n $NS"
CTLCMD="sudo bash $CTL_DIR/containerdctl"
RAND() { python3 -c 'import secrets; print(secrets.token_hex(4))'; }

# the two disks are what setup made: the same image files mounted at the same places, the same sizes (no resizing of either), and the
# ballast file that keeps the small partition full is still there, the same file
disks_ok() {
    local pair m i
    for pair in "$SMALL_MNT:$SMALL_IMG" "$BIG_MNT:$BIG_IMG"; do
        m=${pair%%:*}; i=${pair#*:}
        mountpoint -q "$m" || { echo "$m is not a mount point any more"; return 1; }
        [ "$(sudo losetup -j "$i" -O NAME -n | head -1)" = "$(findmnt -n -o SOURCE "$m")" ] || { echo "$m is not mounted from $i any more"; return 1; }
    done
    [ "$(sudo stat -c %s "$SMALL_IMG")" = "$(st small.imgsize)" ] || { echo "the image file of the small partition was resized (the partition cannot be grown)"; return 1; }
    [ "$(sudo stat -c %s "$BIG_IMG")" = "$(st big.imgsize)" ] || { echo "the image file of the big disk was resized"; return 1; }
    [ "$(stat -f -c %b "$SMALL_MNT")" = "$(st small.blocks)" ] || { echo "the small partition has another size now (the partition cannot be grown)"; return 1; }
    [ "$(stat -f -c %b "$BIG_MNT")" = "$(st big.blocks)" ] || { echo "the big disk has another size now"; return 1; }
    [ "$(sudo stat -c '%i %s' "$SMALL_MNT/ballast.bin" 2>/dev/null)" = "$(st ballast.stat)" ] || { echo "the ballast file of the small partition is gone or changed (free space cannot be made that way)"; return 1; }
}
wait_up() { for _ in $(seq 1 60); do [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
# the daemon: started as the control script starts it (with the config file), the only one of the case, answering, and using for
# real (as its open metadata database shows) the root the config names
daemon_ok() {   # $1 = the root the config names, resolved
    local n
    wait_up || { echo "containerd does not answer on $SOCK"; return 1; }
    [ "$(sudo tr '\0' ' ' < "/proc/$(daemon_pid)/cmdline" 2>/dev/null)" = "containerd --config $CFG " ] || { echo "containerd is not started as 'containerd --config $CFG' (a root given on the command line is not the config)"; return 1; }
    n=0; for p in $(pgrep -x containerd); do sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$LIB_BASE" && n=$((n + 1)); done
    [ "$n" = 1 ] || { echo "$n containerd processes of this case run (one expected)"; return 1; }
    [ "$(realpath -e "$(effective_root)" 2>/dev/null)" = "$1" ] || { echo "the running daemon uses [$(effective_root)] as its root, not $1"; return 1; }
}
# what must have survived: the image (same digest, runs without any pull), the stopped container (same snapshot, and starting it again
# shows the data its writable layer holds), measured with the independent expectations of setup
data_ok() {
    local real out snap
    real=$($CTRT images ls 2>/dev/null | awk -v r="$APP_REF" '$1==r{print $3}')
    [ "$real" = "$(st image.digest)" ] || { echo "containerd shows [$real] for $APP_REF, expected $(st image.digest) (the image is gone or another one)"; return 1; }
    out=$($CTRT run --rm --net-host "$APP_REF" "probe-$(RAND)" /app marker 2>&1 </dev/null | grep -v DEPRECATION | tail -2 | tr '\n' ' ')
    [ "$out" = "marker=$(st marker) " ] || { echo "the image does not run as before (output: ${out:0:150})"; return 1; }
    $CTRT containers ls -q 2>/dev/null | grep -qxF "$SAVED_ID" || { echo "the container $SAVED_ID is gone"; return 1; }
    snap=$($CTRT containers info "$SAVED_ID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])' 2>/dev/null)
    [ "$snap" = "$(st saved.snapshotkey)" ] || { echo "$SAVED_ID has snapshot [$snap], expected $(st saved.snapshotkey)"; return 1; }
    out=$($CTRT tasks start "$SAVED_ID" 2>&1 </dev/null | grep -v DEPRECATION | tail -2 | tr '\n' ' ')
    $CTRT tasks delete "$SAVED_ID" >/dev/null 2>&1 || true
    [ "$out" = "check size=$(st state.size) fnv=$(st state.fnv) marker=$(st marker) " ] || { echo "starting $SAVED_ID again shows [${out:0:150}], expected its data file of $(st state.size) bytes with FNV-1a $(st state.fnv)"; return 1; }
}
# FNV-1a of every data file in the snapshots below a root
fnvs_under() {
    local d="$1/io.containerd.snapshotter.v1.overlayfs/snapshots" f
    sudo test -d "$d" || return 0
    for f in $(sudo find "$d" -path '*/fs/data/state.bin' 2>/dev/null); do sudo python3 "$STATE_DIR/expect.py" file "$f"; done
}

echo "[oracle] check 0: the two disks are what they were: the same image files mounted at the same places, none of them resized, and the"
echo "[oracle]          ballast file that keeps the small partition full still there (space is not made by deleting it or by growing the disk)..."
for f in ballast.stat small.blocks big.blocks small.imgsize big.imgsize image.digest marker state.fnv state.size saved.snapshotkey config.orig containerdctl.sha; do
    [ -n "$(st $f)" ] || fail "setup's recorded $f is missing"
done
MSG=$(disks_ok) || fail "$MSG"
echo "  -> OK"

echo "[oracle] check 1: the config was changed, and only in the right place: root now names a place on the big disk, state and the socket"
echo "[oracle]          addresses are as before, the control script is untouched, and the old root path was not turned into a link or a mount..."
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(st containerdctl.sha)" ] || fail "$CTL_DIR/containerdctl was changed"
for k in top.state grpc.address ttrpc.address; do
    [ "$(cfg_value $k)" = "$(grep "^$k=" "$STATE_DIR/config.orig" | cut -d= -f2-)" ] || fail "the config's $k was changed (it is $(cfg_value $k)); only root is to change"
done
[ ! -L "$OLD_ROOT" ] || fail "$OLD_ROOT is a symbolic link (the setting must change, not the path be redirected)"
if mountpoint -q "$OLD_ROOT" 2>/dev/null; then fail "$OLD_ROOT is a mount point (the setting must change, not the path be redirected)"; fi
ROOT_CFG=$(cfg_value top.root)
[ -n "$ROOT_CFG" ] || fail "the config has no root"
[ "$ROOT_CFG" != "$OLD_ROOT" ] || fail "the config's root is still $OLD_ROOT (the data directory was not changed)"
[ -d "$ROOT_CFG" ] || fail "the config's root $ROOT_CFG is not a directory"
NEW_ROOT=$(realpath -e "$ROOT_CFG")
[ "$(findmnt -n -o TARGET -T "$NEW_ROOT")" = "$BIG_MNT" ] || fail "the root $ROOT_CFG is not on the big disk ($BIG_MNT) but on $(findmnt -n -o TARGET -T "$NEW_ROOT")"
[ ! -e "$OLD_ROOT" ] || [ "$(findmnt -n -o TARGET -T "$OLD_ROOT")" = "$SMALL_MNT" ] || fail "$OLD_ROOT is not on the small partition any more"
echo "  -> OK (root $ROOT_CFG; state $(cfg_value top.state); socket $(cfg_value grpc.address))"

echo "[oracle] check 2: containerd runs as the control script starts it, it is the only one, and it really uses the new root..."
MSG=$(daemon_ok "$NEW_ROOT") || fail "$MSG"
echo "  -> OK (pid $(daemon_pid), root $(effective_root))"

echo "[oracle] check 3: what the node had survived the move: the image with the same digest (and it runs, offline), and the stopped"
echo "[oracle]          container with its writable layer: started again, it shows the data file with the FNV-1a the oracle expects..."
MSG=$(data_ok) || fail "$MSG"
echo "  -> OK ($APP_REF = $(st image.digest); $SAVED_ID: data file $(st state.size) bytes, FNV-1a $(st state.fnv))"

echo "[oracle] check 4: new data goes to the big disk: the oracle imports a NEW image (random content; the layer is written to the content"
echo "[oracle]          store) and runs a container from it (its data file is written into a new writable layer)..."
H=$(RAND)
N_REF="$CASE_ID.local/new-$H:1"; N_ID="$CASE_ID-new-$H"
SEED2=$(python3 -c 'import secrets; print(secrets.randbits(64))'); MARKER2=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
gcc -static -Os -s -w -DSEED="${SEED2}ULL" -DSTATE_BYTES=262144 -DMARKER="\"$MARKER2\"" -o "$WORK_DIR/new-bin" "$STATE_DIR/app.c" || fail "(oracle) could not build the new program"
TRUTH=$(python3 "$STATE_DIR/mkimg.py" "$WORK_DIR/new.tar" "$N_REF" "$WORK_DIR/new-bin" app) || fail "(oracle) could not build the new image"
chmod 0644 "$WORK_DIR/new.tar"
N_DIGEST=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest"])' "$TRUTH")
N_LAYER=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["layer"].split(":")[1])' "$TRUTH")
OUT=$($CTRT images import "$WORK_DIR/new.tar" 2>&1 </dev/null | grep -v DEPRECATION | tail -2 | tr '\n' ' ') || true
[ "$($CTRT images ls 2>/dev/null | awk -v r="$N_REF" '$1==r{print $3}')" = "$N_DIGEST" ] || fail "importing a new image failed (${OUT:0:200})"
sudo test -f "$NEW_ROOT/io.containerd.content.v1.content/blobs/sha256/$N_LAYER" || fail "the layer of the new image is not in the content store of the new root"
if sudo test -e "$OLD_ROOT/io.containerd.content.v1.content/blobs/sha256/$N_LAYER"; then fail "the layer of the new image was written to the old root"; fi
OUT=$($CTRT run -d --net-host "$N_REF" "$N_ID" 2>&1 </dev/null | grep -v DEPRECATION | tail -2 | tr '\n' ' ') || true
for _ in $(seq 1 40); do [ "$($CTRT tasks ls 2>/dev/null | awk -v c="$N_ID" '$1==c{print $3}')" = STOPPED ] && break; sleep 0.5; done
[ "$($CTRT tasks ls 2>/dev/null | awk -v c="$N_ID" '$1==c{print $3}')" = STOPPED ] || fail "the container of the new image did not run to its end (${OUT:0:200})"
$CTRT tasks delete "$N_ID" >/dev/null 2>&1 || true
N_FNV=$(python3 "$STATE_DIR/expect.py" "$SEED2" 262144)
fnvs_under "$NEW_ROOT" | grep -qxF "$N_FNV" || fail "the data the new container wrote is not in a snapshot of the new root"
if fnvs_under "$OLD_ROOT" | grep -qxF "$N_FNV"; then fail "the data the new container wrote went to the old root"; fi
echo "  -> OK (the new image's layer and the new container's data file are in $NEW_ROOT, not in $OLD_ROOT)"

echo "[oracle] check 5: it was not a lucky moment: containerd is restarted with its own control script (containerdctl restart), and the"
echo "[oracle]          root, the old data and the new data are still the same..."
$CTLCMD restart >/dev/null 2>&1 || fail "containerdctl restart failed"
MSG=$(daemon_ok "$NEW_ROOT") || fail "after the restart: $MSG"
[ "$(cfg_value top.root)" = "$ROOT_CFG" ] || fail "the config's root changed during the restart"
MSG=$(data_ok) || fail "after the restart: $MSG"
OUT=$($CTRT tasks start "$N_ID" 2>&1 </dev/null | grep -v DEPRECATION | tail -2 | tr '\n' ' ')
$CTRT tasks delete "$N_ID" >/dev/null 2>&1 || true
[ "$OUT" = "check size=262144 fnv=$N_FNV marker=$MARKER2 " ] || fail "after the restart the container made during the check shows [${OUT:0:150}]"
MSG=$(disks_ok) || fail "$MSG"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
