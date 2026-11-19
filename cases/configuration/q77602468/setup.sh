#!/bin/bash
set -e

CASE_ID="bench77602468"
RUN_BASE="/run/$CASE_ID"              # sockets, exec root, pid files and logs of the lab's containerd, dockerd and CRI-O; CRI-O's run root
LIB_BASE="/var/lib/$CASE_ID"          # the lab's configuration, Docker's data root, CRI-O's storage root, the CNI stub
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
CRIO_SOCK="$RUN_BASE/crio.sock"
CRIO_ROOT="$LIB_BASE/crio/root"       # CRI-O's image and container storage (containers/storage graph root)
CRIO_RUNROOT="$RUN_BASE/crio"         # its run root
IMG="private-gcr.invalid/$CASE_ID/app:1.0"      # the private image: it exists in Docker's store only; nothing can pull it (.invalid never resolves)
PAUSE_IMG="localhost/$CASE_ID/pause:1"          # the pods' sandbox image, put in CRI-O's store by setup

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK"

echo "[setup] checking the stack under test is installed: CRI-O + crictl (the runtime that must run the image), dockerd + docker (where the image is)..."
echo "[setup] The case runs a private CRI-O and a private Docker daemon with their own sockets and storage: the machine's own services are not touched."
for b in crio crictl dockerd docker containerd python3 sudo sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
crio --version | head -1; dockerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc and skopeo are installed (gcc: the application is one static program; skopeo: the tool that copies images between stores)..."
need=()
command -v gcc >/dev/null 2>&1 || need+=(gcc libc6-dev)
command -v skopeo >/dev/null 2>&1 || need+=(skopeo)
if [ ${#need[@]} -gt 0 ]; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" "${need[@]}"
fi
skopeo --version

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/exec" "$LIB_BASE/etc" "$LIB_BASE/crio" "$LIB_BASE/cni/bin" "$LIB_BASE/cni/net.d"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

case "$(uname -m)" in x86_64) GOARCH=amd64 ;; aarch64|arm64) GOARCH=arm64 ;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;; esac

echo "[setup] building the images offline, in 'docker save' format: the application (one static program: it prints a line with a random token of this run"
echo "[setup] every 5 seconds, and prints the token alone when started with an argument) and the sandbox image of the pods (a static program that only waits)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argv;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1) { puts(TOKEN); return 0; }
    for (;;) {
        puts("bench77602468-app-ok token=" TOKEN);
        sleep(5);
    }
}
CEOF
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' > "$STATE_DIR/pause.c"
gcc -static -Os -s -w -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/app" "$STATE_DIR/app.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause" "$STATE_DIR/pause.c"
cat > "$STATE_DIR/mksave.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile
prog_path, entry, name, out, arch = sys.argv[1:6]
prog = open(prog_path, "rb").read()
def info(n, size, mode):
    t = tarfile.TarInfo(n); t.size = size; t.mode = mode; t.mtime = 0; return t
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    t.addfile(info(entry.lstrip("/"), len(prog), 0o755), io.BytesIO(prog))
layer = buf.getvalue()
diff_id = "sha256:" + hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": [entry]},
                  "rootfs": {"type": "layers", "diff_ids": [diff_id]}, "history": [{"created_by": "bench77602468 setup"}]}).encode()
ch = hashlib.sha256(cfg).hexdigest()
man = json.dumps([{"Config": ch + ".json", "RepoTags": [name], "Layers": [ch[:16] + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for n, d in ((ch + ".json", cfg), (ch[:16] + "/layer.tar", layer), ("manifest.json", man)):
        t.addfile(info(n, len(d), 0o644), io.BytesIO(d))
print(ch)
PYEOF
CONFIG_HEX=$(python3 "$STATE_DIR/mksave.py" "$STATE_DIR/app" /app "$IMG" "$STATE_DIR/app.tar" "$GOARCH")
python3 "$STATE_DIR/mksave.py" "$STATE_DIR/pause" /pause "$PAUSE_IMG" "$STATE_DIR/pause.tar" "$GOARCH" >/dev/null

echo "[setup] the private containerd and Docker daemon of the lab (own sockets, roots and exec root; no bridge, no iptables)..."
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
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" "$(command -v containerd)" --config "$LIB_BASE/etc/containerd.toml"
for _ in $(seq 1 60); do sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the lab's containerd did not come up"; sudo tail -5 "$RUN_BASE/containerd.log"; exit 1; }
# shellcheck disable=SC2086
start_daemon "$RUN_BASE/dockerd.pid" "$RUN_BASE/dockerd.log" "$(command -v dockerd)" --host "unix://$DOCKER_SOCK" --pidfile "$RUN_BASE/docker.pid" \
    --data-root "$LIB_BASE/docker" --exec-root "$RUN_BASE/exec" --containerd "$CTD_SOCK" --exec-opt native.cgroupdriver=cgroupfs \
    $FEATURE --bridge none --iptables=false --ip6tables=false --ip-forward=false
for _ in $(seq 1 120); do sudo docker -H "unix://$DOCKER_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo docker -H "unix://$DOCKER_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the lab's dockerd did not come up"; sudo tail -5 "$RUN_BASE/dockerd.log"; exit 1; }

echo "[setup] loading the private image into Docker (the only copy that is left: the archive is deleted below), and checking Docker's image id is its config digest..."
sudo docker -H "unix://$DOCKER_SOCK" load -i "$STATE_DIR/app.tar" >/dev/null
DID=$(sudo docker -H "unix://$DOCKER_SOCK" image inspect -f '{{.Id}}' "$IMG" 2>/dev/null || true)
[ "$DID" = "sha256:$CONFIG_HEX" ] || { echo "[setup] ERROR: Docker's image id ($DID) is not the config digest of the archive (sha256:$CONFIG_HEX): its image store is not the classic one"; exit 1; }
echo "  -> $IMG in Docker, id $DID"

echo "[setup] the network stub for the node (two CNI plugins that only answer: no bridge, no iptables, nothing on the host's network)..."
cat <<'CEOF' | sudo tee "$LIB_BASE/cni/bin/loopback" >/dev/null
#!/bin/bash
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"lo","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"127.0.0.1/8","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$LIB_BASE/cni/bin/benchnet" >/dev/null
#!/bin/bash
case "$CNI_COMMAND" in
    ADD) echo '{"cniVersion":"1.0.0","interfaces":[{"name":"'"$CNI_IFNAME"'","sandbox":"'"$CNI_NETNS"'"}],"ips":[{"address":"10.88.0.2/16","interface":0}]}' ;;
    VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0","1.1.0"]}' ;;
    *) ;;
esac
CEOF
sudo chmod 755 "$LIB_BASE/cni/bin/loopback" "$LIB_BASE/cni/bin/benchnet"
echo '{"cniVersion":"1.0.0","name":"benchnet","plugins":[{"type":"benchnet"}]}' | sudo tee "$LIB_BASE/cni/net.d/10-benchnet.conflist" >/dev/null

echo "[setup] which OCI runtime and monitor (conmon) the machine's CRI-O uses by default, from 'crio config'; the private CRI-O uses the same ones..."
CFG=$(sudo crio config 2>/dev/null)
# 'crio config' prints the built-in default as a comment ("# default_runtime = "crun""): an uncommented line (a drop-in) wins, else the commented one is the value in force
DEF=$(echo "$CFG" | awk -F'"' '/^[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
[ -n "$DEF" ] || DEF=$(echo "$CFG" | awk -F'"' '/^#[[:space:]]*default_runtime[[:space:]]*=/ {print $2; exit}')
DEF=${DEF:-runc}
tbl() { echo "$CFG" | awk -v t="[crio.runtime.runtimes.$DEF]" -v k="$1" '$0 == t {on=1; next} /^\[/ {on=0} on && $1 == k {gsub(/"/, "", $3); print $3; exit}'; }
BACKEND=$(tbl runtime_path); MONITOR=$(tbl monitor_path)
[ -x "$BACKEND" ] || BACKEND=$(command -v runc || true)
[ -x "$MONITOR" ] || MONITOR=$(command -v conmon || echo /usr/libexec/crio/conmon)
[ -x "$BACKEND" ] || { echo "[setup] ERROR: no OCI runtime found for CRI-O's default runtime '$DEF'"; exit 1; }
PINNS=$(echo "$CFG" | awk -F'"' '/^#?[[:space:]]*pinns_path[[:space:]]*=/ {print $2; exit}')
[ -x "$PINNS" ] || PINNS=$(command -v pinns || echo /usr/libexec/crio/pinns)
echo "  -> default runtime '$DEF': $BACKEND, conmon $MONITOR, pinns $PINNS"

echo "[setup] the sandbox image of the pods is copied into CRI-O's own storage ($CRIO_ROOT) with skopeo, before CRI-O starts..."
echo '{"default":[{"type":"insecureAcceptAnything"}]}' | sudo tee "$LIB_BASE/crio/policy.json" >/dev/null
sudo mkdir -p "$CRIO_ROOT" "$CRIO_RUNROOT"
sudo skopeo copy --quiet --policy "$LIB_BASE/crio/policy.json" "docker-archive:$STATE_DIR/pause.tar" "containers-storage:[overlay@$CRIO_ROOT+$CRIO_RUNROOT]$PAUSE_IMG"

echo "[setup] the private CRI-O: own socket $CRIO_SOCK, storage root $CRIO_ROOT, run root $CRIO_RUNROOT, CNI stub, no registries, no credentials, no NRI..."
sudo tee "$LIB_BASE/crio/crio.conf" >/dev/null <<EOF
[crio]
root = "$CRIO_ROOT"
runroot = "$CRIO_RUNROOT"
storage_driver = "overlay"
log_dir = "$LIB_BASE/crio/pods"
version_file = "$RUN_BASE/crio/version"
version_file_persist = ""
clean_shutdown_file = "$LIB_BASE/crio/clean.shutdown"

[crio.api]
listen = "$CRIO_SOCK"

[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
default_runtime = "bench"
container_exits_dir = "$RUN_BASE/crio/exits"
container_attach_socket_dir = "$RUN_BASE/crio"
namespaces_dir = "$RUN_BASE/crio/ns"
pinns_path = "$PINNS"

[crio.runtime.runtimes.bench]
runtime_path = "$BACKEND"
runtime_root = "$RUN_BASE/runtime"
monitor_path = "$MONITOR"

[crio.image]
pause_image = "$PAUSE_IMG"
pause_command = "/pause"
signature_policy = "$LIB_BASE/crio/policy.json"

[crio.network]
network_dir = "$LIB_BASE/cni/net.d"
plugin_dirs = ["$LIB_BASE/cni/bin"]

[crio.nri]
enable_nri = false
EOF
sudo chmod 644 "$LIB_BASE/crio/crio.conf" "$LIB_BASE/crio/policy.json"
start_daemon "$RUN_BASE/crio.pid" "$RUN_BASE/crio.log" env HOME=/root crio --config "$LIB_BASE/crio/crio.conf" --config-dir "" --log-level info
for _ in $(seq 1 60); do
    [ -S "$CRIO_SOCK" ] && $CRICTL version >/dev/null 2>&1 && break
    sleep 0.5
done
$CRICTL version >/dev/null 2>&1 || { echo "[setup] ERROR: the private CRI-O did not come up; last log lines:"; sudo tail -15 "$RUN_BASE/crio.log" | cut -c1-250; exit 1; }
$CRICTL inspecti "$PAUSE_IMG" >/dev/null 2>&1 || { echo "[setup] ERROR: CRI-O does not see the sandbox image"; exit 1; }
echo "  -> CRI-O $($CRICTL version 2>/dev/null | awk '/RuntimeVersion/ {print $2}') up on $CRIO_SOCK; its store holds only the sandbox image"

echo "[setup] the job's wrappers: docker (the Docker client of the lab's daemon) and node-crictl (crictl of the private CRI-O)..."
cat > "$WORK_DIR/bin/docker" <<EOF
#!/bin/sh
# docker ARGS...: the docker client against the lab's Docker daemon (socket $DOCKER_SOCK; it calls sudo itself)
exec sudo $(command -v docker) -H unix://$DOCKER_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the private CRI-O (socket $CRIO_SOCK; it calls sudo itself)
exec sudo crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/docker" "$WORK_DIR/bin/node-crictl"

echo "[setup] recording the state (root-only): the daemons (pid + start time + program), hashes of the configuration and wrappers, the image's identity..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" IMG="$IMG" PAUSE_IMG="$PAUSE_IMG" TOKEN="$TOKEN" CONFIG_HEX="$CONFIG_HEX" \
    CRIO_SOCK="$CRIO_SOCK" DOCKER_SOCK="$DOCKER_SOCK" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
files = [E["LIB_BASE"] + "/crio/crio.conf", E["LIB_BASE"] + "/crio/policy.json", E["LIB_BASE"] + "/etc/containerd.toml",
         E["WORK_DIR"] + "/bin/docker", E["WORK_DIR"] + "/bin/node-crictl"]
d = {"daemons": {n: ident(n) for n in ("containerd", "dockerd", "crio")}, "files": {f: sha(f) for f in files},
     "img": E["IMG"], "pause_img": E["PAUSE_IMG"], "token": E["TOKEN"], "config_hex": E["CONFIG_HEX"],
     "crio_sock": E["CRIO_SOCK"], "docker_sock": E["DOCKER_SOCK"]}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF

echo "[setup] removing the build inputs: no archive, program or generator is left, the image exists in Docker's store only..."
rm -f "$STATE_DIR"/app "$STATE_DIR"/app.c "$STATE_DIR"/pause "$STATE_DIR"/pause.c "$STATE_DIR"/*.tar "$STATE_DIR"/mksave.py
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. Docker holds $IMG; CRI-O (storage $CRIO_ROOT) does not, and the image cannot be pulled from anywhere."
