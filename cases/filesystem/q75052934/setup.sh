#!/bin/bash
set -e

CASE_ID="bench75052934"
RUN_BASE="/run/$CASE_ID"              # containerd's state, socket, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # containerd root, control script, the tool directory (not in /run: it is mounted noexec on many hosts)
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
TOOLS_DIR="$LIB_BASE/tools"           # B: the host directory with the diagnostic tools that must reach the running container
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
VOL_DIR="$WORK_DIR/volume"            # the container's own volume (mounted at /vol when the container is created)
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"               # container A
APP_REF="$CASE_ID.local/app:1"
PAUSE_REF="$CASE_ID.local/pause:1"    # sandbox ("pause") image of the pod, built here

CTR="sudo ctr -a $CTD_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc, python3 and nsenter are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3 nsenter; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates; }
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] making sure gcc is available (gcc: three tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$VOL_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd" "$CTL_DIR" "$TOOLS_DIR/bin"
cd "$WORK_DIR"

echo "[setup] compiling the programs, each with its own per-run random token: the application of container A (once a second it"
echo "[setup] prints its pid, how many processes its /proc shows and what it reads from /vol and /tools), the diagnostic tool"
echo "[setup] that lives in the tool directory, and the sandbox program (only waits)..."
rnd() { python3 -c 'import secrets; print(secrets.token_hex(8))'; }
TOK_VOL="vol-$(rnd)"; TOK_TOOLS="tools-$(rnd)"; TOK_DIAG="diag-$(rnd)"
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* first line of a file, or "missing" */
static void first_line(const char *path, char *out, size_t n) {
    FILE *f = fopen(path, "r");
    if (!f || !fgets(out, (int)n, f)) {
        strcpy(out, "missing");
    } else {
        out[strcspn(out, "\r\n")] = 0;
    }
    if (f) fclose(f);
}

int main(void) {
    char vol[128], tools[128], live[128];
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        int nproc = 0;
        DIR *d = opendir("/proc");
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)))
                if (isdigit((unsigned char)e->d_name[0])) nproc++;
            closedir(d);
        }
        first_line("/vol/vol-token", vol, sizeof vol);
        first_line("/tools/probe", tools, sizeof tools);
        first_line("/tools/live", live, sizeof live);
        printf("bench75052934 pid=%d nproc=%d vol=%s tools=%s live=%s\n", (int)getpid(), nproc, vol, tools, live);
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/diag.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench75052934-diag-ok token=" TOKEN);
    return 0;
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
gcc -static -Os -s -w -DTOKEN="\"$TOK_DIAG\"" -o "$STATE_DIR/diag-bin" "$STATE_DIR/diag.c"
gcc -static -Os -s -w -o "$STATE_DIR/pause-bin" "$STATE_DIR/pause.c"

echo "[setup] filling the tool directory $TOOLS_DIR (a plain directory of the host: a probe file and the diagnostic tool) and the"
echo "[setup] volume directory of container A..."
sudo install -m 0755 "$STATE_DIR/diag-bin" "$TOOLS_DIR/bin/diag"
printf '%s\n' "$TOK_TOOLS" | sudo tee "$TOOLS_DIR/probe" >/dev/null
sudo chmod 755 "$TOOLS_DIR" "$TOOLS_DIR/bin"; sudo chmod 644 "$TOOLS_DIR/probe"
echo "[setup] making the tool directory a shared mount of the host (a bind of itself, shared): a clone of it keeps that propagation on"
echo "[setup] every host, whatever the host's root mount does (on a systemd host / is shared, on a minimal one it is private)..."
sudo mount --bind "$TOOLS_DIR" "$TOOLS_DIR"
sudo mount --make-shared "$TOOLS_DIR"
printf '%s\n' "$TOK_VOL" > "$VOL_DIR/vol-token"
printf '%s\n' "$TOK_TOOLS" > "$STATE_DIR/tok_tools"
printf '%s\n' "$TOK_VOL" > "$STATE_DIR/tok_vol"
printf '%s\n' "$TOK_DIAG" > "$STATE_DIR/tok_diag"

echo "[setup] writing a generator for images in Docker format (config blob + one gzip layer holding the program)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY : build a Docker-format image (one layer with BINARY as /ENTRY) into an OCI archive
(for ctr images import). Prints the digests as JSON."""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        data = open(binary, "rb").read()
        ti = tarfile.TarInfo(entry)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        t.addfile(ti, io.BytesIO(data))
    layer = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(layer)
    layer_gz = gz.getvalue()               # Docker layers are gzip: blob digest != diff id
    config = json.dumps({
        "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
        "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                   "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
        "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
        "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s / # buildkit" % entry},
                    {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry,
                     "empty_layer": True}],
        "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                           "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                          separators=(",", ":")).encode()
    return layer_gz, config, manifest


def truth(layer_gz, config, manifest):
    return json.dumps({"manifest": sha(manifest), "manifest_size": len(manifest), "config": sha(config),
                       "layer": sha(layer_gz), "layer_size": len(layer_gz), "media_type": DOCKER_MANIFEST})


out, ref, binary, entry = sys.argv[1:5]
layer_gz, config, manifest = build(binary, entry)
index = json.dumps({"schemaVersion": 2, "manifests": [{
    "mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
    "annotations": {"io.containerd.image.name": ref,
                    "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", index)
    for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], data)
print(truth(layer_gz, config, manifest))
PYEOF

echo "[setup] starting this node's containerd: its own socket, root and state, containerd's default config for the installed"
echo "[setup] version (CRI plugin on) moved into that root/state, NRI off, the pod sandbox image set to the local one..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
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
    elif section.endswith(".cni") and k == "bin_dirs":
        line = f"{indent}bin_dirs = ['{cni}/bin']\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(''|\"\")\s*$", line):
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif "pinned_images" in section and k == "sandbox":
        line = f"{indent}sandbox = '{pause}'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
grep -q "$PAUSE_REF" "$RUN_BASE/config.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
cat <<CEOF | sudo tee "$CTL_DIR/containerdctl" >/dev/null
#!/bin/bash
# how this node's containerd is started and stopped: containerdctl start|stop|restart|status
PIDF="$RUN_BASE/containerd.pid"
alive() { [ -s "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }
do_start() {
    if alive; then echo "containerd is already running"; return 0; fi
    setsid -f bash -c 'echo \$\$ > "\$1"; exec containerd --config "\$2" >"\$3" 2>&1 </dev/null' _ "\$PIDF" "$RUN_BASE/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
    echo "containerd started"
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    kill -TERM "\$(cat "\$PIDF")"
    for _ in \$(seq 1 40); do alive || break; sleep 0.5; done
    alive && kill -KILL "\$(cat "\$PIDF")"
    echo "containerd stopped"
}
case "\$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid \$(cat "\$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CEOF
sudo chmod 755 "$CTL_DIR/containerdctl"
sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}' > "$STATE_DIR/containerdctl.sha"
sudo "$CTL_DIR/containerdctl" start >/dev/null
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of containerd does not answer"; exit 1; }
echo "  -> CRI answers"

echo "[setup] importing the images into the 'k8s.io' namespace, where the CRI looks for images, and giving two of them"
imp() {   # $1 = key (file stem), $2 = ref, $3 = entry name
    local ID
    ID=$(python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$1.tar" "$2" "$STATE_DIR/$1-bin" "$3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"])')
    chmod 0644 "$STATE_DIR/$1.tar"
    $CTR -n k8s.io images import "$STATE_DIR/$1.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $2"; exit 1; }
    rm -f "$STATE_DIR/$1.tar"
    echo "${ID#sha256:}" > "$STATE_DIR/image_id_$1"
    echo "  -> $2  id $ID"
}
echo "[setup] importing the two images into the 'k8s.io' namespace, where the CRI looks for images..."
imp pause "$PAUSE_REF" pause
imp app "$APP_REF" app
for k in pause app; do
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "sha256:$(cat "$STATE_DIR/image_id_$k")" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know the $k image"; exit 1; }
done

echo "[setup] writing the pod and container configs: host network (no CNI plugin needed), the container gets its OWN pid namespace"
echo "[setup] (it is pid 1 there) and its own mount namespace, the volume $VOL_DIR is mounted at /vol with the default (private)"
echo "[setup] mount propagation..."
python3 - "$WORK_DIR" "$POD_NAME" "$VOL_DIR" "$APP_NAME" "$APP_REF" <<'PYEOF'
import json
import sys

work, pod, vol, app, app_ref = sys.argv[1:6]
with open(work + "/pod.json", "w") as f:
    json.dump({
        "metadata": {"name": pod, "namespace": "default", "attempt": 1, "uid": "bench75052934-uid"},
        "log_directory": work + "/logs",
        "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}},   # network: NODE; pid: CONTAINER
    }, f)
with open(work + "/" + app + ".json", "w") as f:
    json.dump({"metadata": {"name": app}, "image": {"image": app_ref}, "log_path": app + ".log",
               "mounts": [{"container_path": "/vol", "host_path": vol, "readonly": False}],
               "linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}, f)
PYEOF

echo "[setup] starting the pod sandbox and container A ($APP_REF)..."
POD_ID=$("${CRI[@]}" runp "$WORK_DIR/pod.json" 2>/dev/null) || { echo "[setup] ERROR: crictl runp failed"; exit 1; }
APP_ID=$("${CRI[@]}" create "$POD_ID" "$WORK_DIR/$APP_NAME.json" "$WORK_DIR/pod.json" 2>"$STATE_DIR/create_err.txt") || { cat "$STATE_DIR/create_err.txt"; echo "[setup] ERROR: crictl create failed"; exit 1; }
"${CRI[@]}" start "$APP_ID" >/dev/null 2>"$STATE_DIR/start_err.txt" || { cat "$STATE_DIR/start_err.txt"; echo "[setup] ERROR: crictl start failed"; exit 1; }
echo "$POD_ID" > "$STATE_DIR/pod_id"
echo "$APP_ID" > "$STATE_DIR/container_app"
echo "  -> pod $POD_ID"
echo "  -> container $APP_ID ($APP_NAME)"

echo "[setup] waiting until the application reports itself in the container log..."
READY=""
for _ in $(seq 1 40); do
    if "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | grep -q "^bench75052934 pid="; then READY=1; break; fi
    sleep 0.5
done
[ -n "$READY" ] || { echo "[setup] ERROR: the application never logged"; exit 1; }

echo "[setup] recording the identity of container A (host pid, start time, mount and pid namespace inodes), the propagation of the"
echo "[setup] host's root mount, and the daemon's identity, so the checks can tell nothing was replaced..."
PID=$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "$PID" > "$STATE_DIR/pid"
sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}' > "$STATE_DIR/starttime"
sudo readlink "/proc/$PID/ns/mnt" > "$STATE_DIR/ns_mnt"
sudo readlink "/proc/$PID/ns/pid" > "$STATE_DIR/ns_pid"
readlink /proc/self/ns/mnt > "$STATE_DIR/ns_mnt_host"
readlink /proc/self/ns/pid > "$STATE_DIR/ns_pid_host"
awk '$5 == "/" {n = index($0, " - "); split(substr($0, 1, n), f, " "); s = ""; for (i = 7; i <= length(f); i++) s = s f[i] " "; print s; exit}' /proc/self/mountinfo > "$STATE_DIR/host_root_opts"
P=$(cat "$RUN_BASE/containerd.pid"); echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "  -> host pid $PID, mount ns $(cat "$STATE_DIR/ns_mnt"), pid ns $(cat "$STATE_DIR/ns_pid")"

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR"/*-bin "$STATE_DIR"/*.c "$STATE_DIR/mkimg.py" "$STATE_DIR/patch_config.py"

echo "[setup] done. Container A ($APP_NAME in pod $POD_NAME) runs with its own pid and mount namespaces and the volume at /vol;"
echo "[setup] the tool directory $TOOLS_DIR exists only on the host."
