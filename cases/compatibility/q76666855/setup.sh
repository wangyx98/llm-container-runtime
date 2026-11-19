#!/bin/bash
set -e

CASE_ID="bench76666855"
RUN_BASE="/run/$CASE_ID"              # sockets, exec root, pid files and logs of the lab's containerd and dockerd
LIB_BASE="/var/lib/$CASE_ID"          # their roots, the request endpoint and its log
WORK_DIR="/tmp/$CASE_ID"              # what the job has: the wrappers
STATE_DIR="$WORK_DIR/.bench"          # root-only record of what is true
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
EP_PORT=18666                         # the "staging API" that the load generator calls
IMAGE="$CASE_ID/load:1"
LOAD_BIN="/jmeter/bin/run-lp-endpoint-tests"
TARGET_NAME="lp-endpoint-runner";  TARGET_TAG="jmeter-lp-endpoints"
CONTROL_NAME="api-health-probe";   CONTROL_TAG="api-health-probe"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking what the case needs is installed (dockerd, docker, containerd, ctr, runc of this host are the stack under test)..."
for c in dockerd docker containerd ctr runc python3 sudo sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
dockerd --version; containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc exists (one tiny static program is the image)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE" "$RUN_BASE"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
sudo mkdir -p "$RUN_BASE/exec" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$LIB_BASE/etc" "$LIB_BASE/bin" "$LIB_BASE/endpoint"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo chmod 755 "$LIB_BASE" "$LIB_BASE/endpoint"
cd "$WORK_DIR"

# detached daemon launcher: $1 pid file, $2 log file, rest = the command (exec keeps the pid)
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the load generator (a static program standing for 'jmeter -n -t lp-endpoints.jmx': one request per second to the staging API, tagged with its name; it ends on SIGTERM)..."
cat > "$STATE_DIR/load.c" <<'CEOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static void bye(int s) { (void)s; _exit(0); }

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)atoi(argv[2]));
    a.sin_addr.s_addr = inet_addr(argv[1]);
    for (;;) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
            char b[256], r[128];
            int n = snprintf(b, sizeof b, "GET /z-api/lp-endpoints?src=%s HTTP/1.0\r\nHost: staging\r\n\r\n", argv[3]);
            if (write(s, b, n) > 0 && read(s, r, sizeof r) < 0) { }
        }
        if (s >= 0) close(s);
        sleep(1);
    }
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/load" "$STATE_DIR/load.c"
mkdir -p "$STATE_DIR/rootfs$(dirname "$LOAD_BIN")"
cp "$STATE_DIR/load" "$STATE_DIR/rootfs$LOAD_BIN"
chmod 0755 "$STATE_DIR/rootfs$LOAD_BIN"

echo "[setup] the staging API stand-in (127.0.0.1:$EP_PORT; one line 'epoch tag' per request in $LIB_BASE/endpoint/hits.log)..."
cat > "$STATE_DIR/endpoint.py" <<'PYEOF'
import http.server
import re
import sys
import time

LOG, PORT = sys.argv[1], int(sys.argv[2])


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        m = re.search(r"[?&]src=([A-Za-z0-9_.-]+)", self.path)
        with open(LOG, "a") as f:
            f.write("%.3f %s\n" % (time.time(), m.group(1) if m else "-"))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF
sudo install -m 0644 "$STATE_DIR/endpoint.py" "$LIB_BASE/bin/endpoint.py"
sudo touch "$LIB_BASE/endpoint/hits.log"; sudo chmod 0644 "$LIB_BASE/endpoint/hits.log"

echo "[setup] containerd and dockerd of the lab (own sockets, roots, exec root and cgroup parent; the machine's own services are not touched)..."
sudo tee "$LIB_BASE/etc/containerd.toml" >/dev/null <<EOF
version = 2
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "$CTD_SOCK"
[ttrpc]
  address = "$CTD_SOCK.ttrpc"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
EOF
FEATURE=""
dockerd --help 2>&1 | grep -q -- '--feature' && FEATURE="--feature containerd-snapshotter=false"
cat > "$STATE_DIR/stack.tmpl" <<'SEOF'
#!/bin/bash
# stack start|stop|restart|status: the services of this machine's container stack, like `systemctl start|stop|restart containerd docker`: a containerd and a dockerd of the lab (own sockets
# and roots below __RUN__ and __LIB__; the machine's own services are not touched)
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
RUN="__RUN__"; LIB="__LIB__"
CSOCK="$RUN/containerd.sock"; DSOCK="$RUN/docker.sock"

alive() { local p; [ -s "$1" ] && p=$(cat "$1") && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$2" ]; }
launch() { local pf="$1" lg="$2"; shift 2
    setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >>"$log" 2>&1 </dev/null' _ "$pf" "$lg" "$@" </dev/null >/dev/null 2>&1; }
stop_one() {   # pid file, process name
    local p; alive "$1" "$2" || return 0
    p=$(cat "$1"); kill -TERM "$p" 2>/dev/null
    for _ in $(seq 1 120); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.5; done
    kill -KILL "$p" 2>/dev/null; return 0
}
start() {
    mkdir -p "$RUN/exec"
    alive "$RUN/containerd.pid" containerd || launch "$RUN/containerd.pid" "$RUN/containerd.log" __CONTAINERD__ --config "$LIB/etc/containerd.toml"
    for _ in $(seq 1 60); do __CTR__ -a "$CSOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
    __CTR__ -a "$CSOCK" version >/dev/null 2>&1 || { echo "stack: containerd did not come up"; tail -5 "$RUN/containerd.log"; return 1; }
    alive "$RUN/dockerd.pid" dockerd || { rm -f "$DSOCK" "$RUN/docker.pid"
        launch "$RUN/dockerd.pid" "$RUN/dockerd.log" __DOCKERD__ --host "unix://$DSOCK" --pidfile "$RUN/docker.pid" --data-root "$LIB/docker" --exec-root "$RUN/exec" \
            --containerd "$CSOCK" --exec-opt native.cgroupdriver=cgroupfs --cgroup-parent __CID__ __FEATURE__ --bridge none --iptables=false --ip6tables=false --ip-forward=false; }
    for _ in $(seq 1 120); do __DOCKER__ -H "unix://$DSOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
    __DOCKER__ -H "unix://$DSOCK" version >/dev/null 2>&1 || { echo "stack: dockerd did not come up"; tail -5 "$RUN/dockerd.log"; return 1; }
}
stop() {
    stop_one "$RUN/dockerd.pid" dockerd
    stop_one "$RUN/containerd.pid" containerd
    for p in $(pgrep -f "containerd-shim-runc-v2.* -address $CSOCK"); do kill -TERM "$p" 2>/dev/null; done
    return 0
}
status() {
    alive "$RUN/containerd.pid" containerd && echo "containerd: running (pid $(cat "$RUN/containerd.pid"))" || echo "containerd: stopped"
    alive "$RUN/dockerd.pid" dockerd && echo "dockerd: running (pid $(cat "$RUN/dockerd.pid"))" || echo "dockerd: stopped"
}
case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)  status ;;
    *) echo "usage: stack start|stop|restart|status" >&2; exit 2 ;;
esac
SEOF
sed -e "s|__RUN__|$RUN_BASE|g" -e "s|__LIB__|$LIB_BASE|g" -e "s|__CID__|$CASE_ID|g" -e "s|__FEATURE__|$FEATURE|g" \
    -e "s|__CONTAINERD__|$(command -v containerd)|g" -e "s|__CTR__|$(command -v ctr)|g" -e "s|__DOCKERD__|$(command -v dockerd)|g" -e "s|__DOCKER__|$(command -v docker)|g" \
    "$STATE_DIR/stack.tmpl" > "$WORK_DIR/bin/stack"
chmod 0755 "$WORK_DIR/bin/stack"
cat > "$WORK_DIR/bin/docker" <<EOF
#!/bin/sh
# docker ARGS...: the docker client against the lab's dockerd
exec sudo $(command -v docker) -H unix://$DOCKER_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/ctr" <<EOF
#!/bin/sh
# ctr ARGS...: ctr against the lab's containerd (no namespace is chosen for you: ctr's default is "default")
exec sudo $(command -v ctr) -a $CTD_SOCK "\$@"
EOF
chmod 0755 "$WORK_DIR/bin/docker" "$WORK_DIR/bin/ctr"
cp "$WORK_DIR/bin/stack" "$STATE_DIR/stack"

start_daemon "$RUN_BASE/endpoint.pid" "$RUN_BASE/endpoint.log" python3 "$LIB_BASE/bin/endpoint.py" "$LIB_BASE/endpoint/hits.log" "$EP_PORT"
"$WORK_DIR/bin/stack" start || { echo "[setup] ERROR: the stack did not come up"; exit 1; }
echo "  -> $(sudo "$WORK_DIR/bin/stack" status | tr '\n' ' ')"

echo "[setup] the image (docker import of one static program), the load generator's container (restart policy always) and a healthy neighbour (unless-stopped)..."
D="sudo docker -H unix://$DOCKER_SOCK"
tar -C "$STATE_DIR/rootfs" -cf - . | $D import -c "ENTRYPOINT [\"$LOAD_BIN\"]" - "$IMAGE" >/dev/null || { echo "[setup] ERROR: docker import failed"; exit 1; }
TARGET_ID=$($D run -d --name "$TARGET_NAME" --restart always --network host "$IMAGE" 127.0.0.1 "$EP_PORT" "$TARGET_TAG") || { echo "[setup] ERROR: could not start the load generator's container"; exit 1; }
CONTROL_ID=$($D run -d --name "$CONTROL_NAME" --restart unless-stopped --network host "$IMAGE" 127.0.0.1 "$EP_PORT" "$CONTROL_TAG") || { echo "[setup] ERROR: could not start the neighbour"; exit 1; }
for _ in $(seq 1 30); do
    [ "$(awk '$2=="'$TARGET_TAG'"' "$LIB_BASE/endpoint/hits.log" | wc -l)" -ge 2 ] && [ "$(awk '$2=="'$CONTROL_TAG'"' "$LIB_BASE/endpoint/hits.log" | wc -l)" -ge 2 ] && break
    sleep 0.5
done
[ "$(awk '$2=="'$TARGET_TAG'"' "$LIB_BASE/endpoint/hits.log" | wc -l)" -ge 2 ] || { echo "[setup] ERROR: the staging API sees no requests from the load generator"; exit 1; }
echo "  -> both containers run and call the staging API"

echo "[setup] recording the state (root-only): the endpoint (pid + start time), the programs of the stack, hashes of the scripts and configuration, the two containers..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" DOCKER_SOCK="$DOCKER_SOCK" IMAGE="$IMAGE" \
    TARGET_ID="$TARGET_ID" CONTROL_ID="$CONTROL_ID" TARGET_TAG="$TARGET_TAG" CONTROL_TAG="$CONTROL_TAG" LOAD_BIN="$LOAD_BIN" EP_PORT="$EP_PORT" \
    DOCKERD_BIN="$(command -v dockerd)" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
def inspect(i):
    j = json.loads(subprocess.check_output(["docker", "-H", "unix://" + E["DOCKER_SOCK"], "inspect", i]))[0]
    return {"id": j["Id"], "name": j["Name"], "image": j["Image"], "args": j["Args"], "path": j["Path"], "created": j["Created"], "policy": j["HostConfig"]["RestartPolicy"]["Name"]}
files = [E["LIB_BASE"] + "/etc/containerd.toml", E["LIB_BASE"] + "/bin/endpoint.py", E["STATE_DIR"] + "/stack"] + [E["WORK_DIR"] + "/bin/" + n for n in ("stack", "docker", "ctr")]
d = {"endpoint": ident("endpoint"), "files": {f: sha(f) for f in files}, "dockerd_bin": os.path.realpath(E["DOCKERD_BIN"]),
     "hits": E["LIB_BASE"] + "/endpoint/hits.log", "load_bin": E["LOAD_BIN"], "target_tag": E["TARGET_TAG"], "control_tag": E["CONTROL_TAG"],
     "target": inspect(E["TARGET_ID"]), "control": inspect(E["CONTROL_ID"])}
assert d["target"]["policy"] == "always" and d["control"]["policy"] == "unless-stopped"
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
rm -rf "$STATE_DIR/rootfs" "$STATE_DIR/load" "$STATE_DIR/load.c" "$STATE_DIR/endpoint.py" "$STATE_DIR/stack.tmpl"
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. containerd and dockerd of the lab run; $TARGET_NAME (restart policy always) and $CONTROL_NAME call the staging API on 127.0.0.1:$EP_PORT; the job's files are in $WORK_DIR."
