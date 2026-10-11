#!/bin/bash
# `crictl logs` reads only the container's current log file, so it misses what the node rotated away; the log of a container lives in the file
# `crictl inspect` reports as its logPath plus the rotated files beside it (logPath.TIMESTAMP, the older ones gzipped), oldest first. A record of
# such a file is "TIMESTAMP STREAM TAG TEXT" (TAG F is a complete line, P a part of one that continues in the next record). The exit code and the reason
# are in the same `crictl inspect` status. A container is known by its name and attempt; `crictl ps -a` lists the stopped ones too. The node's
# containerd is not at the default socket, so the endpoint is given.
set -e
cat > /tmp/bench71034357/stopped-logs.sh <<'SCRIPT'
#!/bin/bash
# stopped-logs.sh CONTAINER_NAME ATTEMPT OUTPUT_DIR
set -e
python3 - "$@" <<'PY'
import glob
import gzip
import json
import os
import subprocess
import sys

SOCK = "/run/bench71034357/containerd/containerd.sock"
name, attempt, out = sys.argv[1:4]


def cri(command, *args):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, command, "-o", "json", *args],
                       capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def read(path):
    raw = subprocess.run(["sudo", "cat", path], capture_output=True, check=True).stdout
    return gzip.decompress(raw) if path.endswith(".gz") else raw


found = [c for c in cri("ps", "-a", "--name", "^%s$" % name)["containers"] if str(c["metadata"]["attempt"]) == attempt]
if len(found) != 1:
    sys.exit("no single container %s attempt %s" % (name, attempt))
status = cri("inspect", found[0]["id"])["status"]
log = status["logPath"]
files = sorted(glob.glob(log + ".*")) + [log]          # the timestamps sort in time order; the current file is the newest

streams = {"stdout": b"", "stderr": b""}
for f in files:
    for line in read(f).split(b"\n"):
        if line:
            stamp, stream, tag, text = (line.split(b" ", 3) + [b""])[:4]
            streams[stream.decode()] += text + (b"\n" if tag == b"F" else b"")

os.makedirs(out, exist_ok=True)
for stream, data in streams.items():
    open(os.path.join(out, stream + ".txt"), "wb").write(data)
open(os.path.join(out, "exit.txt"), "w").write("%d\n%s\n" % (status["exitCode"], status["reason"]))
PY
SCRIPT
chmod +x /tmp/bench71034357/stopped-logs.sh

bash /tmp/bench71034357/stopped-logs.sh job 0 /tmp/bench71034357/out
