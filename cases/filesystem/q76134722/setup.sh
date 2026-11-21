#!/bin/bash
set -e

CASE_ID="bench76134722"
RUN_BASE="/run/$CASE_ID"              # the node's containerd: socket, state, pid file, log
LIB_BASE="/var/lib/$CASE_ID"          # containerd's configuration and root, the keep list, the workload's files
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
KEEP_LIST="$LIB_BASE/keep-images.txt"
WL="$LIB_BASE/workload"               # the pod and container definitions of the running workload
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

REG="registry.bench.local"
MIR="mirror.bench.local"
PAUSE="$REG/infra/pause:dev-3.9"      # the sandbox image of the node (pinned)
WEB_USED="$REG/shop/web:dev-100"      # the image of a running container
API_USED="$REG/shop/api:dev-100"      # the image of a running container

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"

echo "[setup] checking the stack under test is installed: containerd, ctr and crictl (the node's runtime and its clients)..."
echo "[setup] The case runs a private containerd (own socket, root and state, the CRI on): the machine's own containerd, docker and images are not touched."
for b in containerd ctr crictl python3 sudo; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure a static busybox (the images' programs) is installed..."
command -v busybox >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" busybox-static; }
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/logs" "$LIB_BASE/etc" "$WL"
sudo chmod 755 "$LIB_BASE" "$LIB_BASE/etc" "$WL"
cd "$WORK_DIR"

echo "[setup] building the images offline (OCI layout, Docker media types): every image = the shared busybox layer + a layer of its own (256 KiB of random bytes, so that every image has blobs of its own)..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import gzip, hashlib, io, json, os, subprocess, sys, tarfile
arch, bb, spec_file, out, built = sys.argv[1:6]
DM, DC, DL = ("application/vnd.docker.distribution.manifest.v2+json", "application/vnd.docker.container.image.v1+json", "application/vnd.docker.image.rootfs.diff.tar.gzip")
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
def info(n, size, mode, kind=tarfile.REGTYPE, link=""):
    t = tarfile.TarInfo(n); t.size = size; t.mode = mode; t.mtime = 1700000000; t.type = kind; t.linkname = link; return t
def gz(b):
    g = io.BytesIO()
    with gzip.GzipFile(fileobj=g, mode="wb", mtime=0) as f: f.write(b)
    return g.getvalue()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d, m in (("bin", 0o755), ("tmp", 0o1777)):
        t.addfile(info(d, 0, m, tarfile.DIRTYPE))
    data = open(bb, "rb").read()
    t.addfile(info("bin/busybox", len(data), 0o755), io.BytesIO(data))
    for a in subprocess.run([bb, "--list"], capture_output=True, text=True).stdout.split():
        if a != "busybox": t.addfile(info("bin/" + a, 0, 0o755, tarfile.SYMTYPE, "busybox"))
base = buf.getvalue(); base_gz = gz(base)
blobs = {sha(base_gz)[7:]: base_gz}
entries, report = [], []
for img in json.load(open(spec_file)):
    names = img["names"]
    ub = io.BytesIO()
    with tarfile.open(fileobj=ub, mode="w", format=tarfile.PAX_FORMAT) as t:
        t.addfile(info("image-name", len(names[0]), 0o644), io.BytesIO(names[0].encode()))
        r = os.urandom(262144); t.addfile(info("blob.bin", len(r), 0o644), io.BytesIO(r))
    layer = ub.getvalue(); layer_gz = gz(layer)
    config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                         "config": {"Env": ["PATH=/usr/local/bin:/usr/bin:/bin"], "Entrypoint": ["/bin/busybox", "sleep", "2000000000"], "Cmd": []},
                         "rootfs": {"type": "layers", "diff_ids": [sha(base), sha(layer)]}, "history": [{"created_by": "bench76134722 " + names[0]}]}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DM, "config": {"mediaType": DC, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DL, "digest": sha(base_gz), "size": len(base_gz)}, {"mediaType": DL, "digest": sha(layer_gz), "size": len(layer_gz)}]}, separators=(",", ":")).encode()
    for b in (layer_gz, config, manifest): blobs[sha(b)[7:]] = b
    for n in names:
        entries.append({"mediaType": DM, "digest": sha(manifest), "size": len(manifest), "annotations": {"io.containerd.image.name": n, "org.opencontainers.image.ref.name": n.rsplit(":", 1)[1]}})
    report.append({"names": names, "id": sha(config), "manifest": sha(manifest), "own_blobs": [sha(layer_gz), sha(config), sha(manifest)]})
with tarfile.open(out, "w") as t:
    for name, data in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", json.dumps({"schemaVersion": 2, "manifests": entries}).encode())):
        t.addfile(info(name, len(data), 0o644), io.BytesIO(data))
    for d, data in blobs.items(): t.addfile(info("blobs/sha256/" + d, len(data), 0o644), io.BytesIO(data))
json.dump({"base": sha(base_gz), "images": report}, open(built, "w"))
PYEOF
cat > "$STATE_DIR/spec.json" <<EOF
[{"names": ["$WEB_USED"]}, {"names": ["$API_USED"]}, {"names": ["$PAUSE"]},
 {"names": ["$REG/shop/web:dev-101"]}, {"names": ["$REG/shop/web:dev-102"]}, {"names": ["$REG/shop/api:dev-101"]}, {"names": ["$REG/shop/api:dev-102"]},
 {"names": ["$MIR/team/worker:dev-7"]},
 {"names": ["$REG/shop/web:dev-103", "$REG/shop/web:stable-103"]},
 {"names": ["$REG/shop/web:dev-keep"]}, {"names": ["$MIR/team/worker:dev-keep"]},
 {"names": ["$REG/tools/curl:1.0"]}, {"names": ["$REG/dev-tools/lint:2.1"]}, {"names": ["$REG/seed/offline:1"]}]
EOF
echo "[{\"names\": [\"$REG/shop/web:dev-201\"]}]" > "$STATE_DIR/spec-other.json"
python3 "$STATE_DIR/mkimg.py" "$ARCH" "$BB" "$STATE_DIR/spec.json" "$STATE_DIR/node.tar" "$STATE_DIR/built.json"
python3 "$STATE_DIR/mkimg.py" "$ARCH" "$BB" "$STATE_DIR/spec-other.json" "$STATE_DIR/other.tar" "$STATE_DIR/built-other.json"

echo "[setup] the keep list (images that stay on the node although they are idle and carry the dev- tag)..."
sudo tee "$KEEP_LIST" >/dev/null <<EOF
# images that stay on the node
$REG/shop/web:dev-keep
$MIR/team/worker:dev-keep
EOF
sudo chmod 644 "$KEEP_LIST"

echo "[setup] the node's containerd: own configuration $CTD_CONF (a version-3 file), own socket $CTD_SOCK, own root; the CRI plugin on; the sandbox image $PAUSE is pinned; no NRI; no CNI (the pods use the node's network)..."
sudo tee "$CTD_CONF" >/dev/null <<EOF
version = 3
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/state"
[grpc]
  address = "$CTD_SOCK"
[ttrpc]
  address = "$CTD_SOCK.ttrpc"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
[plugins."io.containerd.cri.v1.runtime"]
  restrict_oom_score_adj = true
[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "$PAUSE"
EOF
sudo chmod 644 "$CTD_CONF"

echo "[setup] the pod and the two containers of the workload (definitions in $WL)..."
sudo tee "$WL/pod.json" >/dev/null <<EOF
{"metadata": {"name": "shop", "namespace": "bench", "uid": "bench76134722-shop", "attempt": 0}, "log_directory": "$RUN_BASE/logs",
 "linux": {"security_context": {"namespace_options": {"network": 2}}}}
EOF
for c in web api; do
    img="$REG/shop/$c:dev-100"
    sudo tee "$WL/$c.json" >/dev/null <<EOF
{"metadata": {"name": "$c"}, "image": {"image": "$img"}, "command": ["/bin/sh", "-c", "while :; do sleep 1; done"], "log_path": "$c.log", "linux": {}}
EOF
done
sudo chmod 644 "$WL"/*.json

echo "[setup] node-ctr and node-crictl: ctr and crictl against the node's containerd (both call sudo themselves)..."
cat > "$WORK_DIR/bin/node-ctr" <<EOF
#!/bin/sh
# node-ctr ARGS...: ctr against the node's containerd (socket $CTD_SOCK; it calls sudo itself). The images of the CRI are in the namespace k8s.io: node-ctr -n k8s.io images ls
exec sudo $(command -v ctr) -a $CTD_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd (socket $CTD_SOCK; it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/node-ctr" "$WORK_DIR/bin/node-crictl"

echo "[setup] starting the node's containerd, importing the images into the namespace k8s.io (the CRI's) and one image into the namespace bench-other..."
sudo touch "$RUN_BASE/containerd.log"
sudo setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" >> "$4" 2>&1 </dev/null' _ "$RUN_BASE/containerd.pid" "$(command -v containerd)" "$CTD_CONF" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up"; sudo tail -8 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
sudo ctr -a "$CTD_SOCK" -n k8s.io images import "$STATE_DIR/node.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the node's images"; exit 1; }
sudo ctr -a "$CTD_SOCK" -n bench-other images import "$STATE_DIR/other.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the image of the other namespace"; exit 1; }
for _ in $(seq 1 20); do $CRICTL inspecti "$WEB_USED" >/dev/null 2>&1 && break; sleep 0.5; done
$CRICTL inspecti "$WEB_USED" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not see the node's images"; exit 1; }

echo "[setup] running the workload: one pod (host network) with two containers from the images $WEB_USED and $API_USED..."
POD=$($CRICTL runp "$WL/pod.json" 2>/dev/null | tail -1)
[ -n "$POD" ] || { echo "[setup] ERROR: the pod sandbox could not be made"; sudo tail -8 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
for c in web api; do
    CID=$($CRICTL create "$POD" "$WL/$c.json" "$WL/pod.json" 2>/dev/null | tail -1)
    [ -n "$CID" ] && $CRICTL start "$CID" >/dev/null 2>&1 || { echo "[setup] ERROR: the container $c could not be started"; exit 1; }
done
sleep 1
echo "  -> $($CRICTL ps 2>/dev/null | awk 'NR>1 {n++} END {print n+0}') containers running in the pod $POD"

echo "[setup] recording the state (root-only): hashes of the node's files, the containerd process (pid and start time), the pod and containers, the images (ids and blobs of their own)..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" CTD_CONF="$CTD_CONF" KEEP_LIST="$KEEP_LIST" WL="$WL" CTD_SOCK="$CTD_SOCK" \
    WEB_USED="$WEB_USED" API_USED="$API_USED" PAUSE="$PAUSE" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout)
pid = int(open(E["RUN_BASE"] + "/containerd.pid").read())
assert open("/proc/%d/comm" % pid).read().strip() == "containerd"
sb = [s for s in crictl("pods")["items"] if s["metadata"]["name"] == "shop"]
assert len(sb) == 1 and sb[0]["state"] == "SANDBOX_READY"
cs = {c["metadata"]["name"]: c for c in crictl("ps", "-a")["containers"] if c["podSandboxId"] == sb[0]["id"]}
assert sorted(cs) == ["api", "web"] and all(c["state"] == "CONTAINER_RUNNING" for c in cs.values())
built = json.load(open(E["STATE_DIR"] + "/built.json")); other = json.load(open(E["STATE_DIR"] + "/built-other.json"))
target_names = ["registry.bench.local/shop/web:dev-101", "registry.bench.local/shop/web:dev-102", "registry.bench.local/shop/api:dev-101", "registry.bench.local/shop/api:dev-102",
                "mirror.bench.local/team/worker:dev-7", "registry.bench.local/shop/web:dev-103"]
all_names = [n for i in built["images"] for n in i["names"]]
files = [E["WORK_DIR"] + "/bin/node-ctr", E["WORK_DIR"] + "/bin/node-crictl", E["CTD_CONF"], E["KEEP_LIST"]] + sorted(os.path.join(E["WL"], f) for f in os.listdir(E["WL"]))
d = {"files": {x: sha(x) for x in files}, "containerd": {"pid": pid, "start": open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]},
     "sandbox": sb[0]["id"], "ctrs": {n: c["id"] for n, c in cs.items()}, "images": built["images"], "base": built["base"], "all_names": all_names, "target": target_names,
     "keep": [n for n in all_names if n not in target_names], "used": [E["WEB_USED"], E["API_USED"]], "pause": E["PAUSE"], "other": other["images"], "ctd_sock": E["CTD_SOCK"]}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
print("  -> %d files hashed, containerd pid %d, %d image names (%d to be pruned, %d to stay), 1 pod with 2 containers" % (len(d["files"]), pid, len(all_names), len(target_names), len(d["keep"])))
PYEOF

echo "[setup] removing the build inputs: no archive or generator is left (the images exist in containerd's store only)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mkimg.py "$STATE_DIR"/spec*.json "$STATE_DIR"/built*.json
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node has 15 image names in the CRI's namespace (idle dev- images, a keep list, two images in use, the pinned sandbox image, other images) and 1 image in another namespace."
