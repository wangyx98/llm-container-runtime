#!/bin/bash
# Precondition oracle: the initial state is the question's. Everything is measured here:
#  - the lab's files are as setup left them (the configuration has the CRI plugin enabled), the node is the lab's containerd 1.6.17 and it is not running;
#  - the node's start fails with the question's fatal error: "failed to recover state: failed to reserve sandbox name \"web_cert-manager_<uid>_3\": name ... is reserved for \"<id>\"";
#    the id is the one the plugin loaded first (the real sandbox, which sorts before its twin), no process of the node is left;
#  - what the node knew is still on disk: its metadata database and the snapshots of the four containers (two sandboxes, two containers).

CASE_ID="bench64401699"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files, the node's version, the configuration, no node running..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab is not as setup left it"
sudo "$LIB/node/bin/containerd" --version 2>/dev/null | grep -q "v1.6.17" || fail "the node's containerd is not v1.6.17"
grep -q '^disabled_plugins = \[\]' "$LIB/etc/containerd.toml" || fail "the CRI plugin is not enabled in the configuration"
for pid in $(pgrep -x containerd 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && fail "the node's containerd is already running"
done

echo "[precondition] the node does not start, with the question's error..."
sudo sh -c ": > '$RUN/containerd.log'" 2>/dev/null || true
if sudo timeout -k 3 60 "$LIB/bin/nodectl" start >/dev/null 2>&1; then fail "the node's containerd started"; fi
POD_A=$(sudo cat "$STATE_DIR/pod.web"); UID_WEB=$(sudo cat "$STATE_DIR/web.uid")
sudo grep -F "level=fatal" "$RUN/containerd.log" | grep -qF 'msg="Failed to run CRI service" error="failed to recover state: failed to reserve sandbox name \"web_cert-manager_'"$UID_WEB"'_3\": name \"web_cert-manager_'"$UID_WEB"'_3\" is reserved for \"'"$POD_A"'\""' || fail "the node's error is not the question's (web_cert-manager_<uid>_3 reserved for the first sandbox)"
for pid in $(pgrep -x containerd 2>/dev/null) $(pgrep -x containerd-shim 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && fail "a process of the node is still running"
done

echo "[precondition] what the node knew is still on disk..."
sudo test -s "$LIB/containerd/io.containerd.metadata.v1.bolt/meta.db" || fail "the metadata database is gone"
[ "$(sudo find "$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ge 6 ] || fail "the snapshots are gone"

echo "[precondition] OK: containerd $(sudo "$LIB/node/bin/containerd" --version | awk '{print $3}') cannot recover the CRI state: two sandbox records for the pod web."
