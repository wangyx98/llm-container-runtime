#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench60714937"
WORK_DIR="/tmp/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"

# the registry process of the lab: it was started from the pid file; kill by name AND command line (not 'pkill -f <path>': that would also kill any shell whose own command line
# contains the path, including the one running this script)
for pid in $(pgrep -x python3 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$WORK_DIR|registry\.py.*10\.249\.60\.1"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
done

# the kind cluster of the lab: its node containers (kind labels them with the cluster name) with their volumes, then the Docker network
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    echo "[cleanup] removing the node containers of the kind cluster $CASE_ID and the Docker network..."
    IDS=$(sudo timeout -k 5 60 docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CASE_ID" 2>/dev/null)
    [ -n "$IDS" ] && sudo timeout -k 5 120 docker rm -f -v $IDS >/dev/null 2>&1
    # a node container left under its name by a cluster that was made in some other way
    for n in "$CASE_ID-control-plane" "$CASE_ID-worker" "$CASE_ID-worker2"; do
        sudo timeout -k 5 60 docker rm -f -v "$n" >/dev/null 2>&1
    done
    sudo timeout -k 5 60 docker network rm "$CASE_ID" >/dev/null 2>&1
fi

# anything of a solution that still runs from the work dir (a kind or kubectl client)
for comm in kind kubectl; do
    for pid in $(pgrep -x "$comm" 2>/dev/null); do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CASE_ID" && sudo kill -KILL "$pid" 2>/dev/null
    done
done

# the Docker service, when this case started it (it was stopped before): the other cases that need a private dockerd refuse to run beside a running one
if [ -e "$LIB_BASE/docker_started_by_case" ]; then
    echo "[cleanup] stopping the docker service this case started..."
    command -v systemctl >/dev/null 2>&1 && sudo systemctl stop docker.service docker.socket >/dev/null 2>&1
fi

# the dockerd and the containerd of the lab (helpers/start-docker.sh), when they were started: by their pid files, only when the command line is the lab's
RUN_BASE="/run/$CASE_ID"
for f in dockerd containerd; do
    P=$(sudo cat "$RUN_BASE/$f.pid" 2>/dev/null)
    if [ -n "$P" ] && sudo tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | grep -q "$CASE_ID"; then
        echo "[cleanup] stopping the $f of the lab..."
        sudo kill -TERM "$P" 2>/dev/null
        for _ in $(seq 1 40); do sudo kill -0 "$P" 2>/dev/null || break; sleep 0.5; done
        sudo kill -0 "$P" 2>/dev/null && sudo kill -KILL "$P" 2>/dev/null
    fi
done
if [ -d "$RUN_BASE" ]; then
    # mounts the daemons left (network namespaces, container roots), deepest first, then the directory itself
    for m in $(awk -v b="$RUN_BASE" 'index($2, b)==1 {print $2}' /proc/self/mountinfo | sort -r); do sudo umount -l "$m" 2>/dev/null; done
    sudo rm -rf "$RUN_BASE"
    [ -S /var/run/docker.sock ] && ! sudo docker info >/dev/null 2>&1 && sudo rm -f /var/run/docker.sock
fi

echo "[cleanup] removing the kind binary and the work dir (the downloaded binary stays in /var/cache/$CASE_ID)..."
sudo rm -rf "$LIB_BASE" "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
