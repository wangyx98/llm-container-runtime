#!/bin/bash
set -e

CASE_ID="bench74677606"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, runtime state of the private daemons
LIB_BASE="/var/lib/$CASE_ID"          # roots of the daemons and the decoy container's root file system

# Docker (like Docker 20.10 in the SO question) runs its containers on a containerd of its own, whose
# socket is not the one a plain `ctr` uses, in the containerd namespace "moby". Layout as in real life:
#   dockerd API         $RUN_BASE/docker.sock
#   Docker's containerd $RUN_BASE/docker/containerd/containerd.sock   (the --containerd of dockerd)
# A second, independent containerd is the one the engineer's ctr points to:
#   other containerd    $RUN_BASE/containerd/containerd.sock
DOCKER_SOCK="$RUN_BASE/docker.sock"
DOCKER_EXEC="$RUN_BASE/docker"
DOCKERD_CTD_DIR="$DOCKER_EXEC/containerd"
DOCKERD_CTD_SOCK="$DOCKERD_CTD_DIR/containerd.sock"
OTHER_CTD_DIR="$RUN_BASE/containerd"
OTHER_CTD_SOCK="$OTHER_CTD_DIR/containerd.sock"

APP_NAME="$CASE_ID-app"               # the Docker container to find (its Docker name)
OTHER_NAME="$CASE_ID-other"           # a second Docker container
DECOY="$CASE_ID-decoy"                # a ctr container of the OTHER containerd, in its default namespace
IMAGE="$CASE_ID/app:1"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

DOCKER="sudo docker -H unix://$DOCKER_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking containerd, ctr, runc, dockerd and the docker CLI are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd and Docker cases)..."
for b in containerd ctr runc dockerd docker; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version
dockerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc and python3 are available (gcc: one tiny static program, the process of"
echo "[setup] every container, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] compiling the program of the containers: a static program that just sleeps..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/app" "$STATE_DIR/app.c"

cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF

start_containerd() {   # $1 = state dir (holds the socket), $2 = root dir, $3 = socket, $4 = name of the files
    sudo mkdir -p "$1" "$2"
    containerd config default \
        | python3 "$STATE_DIR/patch_config.py" "$2" "$1" "$3" \
        | sudo tee "$RUN_BASE/$4.toml" >/dev/null
    start_daemon "$RUN_BASE/$4.pid" "$RUN_BASE/$4.log" containerd --config "$RUN_BASE/$4.toml"
    for _ in $(seq 1 60); do
        [ -S "$3" ] && sudo ctr -a "$3" version >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ! sudo ctr -a "$3" version >/dev/null 2>&1; then
        echo "[setup] ERROR: the containerd $4 did not come up; last log lines:"
        sudo tail -20 "$RUN_BASE/$4.log" 2>/dev/null || true
        exit 1
    fi
    echo "  -> containerd $4 up on $3"
}

echo "[setup] starting the containerd of Docker (its own socket, root and state, NRI off)..."
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/docker"
start_containerd "$DOCKERD_CTD_DIR" "$LIB_BASE/docker-containerd" "$DOCKERD_CTD_SOCK" docker-containerd

echo "[setup] starting dockerd (API socket $DOCKER_SOCK) on that containerd, in debug mode (it logs"
echo "[setup] every API call; the oracle reads that log). No bridge/iptables: nothing here touches the"
echo "[setup] host's networking..."
FEATURE=()
if dockerd --help 2>&1 | grep -q -- '--feature'; then
    FEATURE=(--feature containerd-snapshotter=false)
fi
start_daemon "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
    dockerd --debug --host "unix://$DOCKER_SOCK" --pidfile "$RUN_BASE/docker.pid" \
        --data-root "$LIB_BASE/docker" --exec-root "$DOCKER_EXEC" \
        --containerd "$DOCKERD_CTD_SOCK" "${FEATURE[@]}" \
        --bridge none --iptables=false --ip6tables=false --ip-forward=false
for _ in $(seq 1 90); do
    [ -S "$DOCKER_SOCK" ] && $DOCKER info >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $DOCKER info >/dev/null 2>&1; then
    echo "[setup] ERROR: dockerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/dockerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> dockerd up on $DOCKER_SOCK"

echo "[setup] starting the other containerd, the one the engineer's ctr points to..."
start_containerd "$OTHER_CTD_DIR" "$LIB_BASE/containerd" "$OTHER_CTD_SOCK" containerd

echo "[setup] creating the Docker image and starting two Docker containers, each with its name in the"
echo "[setup] environment variable BENCH_NAME of its process (containerd knows nothing of Docker names)..."
tar -C "$STATE_DIR" -c app | $DOCKER import - "$IMAGE" >/dev/null
for n in "$APP_NAME" "$OTHER_NAME"; do
    $DOCKER run -d --name "$n" --network none -e "BENCH_NAME=$n" "$IMAGE" /app >/dev/null \
        || { echo "[setup] ERROR: could not start the Docker container $n"; exit 1; }
done
for _ in $(seq 1 40); do
    N=$(sudo ctr -a "$DOCKERD_CTD_SOCK" -n moby tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
    [ "$N" -eq 2 ] && break
    sleep 0.25
done
[ "$N" -eq 2 ] || { echo "[setup] ERROR: the two Docker containers are not both running"; exit 1; }

echo "[setup] starting a decoy with ctr in the OTHER containerd (default namespace), carrying the very"
echo "[setup] same BENCH_NAME as the Docker container: it is not started by Docker..."
sudo mkdir -p "$LIB_BASE/rootfs/$DECOY"
sudo cp "$STATE_DIR/app" "$LIB_BASE/rootfs/$DECOY/app"
sudo ctr -a "$OTHER_CTD_SOCK" run -d --env "BENCH_NAME=$APP_NAME" \
    --rootfs "$LIB_BASE/rootfs/$DECOY" "$DECOY" /app >/dev/null 2>&1 \
    || { echo "[setup] ERROR: could not start the decoy"; exit 1; }
for _ in $(seq 1 40); do
    sudo ctr -a "$OTHER_CTD_SOCK" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | grep -q . && break
    sleep 0.25
done

echo "[setup] recording the truth (Docker's own answer, the task PIDs, the shim PIDs) and the identity of"
echo "[setup] the three daemons (pid + start time)..."
sudo python3 - "$STATE_DIR" "$DOCKER_SOCK" "$DOCKERD_CTD_SOCK" "$OTHER_CTD_SOCK" "$APP_NAME" "$OTHER_NAME" "$DECOY" <<'PYEOF'
import http.client
import json
import socket
import subprocess
import sys

state, dsock, asock, bsock, app, other, decoy = sys.argv[1:8]


class UnixConn(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(dsock)


def inspect(name):
    c = UnixConn("localhost")
    c.request("GET", "/containers/%s/json" % name)
    return json.loads(c.getresponse().read())


def shim_pid(cid):
    out = subprocess.run(["ps", "-eo", "pid=,comm=,args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1].startswith("containerd-shim") and ("-id %s " % cid) in parts[2]:
            return int(parts[0])
    return 0


def task_pid(sock, ns, cid):
    cmd = ["ctr", "-a", sock] + (["-n", ns] if ns else []) + ["tasks", "ls"]
    for line in subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()[1:]:
        f = line.split()
        if f and f[0] == cid:
            return int(f[1])
    return 0


truth = {"docker_socket": dsock, "containerd_socket": asock, "other_containerd_socket": bsock,
         "namespace": "moby"}
for key, name in (("target", app), ("other", other)):
    i = inspect(name)
    cid = i["Id"]
    assert len(cid) == 64 and i["State"]["Running"], name
    assert task_pid(asock, "moby", cid) == i["State"]["Pid"], "docker and containerd disagree on the PID"
    truth[key] = {"id": cid, "pid": i["State"]["Pid"], "shim_pid": shim_pid(cid), "name": name}
truth["decoy"] = {"id": decoy, "pid": task_pid(bsock, "", decoy)}
json.dump(truth, open(state + "/truth.json", "w"), indent=1)
PYEOF
for d in docker-containerd dockerd containerd; do
    P=$(cat "$RUN_BASE/$d.pid")
    echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$d.id"
done
# where dockerd's log ends now: whatever the case's own scripts asked of Docker is before this point
sudo wc -c < "$RUN_BASE/dockerd.log" > "$STATE_DIR/api.baseline"
python3 -c 'import json,sys; t=json.load(open(sys.argv[1])); print("  -> target %s pid %s; other pid %s; decoy pid %s" % (t["target"]["id"][:12]+"...", t["target"]["pid"], t["other"]["pid"], t["decoy"]["pid"]))' "$STATE_DIR/truth.json"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/patch_config.py"

echo "[setup] done. Docker runs $APP_NAME and $OTHER_NAME on its own containerd; ctr's containerd has a decoy."
