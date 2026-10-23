#!/bin/bash
# Precondition oracle: the initial state is the question's. Everything is measured here:
#  - the lab's files are as setup left them, the node is the lab's containerd 1.6.17 and it is not running, the evidence directory is empty;
#  - the node's containerd really fails to start, and the panic is the question's (slice bounds out of range in bbolt's leafPageElement.key, from Cursor.nsearch, from metadata.(*DB).Init);
#  - meta.db is the recorded broken file; its two meta pages are valid and belong to two different transactions with different root pages (so the previous transaction is intact in the file);
#  - what the node knew is still on disk: the image's manifest blob, the writable snapshot of c1 with the /marker of the program.

CASE_ID="bench67889258"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
META="$LIB/containerd/io.containerd.metadata.v1.bolt/meta.db"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node's version, no node running, no evidence yet..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab is not as setup left it"
sudo "$LIB/node/bin/containerd" --version 2>/dev/null | grep -q "v1.6.17" || fail "the node's containerd is not v1.6.17"
for pid in $(pgrep -x containerd 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && fail "the node's containerd is already running"
done
[ -z "$(sudo ls -A "$LIB/evidence" 2>/dev/null)" ] || fail "the evidence directory is not empty"

echo "[precondition] the broken database: the recorded file, two valid meta pages, two transactions with different roots..."
[ "$(sudo sha256sum "$META" | cut -d' ' -f1)" = "$(sudo cat "$STATE_DIR/corrupt.sha")" ] || fail "meta.db is not the recorded broken file"
sudo python3 - "$META" <<'PY' || fail "the meta pages of meta.db are not what the lab recorded"
import struct, sys
d = open(sys.argv[1], "rb").read()
PS = 4096
def fnv(b):
    h = 0xCBF29CE484222325
    for c in b:
        h = ((h ^ c) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h
m = []
for i in (0, 1):
    v = struct.unpack("<IIIIQQQQQQ", d[i * PS + 16:i * PS + 80])
    assert v[0] == 0xED0CDAED and v[9] == fnv(d[i * PS + 16:i * PS + 72]), "meta %d is not valid" % i
    m.append(v)
assert abs(m[0][8] - m[1][8]) == 1 and m[0][4] != m[1][4], "the transactions are not two with different roots"
cur = max(m, key=lambda v: v[8])
assert struct.unpack("<I", d[cur[4] * PS + 20:cur[4] * PS + 24])[0] == 0xFFFE0000, "the current root page is not the torn one"
PY

echo "[precondition] the node does not start, and the panic is the question's..."
sudo sh -c ": > '$RUN/containerd.log'" 2>/dev/null || true
if sudo timeout -k 3 60 "$LIB/bin/nodectl" start >/dev/null 2>&1; then fail "the node's containerd started"; fi
LOGTXT=$(sudo cat "$RUN/containerd.log" 2>/dev/null)
echo "$LOGTXT" | grep -q "panic: runtime error: slice bounds out of range" || fail "no bbolt panic in the node's log"
echo "$LOGTXT" | grep -q "leafPageElement).key" && echo "$LOGTXT" | grep -q "Cursor).nsearch" && echo "$LOGTXT" | grep -q "metadata.(\*DB).Init" || fail "the panic is not the one of the question (leafPageElement.key / nsearch / metadata.DB.Init)"
for pid in $(pgrep -x containerd 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && fail "a containerd of the node is still running"
done
[ "$(sudo sha256sum "$META" | cut -d' ' -f1)" = "$(sudo cat "$STATE_DIR/corrupt.sha")" ] || fail "the failed start changed meta.db"

echo "[precondition] what the node knew is still on disk (manifest blob, c1's snapshot with its /marker)..."
MAN=$(sudo cat "$STATE_DIR/manifest.digest"); TOKEN=$(sudo cat "$STATE_DIR/token")
sudo test -s "$LIB/containerd/io.containerd.content.v1.content/blobs/sha256/${MAN#sha256:}" || fail "the manifest blob is not in the content store"
sudo sh -c "grep -rlx '$TOKEN' '$LIB'/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/*/fs/marker" >/dev/null 2>&1 || fail "no snapshot has the /marker of c1"

echo "[precondition] OK: containerd $(sudo "$LIB/node/bin/containerd" --version | awk '{print $3}') panics in bbolt on meta.db; the image blob and c1's snapshot are on disk."
