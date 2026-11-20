#!/bin/bash
set -e

CASE_ID="bench73971174"
RUN_BASE="/run/$CASE_ID"              # the lab's containerd: socket, state, pid file, log
LIB_BASE="/var/lib/$CASE_ID"          # its configuration and root
PODLOG="/var/log/$CASE_ID/pods"       # where the node's containers log: <namespace>_<pod>_<uid>/<container>/<n>.log (the kubelet's layout)
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
IMG="localhost/$CASE_ID/node:1"       # busybox as an image; it is the sandbox image of the pods too

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"

echo "[setup] checking the stack under test is installed: containerd + crictl (the node's runtime and its client), and the machine's systemd journal..."
echo "[setup] The case runs a private containerd with its own socket and root: the machine's own containerd and journald are not touched."
for b in containerd ctr crictl python3 sudo sha256sum journalctl logger; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1
[ -S /run/systemd/journal/socket ] && sudo journalctl -q -n 1 --no-pager >/dev/null 2>&1 || { echo "[setup] ERROR: systemd-journald is not running on this machine (no /run/systemd/journal/socket)"; exit 1; }
logger --help 2>&1 | grep -q -- '--journald' || { echo "[setup] ERROR: this logger has no --journald"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure a static busybox (the image's programs) is installed..."
command -v busybox >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" busybox-static; }
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;; esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin" "$WORK_DIR/forwarder"
chmod 755 "$WORK_DIR" "$STATE_DIR" "$WORK_DIR/forwarder"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/etc" "$PODLOG"
sudo chmod 755 "/var/log/$CASE_ID" "$PODLOG"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

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
                     "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}, "history": [{"created_by": "bench73971174 setup"}]}, separators=(",", ":")).encode()
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

echo "[setup] the node's containerd: own configuration $CTD_CONF (a version-3 file), own socket $CTD_SOCK, own root; the CRI plugin on; no NRI; no CNI (the pods use the node's network)..."
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
  sandbox = "$IMG"
EOF
sudo chmod 644 "$CTD_CONF"
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" env HOME=/root "$(command -v containerd)" --config "$CTD_CONF"
for _ in $(seq 1 60); do sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up; last log lines:"; sudo tail -15 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
$CTR images import "$STATE_DIR/node.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the node image"; exit 1; }
for _ in $(seq 1 10); do $CRICTL inspecti "$IMG" >/dev/null 2>&1 && break; sleep 1; done
$CRICTL inspecti "$IMG" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not see the node image"; sudo grep -iE 'error|fail' "$RUN_BASE/containerd.log" | grep -v DEPRECATION | tail -6 | cut -c1-400; exit 1; }
echo "  -> containerd $(sudo ctr -a "$CTD_SOCK" version | awk '/Server/ {f=1} f && /Version/ {print $2; exit}') up on $CTD_SOCK"

echo "[setup] the wrapper node-crictl (crictl of this containerd; it calls sudo itself)..."
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd (socket $CTD_SOCK; it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/node-crictl"

echo "[setup] the node's workloads: two pods (web, db), one container each, printing a numbered line to stdout every second or two and to stderr every third..."
declare -A POD CTR NONCE
for n in web db; do
    NONCE[$n]="n$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
    UID_="u-$n-$$"
    sudo mkdir -p "$PODLOG/bench_${n}_$UID_"
    cat > "$STATE_DIR/$n-pod.json" <<JEOF
{"metadata":{"name":"$n","namespace":"bench","uid":"$UID_","attempt":0},"log_directory":"$PODLOG/bench_${n}_$UID_","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
    STEP=1; [ "$n" = db ] && STEP=2
    SCRIPT="i=0; while :; do i=\$((i+1)); echo \"$n ${NONCE[$n]} out \$i \$(date +%s)\"; if [ \$((i%3)) -eq 0 ]; then echo \"$n ${NONCE[$n]} err \$i \$(date +%s)\" >&2; fi; sleep $STEP; done"
    python3 - "$STATE_DIR/$n-ctr.json" "$IMG" "$n" "$SCRIPT" <<'PYEOF'
import json, sys
out, img, n, script = sys.argv[1:5]
json.dump({"metadata": {"name": n}, "image": {"image": img}, "command": ["/bin/sh", "-c", script], "log_path": n + "/0.log", "linux": {}}, open(out, "w"))
PYEOF
    POD[$n]=$($CRICTL runp "$STATE_DIR/$n-pod.json" 2>/dev/null | tail -1)
    [ -n "${POD[$n]}" ] || { echo "[setup] ERROR: pod $n did not start"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
    CTR[$n]=$($CRICTL create "${POD[$n]}" "$STATE_DIR/$n-ctr.json" "$STATE_DIR/$n-pod.json" 2>&1 | tail -1)
    $CRICTL start "${CTR[$n]}" >/dev/null 2>&1 || { echo "[setup] ERROR: container of $n did not start: ${CTR[$n]}"; exit 1; }
done
for n in web db; do
    for _ in $(seq 1 30); do
        F=$(sudo find "$PODLOG" -path "*/$n/0.log" 2>/dev/null | head -1)
        [ -n "$F" ] && [ "$(sudo wc -l "$F" 2>/dev/null | cut -d' ' -f1)" -ge 2 ] && break
        sleep 1
    done
    [ -n "$F" ] && [ "$(sudo wc -l "$F" | cut -d' ' -f1)" -ge 2 ] || { echo "[setup] ERROR: the log of $n has no lines"; exit 1; }
done

echo "[setup] recording the state (root-only): the containerd process (pid + start time + program), hashes, the containers' ids, log files (inode, first line), nonces, the time..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" PODLOG="$PODLOG" IMG="$IMG" CTD_SOCK="$CTD_SOCK" CTD_CONF="$CTD_CONF" \
    WEB_POD="${POD[web]}" WEB_CTR="${CTR[web]}" WEB_NONCE="${NONCE[web]}" DB_POD="${POD[db]}" DB_CTR="${CTR[db]}" DB_NONCE="${NONCE[db]}" python3 - <<'PYEOF'
import glob, hashlib, json, os, subprocess, time
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def crictl(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a), capture_output=True, text=True).stdout
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
targets = {}
for n in ("web", "db"):
    c = json.loads(crictl("inspect", E[n.upper() + "_CTR"]))
    assert c["status"]["state"] == "CONTAINER_RUNNING", "target %s is not running" % n
    f = c["status"]["logPath"]
    assert os.path.isfile(f) and f.startswith(E["PODLOG"] + "/"), "the log of %s is not below %s: %s" % (n, E["PODLOG"], f)
    st = os.stat(f)
    first = open(f, "rb").readline()
    targets[n] = {"pod": E[n.upper() + "_POD"], "ctr": E[n.upper() + "_CTR"], "nonce": E[n.upper() + "_NONCE"], "log": f, "inode": st.st_ino,
                  "first_line_sha": hashlib.sha256(first).hexdigest(), "size": st.st_size}
files = [E["CTD_CONF"], E["WORK_DIR"] + "/bin/node-crictl"]
d = {"daemons": {"containerd": ident("containerd")}, "files": {f: sha(f) for f in files}, "img": E["IMG"], "ctd_sock": E["CTD_SOCK"], "podlog": E["PODLOG"],
     "targets": targets, "setup_epoch": time.time()}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF

echo "[setup] removing the build inputs: no archive or generator is left (the image exists in containerd's store only)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mkimg.py "$STATE_DIR"/*-pod.json "$STATE_DIR"/*-ctr.json
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node runs two workloads (web, db); their output is in the CRI log files below $PODLOG and nowhere in the journal."
