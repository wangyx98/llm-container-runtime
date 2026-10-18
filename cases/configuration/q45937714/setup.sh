#!/bin/bash
set -e

CASE_ID="bench45937714"
LIB="/var/lib/$CASE_ID"                          # the engineer's daemon: configuration, data root, the bind-mounted configuration file
RUN="/run/$CASE_ID"                              # its socket, pid file, exec root and log
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only): the truth about the container
SRC="unix://$RUN/src.sock"
IMAGE="localhost/$CASE_ID/web:1"
PORT=18437

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking docker, dockerd, python3, curl and sudo..."
for c in docker dockerd python3 curl sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
echo "  host: $(docker --version | head -1), $(dockerd --version | head -1), $(uname -m)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] checking that port $PORT is free..."
python3 - "$PORT" <<'PYEOF' || { echo "[setup] ERROR: something already listens on port $PORT"; exit 1; }
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PYEOF

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be pulled from a registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"

# ---- the service: a static program that answers HTTP with what it finds around it: its environment, its arguments, its working directory, the configuration file,
# the data file (size and checksum) and a file in the writable layer of the container
echo "[setup] building the service image offline (one static program, a docker archive for docker load)..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

static void slurp(const char *path, char *out, size_t n) {
    FILE *f = fopen(path, "r");
    size_t k = 0;
    if (!f) { snprintf(out, n, "missing"); return; }
    k = fread(out, 1, n - 1, f);
    fclose(f);
    while (k > 0 && (out[k - 1] == '\n' || out[k - 1] == '\r')) k--;
    out[k] = 0;
}

static void fnv(const char *path, char *out, size_t n) {
    FILE *f = fopen(path, "rb");
    unsigned long long h = 1469598103934665603ULL, size = 0;
    int c;
    if (!f) { snprintf(out, n, "missing"); return; }
    while ((c = fgetc(f)) != EOF) { h ^= (unsigned char)c; h *= 1099511628211ULL; size++; }
    fclose(f);
    snprintf(out, n, "%llu:%016llx", size, h);
}

int main(int argc, char **argv) {
    const char *title = "none";
    int port = 8080, i;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--title") && i + 1 < argc) title = argv[++i];
        else if (!strcmp(argv[i], "--listen") && i + 1 < argc) port = atoi(argv[++i]);
    }
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(port);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 16) < 0) { perror("bind"); return 1; }
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        char req[1024], conf[256], data[64], marker[256], cwd[256], body[1536], head[160];
        (void)!read(c, req, sizeof req);
        slurp("/etc/app.conf", conf, sizeof conf);
        fnv("/data/records.bin", data, sizeof data);
        slurp("/var/lib/marker.txt", marker, sizeof marker);
        if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
        int n = snprintf(body, sizeof body, "nonce=%s\nmode=%s\nextra=%s\ntitle=%s\nworkdir=%s\nconf=%s\ndata=%s\nmarker=%s\n",
                         getenv("NONCE") ? getenv("NONCE") : "unset", getenv("APP_MODE") ? getenv("APP_MODE") : "unset",
                         getenv("EXTRA") ? getenv("EXTRA") : "unset", title, cwd, conf, data, marker);
        int m = snprintf(head, sizeof head, "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", n);
        (void)!write(c, head, m);
        (void)!write(c, body, n);
        close(c);
    }
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cat > "$STATE_DIR/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF PROGRAM : a one-layer docker archive (docker save format): PROGRAM as /srv/app, the directories the service needs, entrypoint /srv/app"""
import hashlib
import io
import json
import os
import sys
import tarfile

out, ref, prog = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d in ("srv", "opt", "opt/work", "etc", "data", "var", "var/lib", "tmp"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 1700000000
        t.addfile(ti)
    with open(prog, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo("srv/app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Entrypoint": ["/srv/app"], "Cmd": ["--listen", "8080", "--title", "default"], "WorkingDir": "/srv",
                                "ExposedPorts": {"8080/tcp": {}}},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$IMAGE" "$STATE_DIR/app"

# ---- the engineer's daemon: private (own socket, data root, exec root, address pool), classic image store, no iptables; the docker of this host is not touched
echo "[setup] starting the engineer's docker daemon (socket $RUN/src.sock)..."
sudo install -d -m 755 "$LIB/etc" "$LIB/src-data" "$LIB/conf" "$RUN/src-exec"
cat <<CEOF | sudo tee "$LIB/etc/src.json" >/dev/null
{
  "data-root": "$LIB/src-data",
  "exec-root": "$RUN/src-exec",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "features": {"containerd-snapshotter": false},
  "bridge": "none",
  "iptables": false,
  "ip6tables": false,
  "ip-forward": false,
  "default-address-pools": [{"base": "10.77.0.0/16", "size": 24}]
}
CEOF
sudo setsid -f sh -c "exec dockerd --config-file $LIB/etc/src.json --host $SRC --pidfile $RUN/src.pid >$RUN/src.log 2>&1 </dev/null"
for _ in $(seq 100); do sudo env DOCKER_HOST="$SRC" docker version >/dev/null 2>&1 && break; sleep 0.3; done
sudo env DOCKER_HOST="$SRC" docker version >/dev/null 2>&1 || { echo "[setup] ERROR: the daemon did not come up"; sudo tail -15 "$RUN/src.log"; exit 1; }
export DOCKER_HOST="$SRC"
sudo env DOCKER_HOST="$SRC" docker load -i "$STATE_DIR/web.tar" >/dev/null || { echo "[setup] ERROR: docker load failed"; exit 1; }

# ---- what somebody else did, once: the run command is not kept anywhere (not here, not in a file of the host, not in a history)
echo "[setup] the container web is started the way somebody else did it (the command is not kept)..."
NONCE="n-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
SALT="$(python3 -c 'import secrets; print(secrets.token_hex(5))')"
MARKER="marker-$(python3 -c 'import secrets; print(secrets.token_hex(5))')"
D="sudo env DOCKER_HOST=$SRC docker"
$D network create appnet >/dev/null
$D volume create webdata >/dev/null
MP="$($D volume inspect -f '{{.Mountpoint}}' webdata)"
sudo sh -c 'head -c 65536 /dev/urandom > "$1/records.bin"' _ "$MP"
printf 'greeting=hello-%s\n' "$SALT" | sudo tee "$LIB/conf/app.conf" >/dev/null
$D run -d --name web --restart unless-stopped --network appnet --network-alias web-svc -p 127.0.0.1:$PORT:8080 \
    -e NONCE="$NONCE" -e APP_MODE=blue -e 'EXTRA=a b=c' --label bench.role=web \
    -v webdata:/data -v "$LIB/conf/app.conf:/etc/app.conf:ro" -w /opt/work "$IMAGE" --title 'Backup Test' --listen 8080 >/dev/null
printf '%s\n' "$MARKER" > "$STATE_DIR/marker.txt"
$D cp "$STATE_DIR/marker.txt" web:/var/lib/marker.txt
for _ in $(seq 30); do curl -s --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/" | grep -q "^nonce=$NONCE$" && break; sleep 0.5; done
BODY="$(curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/")"
echo "$BODY" | grep -q "^nonce=$NONCE$" || { echo "[setup] ERROR: the service does not answer with its nonce"; echo "$BODY"; $D logs web 2>&1 | tail -5; exit 1; }
echo "$BODY" | sed 's/^/  | /'

echo "[setup] recording what is true now (the container's configuration, the hashes of its data, the answer of the service)..."
sudo python3 - "$STATE_DIR" "$LIB" "$SRC" "$NONCE" <<'PYEOF'
import hashlib
import json
import subprocess
import sys
import urllib.request

state, lib, src, nonce = sys.argv[1:5]
inspect = json.loads(subprocess.run(["docker", "-H", src, "inspect", "web"], capture_output=True, text=True, check=True).stdout)[0]
cfg, host = inspect["Config"], inspect["HostConfig"]
mounts = {m["Destination"]: m for m in inspect["Mounts"]}
mp = subprocess.run(["docker", "-H", src, "volume", "inspect", "-f", "{{.Mountpoint}}", "webdata"], capture_output=True, text=True, check=True).stdout.strip()
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
truth = {
    "id": inspect["Id"],
    "cmd": cfg["Cmd"],
    "entrypoint": cfg["Entrypoint"],
    "env": sorted(e for e in cfg["Env"] if e.split("=", 1)[0] in ("NONCE", "APP_MODE", "EXTRA")),
    "workdir": cfg["WorkingDir"],
    "label": cfg["Labels"].get("bench.role"),
    "restart": host["RestartPolicy"]["Name"],
    "ports": host["PortBindings"],
    "volume": [mounts["/data"]["Name"], mounts["/data"]["Type"]],
    "bind": [mounts["/etc/app.conf"]["Type"], mounts["/etc/app.conf"]["RW"]],
    "alias": inspect["NetworkSettings"]["Networks"]["appnet"]["Aliases"],
    "data_sha": sha(mp + "/records.bin"),
    "conf_sha": sha(lib + "/conf/app.conf"),
    "marker_sha": sha(state + "/marker.txt"),
    "body": urllib.request.urlopen("http://127.0.0.1:18437/", timeout=5).read().decode(),
    "nonce": nonce,
}
assert truth["restart"] == "unless-stopped" and truth["alias"] and "web-svc" in truth["alias"] and truth["bind"][1] is False
json.dump(truth, open(state + "/truth.json", "w"), indent=1)
PYEOF
sudo rm -rf "$STATE_DIR/app" "$STATE_DIR/app.c" "$STATE_DIR/mkarchive.py" "$STATE_DIR/web.tar" "$STATE_DIR/marker.txt"
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
history -c 2>/dev/null || true

echo "[setup] done. The container web runs on the engineer's daemon ($RUN/src.sock); the command that started it is not kept."
