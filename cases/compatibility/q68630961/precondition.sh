#!/bin/bash
set -e

CASE_ID="bench68630961"
UNIT="$CASE_ID-containerd.service"
PREFIX="/opt/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
IMAGE="registry.invalid/$CASE_ID/app:1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

echo "[precondition] checking systemd is the init of this machine and setup left its records..."
[ -d /run/systemd/system ] || { echo "  -> FAIL: the machine is not booted with systemd"; exit 1; }
for f in system.truth tarball.sha256 config.sha256 image.truth token; do
    sudo test -s "$STATE_DIR/$f" || { echo "  -> FAIL: setup did not record $f"; exit 1; }
done
echo "  -> OK"

echo "[precondition] checking the unpacked tarball and the config are in place and untouched..."
for f in containerd ctr containerd-shim-runc-v2; do
    [ -x "$PREFIX/bin/$f" ] || { echo "  -> FAIL: $PREFIX/bin/$f is missing"; exit 1; }
done
(cd "$PREFIX/bin" && sudo sha256sum -c "$STATE_DIR/tarball.sha256" >/dev/null 2>&1) \
    || { echo "  -> FAIL: the binaries in $PREFIX/bin are not the ones setup unpacked"; exit 1; }
[ "$(sudo sha256sum "$PREFIX/etc/config.toml" | cut -d' ' -f1)" = "$(cat "$STATE_DIR/config.sha256")" ] \
    || { echo "  -> FAIL: $PREFIX/etc/config.toml is not the one setup wrote"; exit 1; }
[ -s "$PREFIX/dist/containerd-$CASE_ID-linux.tar.gz" ] || { echo "  -> FAIL: the tarball is missing"; exit 1; }
if find "$PREFIX" -name '*.service' | grep -q .; then
    echo "  -> FAIL: there is a unit file inside the tarball install"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the symptom: systemd does not know $UNIT, 'systemctl start' says so..."
LOAD=$(systemctl show "$UNIT" -p LoadState --value 2>/dev/null || true)
[ "$LOAD" = "not-found" ] || { echo "  -> FAIL: LoadState of $UNIT is '$LOAD', not 'not-found'"; exit 1; }
if systemctl cat "$UNIT" >/dev/null 2>&1; then
    echo "  -> FAIL: systemctl cat finds a unit file for $UNIT"
    exit 1
fi
if OUT=$(sudo timeout 30 systemctl start "$UNIT" 2>&1); then
    echo "  -> FAIL: systemctl start $UNIT worked"
    exit 1
fi
echo "$OUT" | grep -qi "not found" || { echo "  -> FAIL: systemctl start did not fail with 'not found': $OUT"; exit 1; }
echo "  -> OK ($(echo "$OUT" | head -1))"

echo "[precondition] checking no containerd of this case runs and nothing answers on its socket..."
for pid in $(pgrep -x containerd 2>/dev/null); do
    if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CASE_ID"; then
        echo "  -> FAIL: a containerd of this case is running (pid $pid)"
        exit 1
    fi
done
[ ! -e "$CTD_SOCK" ] || { echo "  -> FAIL: $CTD_SOCK exists"; exit 1; }
[ ! -e "$RUN_BASE" ] || { echo "  -> FAIL: $RUN_BASE exists (a reboot would not have it)"; exit 1; }
if sudo timeout 10 "$PREFIX/bin/ctr" -a "$CTD_SOCK" version >/dev/null 2>&1; then
    echo "  -> FAIL: a containerd answers on $CTD_SOCK"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the image is already in the containerd root (it will be there as soon as"
echo "[precondition] the service runs): manifest, config and layer blobs and the image name in the metadata..."
BLOBS="$LIB_BASE/containerd/io.containerd.content.v1.content/blobs/sha256"
for k in manifest config diff_id; do
    d=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]].split(":")[1])' "$STATE_DIR/image.truth" "$k")
    sudo test -s "$BLOBS/$d" || { echo "  -> FAIL: blob $k ($d) is not in the content store"; exit 1; }
done
sudo grep -qaF "$IMAGE" "$LIB_BASE/containerd/io.containerd.metadata.v1.bolt/meta.db" \
    || { echo "  -> FAIL: the image name is not in the metadata database"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the host's own containerd/docker units and binary are as recorded..."
NOW=$(for u in containerd.service docker.service; do
        echo "$u $(systemctl show "$u" -p LoadState -p ActiveState -p MainPID --value 2>/dev/null | tr '\n' ' ')"
      done
      SB=$(readlink -f "$(command -v containerd)"); echo "binary $SB $(sha256sum "$SB" | cut -d' ' -f1)")
[ "$NOW" = "$(cat "$STATE_DIR/system.truth")" ] || { echo "  -> FAIL: the host's containerd/docker changed since setup"; exit 1; }
echo "  -> OK"

echo "[precondition] all conditions met."
