#!/bin/bash
set -e

CASE_ID="bench72361508"
RUN_BASE="/run/$CASE_ID"              # the node's containerd: socket, state, pid file and the node's log
LIB_BASE="/var/lib/$CASE_ID"          # its configuration and root
PODLOG="/var/log/$CASE_ID/pods"       # where the node's containers log (CRI files): <namespace>_<pod>_<uid>/<container>/<n>.log
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
NODE_LOG="$RUN_BASE/containerd.log"   # the node's runtime log: what containerd writes (the stand-in of the container-runtime log stream of a GKE node)
IMG="localhost/$CASE_ID/node:1"       # busybox as an image; it is the sandbox image of the pods too

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"

echo "[setup] checking the stack under test is installed: containerd + crictl (the node's runtime and its client)..."
echo "[setup] The case runs a private containerd with its own socket, root and log: the machine's own containerd is not touched."
for b in containerd ctr crictl python3 sudo sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure a static busybox (the image's programs) is installed..."
command -v busybox >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" busybox-static; }
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;; esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/etc" "$PODLOG"
sudo chmod 755 "/var/log/$CASE_ID" "$PODLOG"
cd "$WORK_DIR"

echo "[setup] building the node image offline (OCI layout, Docker media types): busybox with every applet; its entrypoint is a sleep, so it serves as the pods' sandbox image too..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import gzip, hashlib, io, json, subprocess, sys, tarfile
ref, arch, bb, out = sys.argv[1:5]
DM, DC, DL = ("application/vnd.docker.distribution.manifest.v2+json", "application/vnd.docker.container.image.v1+json", "application/vnd.docker.image.rootfs.diff.tar.gzip")
def info(n, size, mode, kind=tarfile.REGTYPE, link=""):
    t = tarfile.TarInfo(n); t.size = size; t.mode = mode; t.mtime = 1700000000; t.type = kind; t.linkname = link; return t
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d, m in (("bin", 0o755), ("tmp", 0o1777)):
        t.addfile(info(d, 0, m, tarfile.DIRTYPE))
    data = open(bb, "rb").read()
    t.addfile(info("bin/busybox", len(data), 0o755), io.BytesIO(data))
    for a in subprocess.run([bb, "--list"], capture_output=True, text=True).stdout.split():
        if a != "busybox": t.addfile(info("bin/" + a, 0, 0o755, tarfile.SYMTYPE, "busybox"))
layer = buf.getvalue()
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g: g.write(layer)
layer_gz = gz.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": ["PATH=/usr/local/bin:/usr/bin:/bin"], "Entrypoint": ["/bin/busybox", "sleep", "2000000000"], "Cmd": []},
                     "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}, "history": [{"created_by": "bench72361508 setup"}]}, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DM, "config": {"mediaType": DC, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DL, "digest": sha(layer_gz), "size": len(layer_gz)}]}, separators=(",", ":")).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": DM, "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for name, data in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer_gz)[7:], layer_gz),
                       ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)):
        t.addfile(info(name, len(data), 0o644), io.BytesIO(data))
PYEOF
python3 "$STATE_DIR/mkimg.py" "$IMG" "$ARCH" "$BB" "$STATE_DIR/node.tar"

echo "[setup] the node's containerd: own configuration $CTD_CONF (a version-3 file; the level of its log is info), own socket $CTD_SOCK, own root; the CRI plugin on; no NRI; no CNI (the pods use the node's network)..."
sudo tee "$CTD_CONF" >/dev/null <<EOF
version = 3
root = "$LIB_BASE/containerd"
state = "$RUN_BASE/state"
[debug]
  level = "info"
[grpc]
  address = "$CTD_SOCK"
[ttrpc]
  address = "$CTD_SOCK.ttrpc"
[plugins."io.containerd.nri.v1.nri"]
  disable = true
[plugins."io.containerd.cri.v1.runtime"]
  restrict_oom_score_adj = true
  systemd_cgroup = true
[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "$IMG"
EOF
sudo chmod 644 "$CTD_CONF"

echo "[setup] node-ctl: start, stop, restart and status of the node's containerd (like systemctl for the machine's own); it reads the configuration when it starts and appends"
echo "[setup] what containerd writes to its stderr to the node's log $NODE_LOG (a second copy of that raw stream is kept in the root-only state of the case)..."
cat > "$WORK_DIR/bin/node-ctl" <<'EOF'
#!/bin/bash
# node-ctl start|stop|restart|status: the node's containerd, like `systemctl start|stop|restart containerd` of a node (it calls sudo itself).
# containerd reads @CONF@ only when it starts; its stderr is appended to @LOG@.
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
PIDF="@PIDF@"
alive() { local p; [ -s "$PIDF" ] && p=$(cat "$PIDF") && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "containerd" ]; }
do_start() {
    alive && { echo "containerd is already running"; return 0; }
    setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" 2> >(tee -a "$5" >> "$4") >/dev/null </dev/null' _ "$PIDF" "@CONTAINERD@" "@CONF@" "@LOG@" "@RAW@" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 60); do "@CTR@" -a "@SOCK@" version >/dev/null 2>&1 && break; sleep 0.5; done
    "@CTR@" -a "@SOCK@" version >/dev/null 2>&1 && echo "containerd started" || { echo "containerd did not come up; the end of @LOG@:"; tail -5 "@LOG@" | cut -c1-200; return 1; }
}
do_stop() {
    alive || { echo "containerd is not running"; return 0; }
    p=$(cat "$PIDF"); kill -TERM "$p"
    for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && kill -KILL "$p"
    echo "containerd stopped"
}
case "$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_stop; do_start ;;
    status) if alive; then echo "active (pid $(cat "$PIDF"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: node-ctl start|stop|restart|status"; exit 2 ;;
esac
EOF
sed -i -e "s|@PIDF@|$RUN_BASE/containerd.pid|g" -e "s|@CONTAINERD@|$(command -v containerd)|g" -e "s|@CONF@|$CTD_CONF|g" -e "s|@LOG@|$NODE_LOG|g" \
    -e "s|@RAW@|$STATE_DIR/raw.log|g" -e "s|@CTR@|$(command -v ctr)|g" -e "s|@SOCK@|$CTD_SOCK|g" "$WORK_DIR/bin/node-ctl"
chmod 755 "$WORK_DIR/bin/node-ctl"
sudo touch "$STATE_DIR/raw.log" "$NODE_LOG"
"$WORK_DIR/bin/node-ctl" start >/dev/null || { echo "[setup] ERROR: the private containerd did not come up; last log lines:"; sudo tail -15 "$NODE_LOG" | cut -c1-250; exit 1; }
$CTR images import "$STATE_DIR/node.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the node image"; exit 1; }
for _ in $(seq 1 10); do $CRICTL inspecti "$IMG" >/dev/null 2>&1 && break; sleep 1; done
$CRICTL inspecti "$IMG" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not see the node image"; sudo grep -iE 'error|fail' "$NODE_LOG" | grep -v DEPRECATION | tail -6 | cut -c1-400; exit 1; }
echo "  -> containerd $(sudo ctr -a "$CTD_SOCK" version | awk '/Server/ {f=1} f && /Version/ {print $2; exit}') up on $CTD_SOCK"

echo "[setup] the wrapper node-crictl (crictl of this containerd; it calls sudo itself)..."
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd (socket $CTD_SOCK; it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/node-crictl"

echo "[setup] the node's workload: the pod web, one container that prints a numbered line to stdout every second (its CRI log file is below $PODLOG)..."
NONCE="n$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
UID_="u-web-$$"
sudo mkdir -p "$PODLOG/bench_web_$UID_"
cat > "$STATE_DIR/web-pod.json" <<JEOF
{"metadata":{"name":"web","namespace":"bench","uid":"$UID_","attempt":0},"log_directory":"$PODLOG/bench_web_$UID_","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
SCRIPT="i=0; while :; do i=\$((i+1)); echo \"web $NONCE out \$i \$(date +%s)\"; sleep 1; done"
python3 - "$STATE_DIR/web-ctr.json" "$IMG" "$SCRIPT" <<'PYEOF'
import json, sys
out, img, script = sys.argv[1:4]
json.dump({"metadata": {"name": "web"}, "image": {"image": img}, "command": ["/bin/sh", "-c", script], "log_path": "web/0.log", "linux": {}}, open(out, "w"))
PYEOF
WPOD=$($CRICTL runp "$STATE_DIR/web-pod.json" 2>/dev/null | tail -1)
[ -n "$WPOD" ] || { echo "[setup] ERROR: pod web did not start"; sudo tail -5 "$NODE_LOG" | cut -c1-250; exit 1; }
WCTR=$($CRICTL create "$WPOD" "$STATE_DIR/web-ctr.json" "$STATE_DIR/web-pod.json" 2>&1 | tail -1)
$CRICTL start "$WCTR" >/dev/null 2>&1 || { echo "[setup] ERROR: the container of web did not start: $WCTR"; exit 1; }
for _ in $(seq 1 30); do
    F=$(sudo find "$PODLOG" -path "*/web/0.log" 2>/dev/null | head -1)
    [ -n "$F" ] && [ "$(sudo wc -l "$F" 2>/dev/null | cut -d' ' -f1)" -ge 3 ] && break
    sleep 1
done
[ -n "$F" ] && [ "$(sudo wc -l "$F" | cut -d' ' -f1)" -ge 3 ] || { echo "[setup] ERROR: the log of web has no lines"; exit 1; }

echo "[setup] recording the state (root-only): hashes, the container's id, log file (inode, first line), nonce, the counts of the node's log so far..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" PODLOG="$PODLOG" IMG="$IMG" CTD_SOCK="$CTD_SOCK" CTD_CONF="$CTD_CONF" NODE_LOG="$NODE_LOG" \
    WEB_POD="$WPOD" WEB_CTR="$WCTR" WEB_NONCE="$NONCE" python3 - <<'PYEOF'
import hashlib, json, os, re, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def crictl(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a), capture_output=True, text=True).stdout
c = json.loads(crictl("inspect", E["WEB_CTR"]))
assert c["status"]["state"] == "CONTAINER_RUNNING", "web is not running"
f = c["status"]["logPath"]
assert os.path.isfile(f) and f.startswith(E["PODLOG"] + "/"), "the log of web is not below %s: %s" % (E["PODLOG"], f)
st = os.stat(f)
raw = open(E["STATE_DIR"] + "/raw.log", errors="replace").read()
lv = lambda name: len(re.findall(r"level=%s\b" % name, raw))
d = {"files": {x: sha(x) for x in [E["WORK_DIR"] + "/bin/node-ctl", E["WORK_DIR"] + "/bin/node-crictl"]}, "img": E["IMG"], "ctd_sock": E["CTD_SOCK"], "conf": E["CTD_CONF"],
     "node_log": E["NODE_LOG"], "podlog": E["PODLOG"],
     "web": {"pod": E["WEB_POD"], "ctr": E["WEB_CTR"], "nonce": E["WEB_NONCE"], "log": f, "inode": st.st_ino,
             "first_line_sha": hashlib.sha256(open(f, "rb").readline()).hexdigest()},
     "baseline": {"info": lv("info"), "warning": lv("warning"), "error": lv("error")}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
print("  -> the node's log so far: %d info, %d warning, %d error lines" % (d["baseline"]["info"], d["baseline"]["warning"], d["baseline"]["error"]))
PYEOF

echo "[setup] removing the build inputs: no archive or generator is left (the image exists in containerd's store only)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mkimg.py "$STATE_DIR"/web-pod.json "$STATE_DIR"/web-ctr.json
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node runs the workload web; containerd logs every pod and container operation of the node at level info into $NODE_LOG."
