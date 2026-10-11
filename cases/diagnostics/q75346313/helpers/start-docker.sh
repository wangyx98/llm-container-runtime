#!/bin/bash
# Start the Docker daemon of this lab: its own socket, data and containerd (already running). It runs with PATH=/tmp/bench75346313/tools and nothing
# else: that directory is the tool set of this machine as the update left it. Prints what it did and, if the daemon does not come up, the end of
# its log. Safe to run again.
CASE_ID="bench75346313"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
TOOLS="$WORK_DIR/tools"
DSOCK="$RUN_BASE/docker.sock"
CSOCK="$RUN_BASE/containerd.sock"
LOG="$RUN_BASE/dockerd.log"

if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then
    echo "dockerd is already running on $DSOCK"
    exit 0
fi
sudo rm -f "$DSOCK" "$RUN_BASE/docker.pid"
feature=()
dockerd --help 2>&1 | grep -q -- '--feature' && feature=(--feature containerd-snapshotter=false)
BASH_BIN=$(command -v bash); SETSID=$(command -v setsid); DOCKERD=$(command -v dockerd)

echo "starting dockerd (PATH=$TOOLS)..."
sudo env "PATH=$TOOLS" "$SETSID" -f "$BASH_BIN" -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
    _ "$RUN_BASE/dockerd.pid" "$LOG" \
    "$DOCKERD" --host "unix://$DSOCK" --pidfile "$RUN_BASE/docker.pid" --group "$(id -gn)" \
        --data-root "$LIB_BASE/docker" --exec-root "$RUN_BASE/exec" --containerd "$CSOCK" "${feature[@]}" \
        --bridge none --iptables=false --ip6tables=false --ip-forward=false </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then
        echo "dockerd is up on $DSOCK"
        exit 0
    fi
    P=$(sudo cat "$RUN_BASE/dockerd.pid" 2>/dev/null)
    if [ -n "$P" ] && ! sudo kill -0 "$P" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
echo "dockerd did not come up. The end of its log:"
sudo tail -8 "$LOG" 2>/dev/null | cut -c1-600
exit 1
