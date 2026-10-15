#!/bin/bash
# start-docker.sh : a Docker daemon of this lab, for a machine where the installed docker service does not come up. It runs a containerd of its own (own socket,
# root and state, NRI off) and a dockerd of its own on the DEFAULT socket /var/run/docker.sock (so 'sudo docker' and 'sudo kind' work as usual), with its own exec
# root and the images in /var/cache/bench60714937/docker (the node image is pulled once). Pid files and logs are in /run/bench60714937; cleanup.sh stops both.
# Prints what it did; if the daemon does not come up, the end of its log. Safe to run again.
CASE_ID="bench60714937"
PATCH="$(cd "$(dirname "$0")" && pwd)/patch_config.py"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
DATA="/var/cache/$CASE_ID/docker"
CSOCK="$RUN_BASE/containerd.sock"
DSOCK="/var/run/docker.sock"

sudo docker info >/dev/null 2>&1 && { echo "a Docker daemon already answers"; exit 0; }
for b in containerd dockerd; do
    command -v "$b" >/dev/null 2>&1 || { echo "$b is not installed (sudo apt-get install -y docker.io)"; exit 1; }
done
# a service that is half started may hold the socket (socket activation) or the default containerd name
command -v systemctl >/dev/null 2>&1 && sudo systemctl stop docker.service docker.socket >/dev/null 2>&1
sudo rm -f "$DSOCK"
sudo mkdir -p "$RUN_BASE/exec" "$LIB_BASE/containerd" "$LIB_BASE/etc" "$DATA"

if ! sudo ctr -a "$CSOCK" version >/dev/null 2>&1; then
    containerd config default | python3 "$PATCH" "$LIB_BASE/containerd" "$RUN_BASE" "$CSOCK" | sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null
    sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
        _ "$RUN_BASE/containerd.pid" "$LIB_BASE/etc/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 60); do
        sudo ctr -a "$CSOCK" version >/dev/null 2>&1 && break
        sleep 0.5
    done
    sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || { echo "the private containerd did not come up:"; sudo tail -4 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }
fi

feature=()
dockerd --help 2>&1 | grep -q -- '--feature' && feature=(--feature containerd-snapshotter=false)
BASH_BIN=$(command -v bash); SETSID=$(command -v setsid); DOCKERD=$(command -v dockerd)
# attempt 1: the usual networking of Docker (iptables, a bridge per network; no docker0); attempt 2 when that fails (no iptables here): without the firewall rules
for attempt in 1 2; do
    net=(--bridge none)
    [ "$attempt" = 2 ] && net=(--bridge none --iptables=false --ip6tables=false --ip-forward=false)
    sudo rm -f "$DSOCK" "$RUN_BASE/docker.pid"
    sudo "$SETSID" -f "$BASH_BIN" -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" \
        "$DOCKERD" --host "unix://$DSOCK" --pidfile "$RUN_BASE/docker.pid" --data-root "$DATA" --exec-root "$RUN_BASE/exec" \
            --containerd "$CSOCK" "${feature[@]}" "${net[@]}" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 60); do
        sudo docker info >/dev/null 2>&1 && { echo "dockerd of the lab is up on $DSOCK (attempt $attempt)"; exit 0; }
        P=$(sudo cat "$RUN_BASE/dockerd.pid" 2>/dev/null)
        [ -n "$P" ] && ! sudo kill -0 "$P" 2>/dev/null && break
        sleep 0.5
    done
    [ "$attempt" = 1 ] && { sudo kill -KILL "$(sudo cat "$RUN_BASE/dockerd.pid" 2>/dev/null)" 2>/dev/null; sleep 1; }
done
echo "dockerd did not come up. The end of its log:"
sudo tail -3 "$RUN_BASE/dockerd.log" 2>/dev/null | cut -c1-250
exit 1
