#!/bin/bash
set -e

W=/tmp/bench73971174
F="$W/forwarder"

cat > "$F/forward.py" <<'EOF'
#!/usr/bin/env python3
# Forwards the CRI log files of the node's containers to the systemd journal, live: one entry per line, MESSAGE = the line, PRIORITY 6 (stdout) or 3 (stderr),
# CONTAINER_ID_FULL = the container's id (asked from containerd through the CRI). New containers are found by rescanning the log directory; a new file is read
# from its first byte; a line that the CRI cut into pieces (P ... F) is one entry.
import glob, json, os, socket, subprocess, time

PODLOG = "/var/log/bench73971174/pods"
SOCK = "unix:///run/bench73971174/containerd.sock"
JOURNAL = "/run/systemd/journal/socket"
PRIO = {"stdout": b"6", "stderr": b"3"}

sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
files = {}          # path -> {"off": bytes consumed, "id": container id, "part": pieces of an unfinished line}
paths = {}          # log path -> container id (asked from containerd)


def crictl(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", SOCK, "--image-endpoint", SOCK] + list(a), capture_output=True, text=True).stdout


def refresh_ids():
    for cid in crictl("ps", "-a", "-q", "--no-trunc").split():
        if cid in paths.values():
            continue
        try:
            paths[json.loads(crictl("inspect", "-o", "json", cid))["status"]["logPath"]] = cid
        except Exception:
            pass


def emit(cid, stream, text):
    sock.sendto(b"MESSAGE=" + text + b"\nPRIORITY=" + PRIO.get(stream, b"6") + b"\nCONTAINER_ID_FULL=" + cid.encode() + b"\nSYSLOG_IDENTIFIER=cri-forward\n", JOURNAL)


while True:
    found = glob.glob(PODLOG + "/*/*/*.log")
    if any(p not in files and p not in paths for p in found):
        refresh_ids()
    for p in found:
        if p not in paths:
            continue
        st = files.setdefault(p, {"off": 0, "id": paths[p], "part": b""})
        try:
            with open(p, "rb") as fh:
                fh.seek(st["off"])
                data = fh.read()
        except OSError:
            continue
        end = data.rfind(b"\n") + 1
        for line in data[:end].split(b"\n")[:-1]:
            try:
                _, stream, tag, text = line.split(b" ", 3)
            except ValueError:
                continue
            st["part"] += text
            if tag == b"F":
                emit(st["id"], stream.decode(), st["part"])
                st["part"] = b""
        st["off"] += end
    time.sleep(0.5)
EOF
sudo setsid -f python3 "$F/forward.py" >"$F/forward.log" 2>&1 </dev/null
sleep 3
echo "forwarder started: $(pgrep -f "$F/forward.py" | head -1)"
