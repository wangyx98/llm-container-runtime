#!/bin/bash
set -e

CASE_ID="bench54303822"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, logs, containerd's state and Docker's exec root
LIB_BASE="/var/lib/$CASE_ID"          # containerd's root, Docker's data root, the wrappers, the data the containers mount
CTL_DIR="$LIB_BASE/bin"
CSOCK="$RUN_BASE/containerd.sock"
DSOCK="$RUN_BASE/docker.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the record of the lab (root only)
IMAGE="$CASE_ID.local/app:1"
TARGET="bench-api"                    # the container the task is about
DECOY="bench-batch"                   # another container of the same daemon, with other values

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking dockerd, docker, containerd, ctr, runc, python3 and sudo are installed (the engine under test)..."
for b in dockerd docker containerd ctr runc python3 sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
dockerd --version
containerd --version

# containerd's shim starts the runc found in its PATH: the newest runc of this host is put first (Docker 29 writes specs that runc 1.1 rejects)
RUNC_BIN=$(for r in $(type -ap runc | awk '!s[$0]++'); do
    v=$("$r" --version 2>/dev/null | awk '/version/{print $3; exit}')
    [ -n "$v" ] && printf '%s %s\n' "$v" "$r"
done | sort -V | tail -1 | awk '{print $2}')
[ -n "$RUNC_BIN" ] || { echo "[setup] ERROR: no working runc found"; exit 1; }
RUNC_DIR="$(dirname "$RUNC_BIN")"
echo "  -> runc: $RUNC_BIN ($("$RUNC_BIN" --version | head -1))"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so no image has to be pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/ctd" "$RUN_BASE/exec" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$LIB_BASE/etc" "$CTL_DIR" "$LIB_BASE/data-api" "$LIB_BASE/data-batch"
echo "api-data" | sudo tee "$LIB_BASE/data-api/marker" >/dev/null
echo "batch-data" | sudo tee "$LIB_BASE/data-batch/marker" >/dev/null

echo "[setup] building the image offline (one static program that waits for SIGTERM; docker import)..."
sudo tee "$STATE_DIR/app.c" >/dev/null <<'APP_C_EOF'
#include <signal.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(void) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;) pause();
}
APP_C_EOF
sudo mkdir -p "$STATE_DIR/root"
sudo gcc -static -Os -s -w -o "$STATE_DIR/root/app" "$STATE_DIR/app.c"

echo "[setup] starting a containerd (root, state and socket of its own) and a dockerd on top of it (the installed services are not touched)..."
cat <<CEOF | sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/ctd"

[grpc]
  address = "$CSOCK"
CEOF
sudo setsid -f bash -c 'echo $$ > "$1"; export PATH="$4:$PATH"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/etc/containerd.toml" "$RUN_BASE/containerd.log" "$RUNC_DIR" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    sudo ctr -a "$CSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the containerd of the lab did not come up:"; sudo tail -4 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

feature=()
dockerd --help 2>&1 | grep -q -- '--feature' && feature=(--feature containerd-snapshotter=false)
sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
    _ "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
    "$(command -v dockerd)" --host "unix://$DSOCK" --pidfile "$RUN_BASE/docker.pid" --data-root "$LIB_BASE/docker" --exec-root "$RUN_BASE/exec" \
        --containerd "$CSOCK" --exec-opt native.cgroupdriver=cgroupfs "${feature[@]}" --bridge none --iptables=false --ip6tables=false --ip-forward=false </dev/null >/dev/null 2>&1
for _ in $(seq 1 90); do
    sudo docker -H "unix://$DSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo docker -H "unix://$DSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the dockerd of the lab did not come up:"; sudo tail -4 "$RUN_BASE/dockerd.log" | cut -c1-300; exit 1; }
sudo docker -H "unix://$DSOCK" version --format '  -> Docker {{.Server.Version}}'

echo "[setup] the wrappers of the lab: docker and ctr for its daemons..."
printf '#!/bin/bash\n# the docker client of this machine'"'"'s lab daemon\nexec docker -H unix://%s "$@"\n' "$DSOCK" | sudo tee "$CTL_DIR/docker" >/dev/null
printf '#!/bin/bash\n# ctr for the containerd of the lab (Docker keeps its containers in the namespace moby)\nexec ctr -a %s "$@"\n' "$CSOCK" | sudo tee "$CTL_DIR/ctr" >/dev/null
sudo chmod 755 "$CTL_DIR/docker" "$CTL_DIR/ctr"
DK="sudo $CTL_DIR/docker"

echo "[setup] importing the image and starting the two containers (each with its own token, mount and limits)..."
sudo tar -C "$STATE_DIR/root" -cf - app | $DK import --change 'ENTRYPOINT ["/app"]' - "$IMAGE" >/dev/null || { echo "[setup] ERROR: docker import failed"; exit 1; }
T1=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
T2=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
$DK run -d --name "$TARGET" --hostname api-host -e "BENCH_TOKEN=$T1" -v "$LIB_BASE/data-api:/data:ro" --memory 96m --cpus 0.5 --network none "$IMAGE" >/dev/null \
    || { echo "[setup] ERROR: could not start $TARGET:"; sudo tail -3 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }
$DK run -d --name "$DECOY" --hostname batch-host -e "BENCH_TOKEN=$T2" -v "$LIB_BASE/data-batch:/data:ro" --memory 64m --cpus 1 --network none "$IMAGE" >/dev/null \
    || { echo "[setup] ERROR: could not start $DECOY"; exit 1; }
for n in "$TARGET" "$DECOY"; do
    [ "$($DK inspect -f '{{.State.Running}}' "$n")" = true ] || { echo "[setup] ERROR: $n is not running"; exit 1; }
done

echo "[setup] the record of what is true (the containers, their values, the daemons and their start times)..."
sudo python3 - "$DSOCK" "$CTL_DIR/docker" "$STATE_DIR" "$RUN_BASE" "$TARGET" "$DECOY" "$T1" "$T2" "$LIB_BASE" <<'PYEOF'
import json
import subprocess
import sys

dsock, docker, state, run, target, decoy, t1, t2, lib = sys.argv[1:10]


def start(pid):
    return open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[19]


rec = {"daemons": {}, "containers": {}}
for name, pidfile in (("dockerd", run + "/dockerd.pid"), ("containerd", run + "/containerd.pid")):
    pid = open(pidfile).read().strip()
    rec["daemons"][name] = {"pid": pid, "start": start(pid)}
for name, tok in ((target, t1), (decoy, t2)):
    j = json.loads(subprocess.check_output([docker, "inspect", name]))[0]
    rec["containers"][name] = {"id": j["Id"], "pid": str(j["State"]["Pid"]), "start": start(j["State"]["Pid"]), "token": tok,
                               "memory": j["HostConfig"]["Memory"], "nanocpus": j["HostConfig"]["NanoCpus"], "hostname": j["Config"]["Hostname"]}
json.dump(rec, open(state + "/lab.json", "w"), indent=1)
PYEOF
echo "[setup] Done."
