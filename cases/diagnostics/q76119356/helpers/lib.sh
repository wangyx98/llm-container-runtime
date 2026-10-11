# Functions to start and stop one "Docker endpoint": a private containerd and a private dockerd on it, with its own sockets, data and runtime
# configuration. Sourced by setup.sh (endpoints a and b) and by oracle.sh (a third one, with names the solution cannot know).
# Needs: CASE_ID, RUN_BASE, LIB_BASE, STATE_DIR.

RUNC_BIN="$(command -v runc)"

start_daemon() {   # $1 pid file, $2 log file, rest = the command; detached, the pid file holds the pid of the daemon itself
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

endpoint_sock() { echo "$RUN_BASE/$1/docker.sock"; }

# start_endpoint NAME DEFAULT_RUNTIME EXTRA_RUNTIME : the daemon's configured runtimes are runc, EXTRA_RUNTIME, and DEFAULT_RUNTIME (which is
# the default runtime of this daemon; "runc" for the one that keeps Docker's own default)
start_endpoint() {
    local e=$1 def=$2 extra=$3
    local run="$RUN_BASE/$e" lib="$LIB_BASE/$e"
    local csock="$run/containerd.sock" dsock; dsock=$(endpoint_sock "$e")
    sudo mkdir -p "$run/exec" "$lib/containerd" "$lib/docker" "$lib/etc"
    containerd config default \
        | python3 "$STATE_DIR/patch_config.py" "$lib/containerd" "$run" "$csock" \
        | sudo tee "$lib/etc/config.toml" >/dev/null
    start_daemon "$run/containerd.pid" "$run/containerd.log" containerd --config "$lib/etc/config.toml"
    local _
    for _ in $(seq 1 60); do
        [ -S "$csock" ] && sudo ctr -a "$csock" version >/dev/null 2>&1 && break
        sleep 0.5
    done
    sudo ctr -a "$csock" version >/dev/null 2>&1 || { echo "[endpoint $e] ERROR: its containerd did not come up"; sudo tail -10 "$run/containerd.log"; return 1; }
    local feature=() rt=(--add-runtime "$extra=$RUNC_BIN")
    dockerd --help 2>&1 | grep -q -- '--feature' && feature=(--feature containerd-snapshotter=false)
    [ "$def" != runc ] && rt+=(--add-runtime "$def=$RUNC_BIN" --default-runtime "$def")
    start_daemon "$run/dockerd.pid" "$run/dockerd.log" \
        dockerd --host "unix://$dsock" --pidfile "$run/docker.pid" --group "$(id -gn)" \
            --data-root "$lib/docker" --exec-root "$run/exec" --containerd "$csock" "${feature[@]}" "${rt[@]}" \
            --bridge none --iptables=false --ip6tables=false --ip-forward=false
    for _ in $(seq 1 90); do
        [ -S "$dsock" ] && docker -H "unix://$dsock" info >/dev/null 2>&1 && break
        sleep 0.5
    done
    docker -H "unix://$dsock" info >/dev/null 2>&1 || { echo "[endpoint $e] ERROR: its dockerd did not come up"; sudo tail -10 "$run/dockerd.log"; return 1; }
    local d P
    for d in containerd dockerd; do
        P=$(sudo cat "$run/$d.pid")
        echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/$e-$d.id"
    done
}

# stop_endpoint NAME : its dockerd and its containerd (by the pid files)
stop_endpoint() {
    local e=$1 d P _
    for d in dockerd containerd; do
        P=$(sudo cat "$RUN_BASE/$e/$d.pid" 2>/dev/null) || continue
        sudo kill "$P" 2>/dev/null || true
        for _ in $(seq 1 40); do sudo kill -0 "$P" 2>/dev/null || break; sleep 0.25; done
        sudo kill -9 "$P" 2>/dev/null || true
    done
}
