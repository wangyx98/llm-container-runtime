#!/bin/bash
set -e

CASE_ID="bench69636534"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and logs of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root and config (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"       # the node's containerd (CRI on, namespace k8s.io)
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record of the expectations
NS_A="$CASE_ID-team-a"                # two Kubernetes namespaces (names in the pods' CRI metadata; not containerd namespaces)
NS_B="$CASE_ID-team-b"
APP_REF="$CASE_ID.local/app:1"        # the image of every container
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pods

CTR_T="sudo ctr -a $T_SOCK"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)   CRICTL_ARCH="amd64" ;;
    aarch64|arm64)  CRICTL_ARCH="arm64" ;;
    *)              CRICTL_ARCH="amd64" ;;
esac

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test and the usual tools)..."
for b in containerd ctr runc python3; do
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

echo "[setup] making sure gcc is available (gcc: tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/logs" "$T_STATE" "$T_ROOT" "$(dirname "$T_CFG")"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the containers: a service (a heartbeat), 'once' (exits 0), 'fail' (exits 1), and the sandbox program..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    unsigned long beat = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "once") == 0) { puts("bench69636534 once"); return 0; }
    if (argc > 1 && strcmp(argv[1], "fail") == 0) { puts("bench69636534 fail"); return 1; }
    for (;;) {
        printf("bench69636534 beat=%lu pid=%d\n", beat++, (int)getpid());
        sleep(1);
    }
}
CEOF
cat > "$STATE_DIR/pause.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
for p in app pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] writing a generator for images in Docker format..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
"""mkimg.py OUT REF BINARY ENTRY [--base RAWLAYER] [DEST=SRC ...] : build a Docker-format image (a layer with BINARY as /ENTRY and the
files SRC as /DEST, on top of the layer RAWLAYER if given) into an OCI archive (for ctr images import). Prints the digests as JSON.
mkimg.py --layer OUT [DEST=SRC ...] : write a raw (uncompressed) layer tar with the files, to be used as --base (a layer shared by images)."""
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


def layer_tar(items):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in items:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 1700000000
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def gz(raw):
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as g:   # deterministic: the same layer always gives the same blob
        g.write(raw)
    return out.getvalue()                   # Docker layers are gzip: blob digest != diff id


if sys.argv[1] == "--layer":
    out = sys.argv[2]
    open(out, "wb").write(layer_tar([(d, open(s, "rb").read(), 0o644) for d, s in (a.split("=", 1) for a in sys.argv[3:])]))
    sys.exit(0)

out, ref, binary, entry = sys.argv[1:5]
rest = sys.argv[5:]
base = None
if rest[:1] == ["--base"]:
    base, rest = open(rest[1], "rb").read(), rest[2:]
extras = [a.split("=", 1) for a in rest]
own = layer_tar([(entry, open(binary, "rb").read(), 0o755)] + [(d, open(s, "rb").read(), 0o644) for d, s in extras])
layers = ([base] if base else []) + [own]
blobs = [gz(l) for l in layers]
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
    "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
               "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
    "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY layer %d # buildkit" % i} for i in range(len(layers))]
               + [{"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry, "empty_layer": True}],
    "rootfs": {"type": "layers", "diff_ids": [sha(l) for l in layers]}}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                       "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(b), "size": len(b)} for b in blobs]},
                      separators=(",", ":")).encode()
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
    for dg, data in [(sha(b), b) for b in blobs] + [(sha(config), config), (sha(manifest), manifest)]:
        add("blobs/sha256/" + dg.split(":")[1], data)
print(json.dumps({"manifest": sha(manifest), "config": sha(config), "layer": sha(blobs[-1]),
                  "base": sha(blobs[0]) if base else ""}))
PYEOF

echo "[setup] writing the containerd config: containerd's default config for the installed version (CRI plugin on), moved into its own"
echo "[setup] root, state and socket, NRI off, the pod sandbox image set to the local one..."
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
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    | sudo tee "$T_CFG" >/dev/null
grep -q "$PAUSE_REF" "$T_CFG" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
sudo sha256sum "$T_CFG" | awk '{print $1}' > "$STATE_DIR/config.sha"

echo "[setup] starting the node's containerd (a plain 'containerd --config <file>', its pid in a file)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$T_CFG" "$RUN_BASE/logs/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$T_SOCK" ] && $CTR_T version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR_T version >/dev/null 2>&1; then
    echo "[setup] ERROR: the node's containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/logs/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> the node's containerd up on $T_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
"${CRI[@]}" version >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI of the node's containerd does not answer"; exit 1; }
echo "  -> CRI answers"

echo "[setup] importing the two images into the 'k8s.io' namespace (the sandbox image and the image of all containers)..."
for pair in "pause:$PAUSE_REF" "app:$APP_REF"; do
    k=${pair%%:*}; ref=${pair#*:}
    python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/$k.tar" "$ref" "$STATE_DIR/$k-bin" "$k" >/dev/null
    chmod 0644 "$STATE_DIR/$k.tar"
    $CTR_T -n k8s.io images import "$STATE_DIR/$k.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import $ref"; exit 1; }
    rm -f "$STATE_DIR/$k.tar"
done
for ref in "$PAUSE_REF" "$APP_REF"; do
    SEEN=""
    for _ in $(seq 1 40); do
        if "${CRI[@]}" inspecti "$ref" >/dev/null 2>&1; then SEEN=1; break; fi
        sleep 0.5
    done
    [ -n "$SEEN" ] || { echo "[setup] ERROR: the CRI does not know $ref"; exit 1; }
done

echo "[setup] writing the helper that makes a pod the way a kubelet does (sandbox metadata name/namespace/uid/attempt, containers with name/attempt)..."
cat > "$STATE_DIR/mkpod.py" <<'PYEOF'
"""mkpod.py SOCK WORKDIR NAMESPACE NAME UID SANDBOX_ATTEMPT STOP CONTAINER:ATTEMPT:MODE... : make a pod the way a kubelet would, through the CRI of the containerd
at SOCK: a pod sandbox with the metadata (name, namespace, uid, attempt) and the usual kubelet labels, then the containers, each with its
metadata (name, attempt) and labels. MODE: run (a service: stays running), once (runs and exits 0), fail (runs and exits 1). STOP=1 stops the pod
at the end (the containers stop with it). Prints what was made as one JSON object."""
import json
import os
import subprocess
import sys
import time

sock, work, namespace, name, uid, sb_attempt, stop = sys.argv[1:8]
specs = [s.split(":") for s in sys.argv[8:]]
APP_REF = "bench69636534.local/app:1"
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER


def cri(*args):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "60s", *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


def state(cid):
    return cri("inspect", "-o", "go-template", "--template", "{{.status.state}}", cid)


pod_labels = {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": namespace, "io.kubernetes.pod.uid": uid}
pod_cfg = {"metadata": {"name": name, "namespace": namespace, "uid": uid, "attempt": int(sb_attempt)},
           "log_directory": os.path.join(work, "logs", uid),
           "labels": pod_labels, "annotations": {"kubernetes.io/config.source": "api"}, **NS}
os.makedirs(pod_cfg["log_directory"], exist_ok=True)
pod_file = os.path.join(work, uid + ".pod.json")
json.dump(pod_cfg, open(pod_file, "w"))
sandbox = cri("runp", pod_file)

containers = []
for cname, attempt, mode in specs:
    cfg = {"metadata": {"name": cname, "attempt": int(attempt)}, "image": {"image": APP_REF},
           "args": {"run": [], "once": ["once"], "fail": ["fail"]}[mode],
           "labels": {**pod_labels, "io.kubernetes.container.name": cname},
           "log_path": "%s_%s.log" % (cname, attempt), **NS}
    cfile = os.path.join(work, "%s.%s.%s.json" % (uid, cname, attempt))
    json.dump(cfg, open(cfile, "w"))
    cid = cri("create", sandbox, cfile, pod_file)
    cri("start", cid)
    want = "CONTAINER_RUNNING" if mode == "run" else "CONTAINER_EXITED"
    for _ in range(60):
        if state(cid) == want:
            break
        time.sleep(0.5)
    else:
        sys.stderr.write("container %s did not reach %s\n" % (cname, want))
        sys.exit(1)
    containers.append({"name": cname, "attempt": int(attempt), "id": cid, "mode": mode})
if stop == "1":
    cri("stopp", sandbox)
print(json.dumps({"uid": uid, "namespace": namespace, "name": name, "sandbox": sandbox, "ready": stop != "1", "containers": containers}))
PYEOF

echo "[setup] making the pods, with random UIDs: the same pod name 'web' in two namespaces, containers that were restarted (attempt 0 exited, attempt 1 running),"
echo "[setup] a finished container, a pod without any container, and a pod that has been stopped..."
uid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
mkp() { python3 "$STATE_DIR/mkpod.py" "$T_SOCK" "$WORK_DIR" "$@"; }
P1=$(mkp "$NS_A" web "$(uid)" 0 0 app:0:fail app:1:run sidecar:0:run)
P2=$(mkp "$NS_B" web "$(uid)" 1 0 app:0:run proxy:0:once)
P3=$(mkp "$NS_B" idle "$(uid)" 2 0)
P4=$(mkp "$NS_A" old-job "$(uid)" 0 1 batch:0:once)
printf '[%s,%s,%s,%s]\n' "$P1" "$P2" "$P3" "$P4" > "$STATE_DIR/pods.json"
python3 - "$STATE_DIR/pods.json" <<'PYEOF'
import json
import sys

for p in json.load(open(sys.argv[1])):
    print("  -> pod %s/%s uid %s (%s): %s" % (p["namespace"], p["name"], p["uid"], "ready" if p["ready"] else "stopped",
          ", ".join("%s#%d=%s" % (c["name"], c["attempt"], c["id"][:8]) for c in p["containers"]) or "no containers"))
PYEOF

echo "[setup] recording the daemon's identity and what the CRI holds (pods and containers with their ids, states and metadata)..."
P=$(sudo cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/t.id"
cri_snapshot() {
    {
        "${CRI[@]}" pods -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    m = p["metadata"]
    print("pod", p["id"], p["state"], m["namespace"], m["name"], m["uid"], m["attempt"])'
        "${CRI[@]}" ps -a -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["containers"]:
    m = c["metadata"]
    print("container", c["id"], c["state"], c["podSandboxId"], m["name"], m["attempt"])'
    } | LC_ALL=C sort
}
cri_snapshot > "$STATE_DIR/cri.snapshot"
echo "  -> $(grep -c '^pod ' "$STATE_DIR/cri.snapshot") pod sandboxes, $(grep -c '^container ' "$STATE_DIR/cri.snapshot") containers"

echo "[setup] removing the build inputs the solution has no business with (the programs, the config tool, the image generator)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/pause-bin" "$STATE_DIR"/*.c "$STATE_DIR/patch_config.py" "$STATE_DIR/mkimg.py"

echo "[setup] done. The node's containerd ($T_SOCK) runs four pods: web in $NS_A and web in $NS_B (the same name), idle (no container) and old-job (stopped)."
