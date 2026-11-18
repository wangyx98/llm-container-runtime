#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench74685092"
RUN_BASE="/run/$CASE_ID"              # sockets, runtime state, pid files of the three daemons
LIB_BASE="/var/lib/$CASE_ID"          # image stores and snapshots of the three daemons
CACHE="/var/cache/$CASE_ID"           # the pinned crictl (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # root-only record of what is true
SOCK_K="$RUN_BASE/k3s/containerd.sock"        # master: the containerd of k3s, the one the CRI (kubelet, crictl) uses
SOCK_S="$RUN_BASE/system/containerd.sock"     # master: the host's own containerd, the one a plain ctr reaches
SOCK_W="$RUN_BASE/worker/containerd.sock"     # worker: one containerd for ctr and crictl alike
CRICTL_VERSION="v1.34.0"
APP_TAG="$CASE_ID-app:latest"
PAUSE_TAG="$CASE_ID-pause:latest"
PAUSE_REF="docker.io/library/$PAUSE_TAG"
POD_NAME="$CASE_ID-pod"
CONTAINER_NAME="$CASE_ID"

case "$(uname -m)" in
    x86_64|amd64)  IMG_ARCH="amd64"; CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51" ;;
    aarch64|arm64) IMG_ARCH="arm64"; CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f" ;;
    *) echo "[setup] NOT APPLICABLE: no pinned crictl for $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking containerd, runc and ctr are installed (the runtime under test)..."
for c in containerd ctr runc python3 curl sudo; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
CTRBIN=$(command -v ctr)
containerd --version

echo "[setup] ensuring gcc exists (two tiny static programs go into the images; no registry is needed)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] the pinned crictl $CRICTL_VERSION ($IMG_ARCH): from $CACHE, else downloaded (sha256 checked); it is kept out of /usr/local/bin and /etc/crictl.yaml stays as it is..."
sudo install -d -m 0755 "$CACHE"
if ! { [ -f "$CACHE/crictl.tar.gz" ] && echo "$CRICTL_SHA  $CACHE/crictl.tar.gz" | sha256sum -c --quiet - 2>/dev/null; }; then
    TMPD=$(mktemp -d)
    curl -fsSL --retry 3 --max-time 300 -o "$TMPD/crictl.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$IMG_ARCH.tar.gz" || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    echo "$CRICTL_SHA  $TMPD/crictl.tar.gz" | sha256sum -c --quiet - || { echo "[setup] ERROR: crictl does not match its sha256"; exit 1; }
    sudo install -m 0644 "$TMPD/crictl.tar.gz" "$CACHE/crictl.tar.gz"
    rm -rf "$TMPD"
fi
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/bin"
sudo tar -xzf "$CACHE/crictl.tar.gz" -C "$LIB_BASE/bin" crictl
CRICTLBIN="$LIB_BASE/bin/crictl"
"$CRICTLBIN" --version

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/logs" "$WORK_DIR/master" "$WORK_DIR/worker"
sudo install -d -m 0700 "$STATE_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the shims of the private daemons keep their runc state and shim sockets in the HOST's /run/containerd (runc's default root); recording what is there now so cleanup removes only what this case adds..."
if [ -d /run/containerd ]; then
    sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort | sudo tee "$STATE_DIR/hostrun.base" >/dev/null
else
    echo "NOEXIST" | sudo tee "$STATE_DIR/hostrun.base" >/dev/null
fi
sudo cp "$STATE_DIR/hostrun.base" "$LIB_BASE/hostrun.base"

crictl_at() { local s=$1; shift; sudo "$CRICTLBIN" --runtime-endpoint "unix://$s" --image-endpoint "unix://$s" --config /dev/null --timeout 30s "$@"; }

echo "[setup] compiling the application (prints a line with a per-run token once a second; the token exists only in this image) and a minimal pause program for the pod sandboxes..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat > "$BUILD/app.c" <<'CEOF'
#include <stdio.h>
#include <time.h>
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        puts("bench74685092-image-ok token=" TOKEN);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
cat > "$BUILD/pause.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>
static void bye(int sig) { (void)sig; _exit(0); }
int main(void) { signal(SIGINT, bye); signal(SIGTERM, bye); for (;;) pause(); }
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$BUILD/bench-app" "$BUILD/app.c"
gcc -static -Os -s -o "$BUILD/bench-pause" "$BUILD/pause.c"

echo "[setup] writing both images the way 'docker save' lays them out (manifest.json + config blob + one layer); the image's architecture is this host's, so 'ctr import --platform linux/$IMG_ARCH' is the right flag here..."
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, binary, name, tag, arch = sys.argv[1:6]
layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid = len(data), 0o755, 0, 0, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()
config = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
                     "config": {"Entrypoint": ["/" + name], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
                     "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "bench74685092"}]},
                    sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": [tag], "Layers": [diff_id + "/layer.tar"]}]).encode()


def add(t, fname, payload):
    ti = tarfile.TarInfo(fname)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)
print(image_id)    # an image's ID, as the CRI reports it, is the sha256 of its config blob
PYEOF
IMAGE_ID=$(python3 "$BUILD/mkimage.py" "$WORK_DIR/app.tar" "$BUILD/bench-app" bench-app "$APP_TAG" "$IMG_ARCH")
python3 "$BUILD/mkimage.py" "$BUILD/pause.tar" "$BUILD/bench-pause" bench-pause "$PAUSE_TAG" "$IMG_ARCH" >/dev/null
chmod 0644 "$WORK_DIR/app.tar"
echo "  -> application image id sha256:$IMAGE_ID (the tar: $WORK_DIR/app.tar)"

echo "[setup] a config generator: each daemon gets containerd's default config for the installed version in a private root/state/socket, the sandbox image on the local pause image, NRI off, restrict_oom_score_adj on..."
cat > "$BUILD/patch_config.py" <<'PYEOF'
import re, sys

lib, run, sock, pause_ref = sys.argv[1:5]
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
    elif (section == "grpc" or section.endswith("server.v1.grpc")) and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif (section == "ttrpc" or section.endswith("server.v1.ttrpc")) and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif k in ("sandbox", "sandbox_image"):
        line = f"{indent}{k} = '{pause_ref}'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF

start_daemon() {   # $1 = k3s | system | worker
    local n=$1 run="$RUN_BASE/$1" lib="$LIB_BASE/$1"
    sudo mkdir -p "$run" "$lib"
    containerd config default | python3 "$BUILD/patch_config.py" "$lib" "$run" "$run/containerd.sock" "$PAUSE_REF" | sudo tee "$run/config.toml" >/dev/null
    # never start a daemon whose config still has the host's default socket (it would take over /run/containerd/containerd.sock)
    [ "$(sudo grep -c "$run/containerd.sock" "$run/config.toml")" -ge 1 ] || { echo "[setup] ERROR: the patched config of '$n' has no private socket address"; return 1; }
    sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$run" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 40); do
        [ -S "$run/containerd.sock" ] && crictl_at "$run/containerd.sock" info >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    echo "[setup] ERROR: containerd '$n' did not come up; last log lines:"
    sudo tail -20 "$run/containerd.log" 2>/dev/null || true
    return 1
}
echo "[setup] starting the three daemons: the containerd of k3s and the host's own containerd (the master node), and the worker's containerd..."
start_daemon k3s; start_daemon system; start_daemon worker
echo "  -> k3s: $SOCK_K"; echo "  -> system: $SOCK_S"; echo "  -> worker: $SOCK_W"
for s in "$SOCK_K" "$SOCK_S" "$SOCK_W"; do sudo "$CTRBIN" -a "$s" -n k8s.io images import "$BUILD/pause.tar" >/dev/null; done

echo "[setup] the node's tools: on the master 'ctr' reaches the system containerd, 'crictl' the one of k3s; on the worker both reach the worker's containerd..."
mkwrap() {   # $1 = file, $2... = the command to exec
    local f=$1; shift
    printf '#!/bin/sh\nexec %s "$@"\n' "$*" > "$f"
    chmod 0755 "$f"
}
mkwrap "$WORK_DIR/master/ctr" "$CTRBIN -a $SOCK_S"
mkwrap "$WORK_DIR/master/crictl" "$CRICTLBIN --runtime-endpoint unix://$SOCK_K --image-endpoint unix://$SOCK_K --config /dev/null --timeout 30s"
mkwrap "$WORK_DIR/worker/ctr" "$CTRBIN -a $SOCK_W"
mkwrap "$WORK_DIR/worker/crictl" "$CRICTLBIN --runtime-endpoint unix://$SOCK_W --image-endpoint unix://$SOCK_W --config /dev/null --timeout 30s"

echo "[setup] the worker, the good node: the very command of the question ('ctr -n k8s.io images import app.tar --platform linux/$IMG_ARCH') and a container running in a pod..."
sudo "$WORK_DIR/worker/ctr" -n k8s.io images import "$WORK_DIR/app.tar" --platform "linux/$IMG_ARCH" >/dev/null
sudo "$WORK_DIR/worker/crictl" images | grep -F "$CASE_ID-app" | sed 's/^/  -> worker crictl: /'
cat > "$BUILD/worker-pod.json" <<PEOF
{"metadata": {"name": "$CASE_ID-worker-pod", "namespace": "default", "attempt": 1, "uid": "bench74685092uid00000002"},
 "log_directory": "$WORK_DIR/logs", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
PEOF
cat > "$BUILD/worker-container.json" <<CEOF2
{"metadata": {"name": "$CASE_ID-w"}, "image": {"image": "$APP_TAG"}, "log_path": "$CASE_ID-w.0.log", "linux": {}}
CEOF2
sudo install -m 0600 "$BUILD/worker-pod.json" "$BUILD/worker-container.json" "$STATE_DIR/"
WPOD=$(crictl_at "$SOCK_W" runp "$STATE_DIR/worker-pod.json")
WCTR=$(crictl_at "$SOCK_W" create "$WPOD" "$STATE_DIR/worker-container.json" "$STATE_DIR/worker-pod.json")
crictl_at "$SOCK_W" start "$WCTR" >/dev/null
for _ in $(seq 1 20); do crictl_at "$SOCK_W" logs "$WCTR" 2>/dev/null | grep -qF "token=$TOKEN" && break; sleep 0.5; done
crictl_at "$SOCK_W" logs "$WCTR" 2>/dev/null | grep -qF "token=$TOKEN" || { echo "[setup] ERROR: the worker's container does not run the image"; exit 1; }
echo "  -> worker: container $WCTR runs the image in pod $WPOD"

echo "[setup] the master: what the asker did, with the same command, through the master's ctr (that is the host's own containerd)..."
sudo "$WORK_DIR/master/ctr" -n k8s.io images import "$WORK_DIR/app.tar" --platform "linux/$IMG_ARCH" >/dev/null
sudo "$WORK_DIR/master/ctr" -n k8s.io images ls -q | grep -F "$CASE_ID-app" | sed 's/^/  -> master ctr: /'
sudo "$WORK_DIR/master/crictl" images | sed 's/^/  -> master crictl: /'

echo "[setup] the pod 'scheduled' to the master: its sandbox on the containerd of k3s, and a container config that names the image plainly (the CRI does not pull when it creates a container in an existing sandbox)..."
cat > "$WORK_DIR/pod-config.json" <<PEOF
{
  "metadata": {"name": "$POD_NAME", "namespace": "default", "attempt": 1, "uid": "bench74685092uid00000001"},
  "log_directory": "$WORK_DIR/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
PEOF
cat > "$WORK_DIR/container-config.json" <<CEOF2
{
  "metadata": {"name": "$CONTAINER_NAME"},
  "image": {"image": "$APP_TAG"},
  "log_path": "$CONTAINER_NAME.0.log",
  "linux": {}
}
CEOF2
POD_ID=$(crictl_at "$SOCK_K" runp "$WORK_DIR/pod-config.json")
echo "  -> pod sandbox $POD_ID"
if crictl_at "$SOCK_K" create "$POD_ID" "$WORK_DIR/container-config.json" "$WORK_DIR/pod-config.json" > "$BUILD/first_attempt.out" 2>&1; then
    echo "[setup] FAIL: the container was created; the scenario is not broken"
    exit 1
fi
sed 's/^/  -> /' "$BUILD/first_attempt.out" | tail -3

echo "[setup] recording the state (root-only): the image id, the token, the pods, the containers, each daemon's process and config hash, the wrappers and the tar..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" RUN_BASE="$RUN_BASE" LIB_BASE="$LIB_BASE" IMAGE_ID="$IMAGE_ID" TOKEN="$TOKEN" POD_ID="$POD_ID" WPOD="$WPOD" WCTR="$WCTR" python3 - <<'PYEOF'
import hashlib, json, os

E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()


def starttime(pid):
    s = open("/proc/%s/stat" % pid).read()
    return int(s[s.rindex(")") + 2:].split()[19])


d = {"image_id": E["IMAGE_ID"], "token": E["TOKEN"], "pod_id": E["POD_ID"], "worker_pod_id": E["WPOD"], "worker_container_id": E["WCTR"],
     "tar_sha": sha(E["WORK_DIR"] + "/app.tar"), "daemons": {}, "wrappers": {}}
for n in ("k3s", "system", "worker"):
    run = "%s/%s" % (E["RUN_BASE"], n)
    pid = int(open(run + "/containerd.pid").read())
    d["daemons"][n] = {"pid": pid, "start": starttime(pid), "config_sha": sha(run + "/config.toml")}
for w in ("master/ctr", "master/crictl", "worker/ctr", "worker/crictl"):
    d["wrappers"][w] = sha(E["WORK_DIR"] + "/" + w)
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The master's ctr shows the image, the master's crictl does not; the worker has it in both and runs it; the master's pod sandbox waits for its container."
