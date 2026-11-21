#!/bin/bash
set -e

CASE_ID="bench68684356"
RUN_BASE="/run/$CASE_ID"              # the node's containerd: socket, state, pid files and the logs of containerd and kubelet
LIB_BASE="/var/lib/$CASE_ID"          # containerd's configuration and root, the kubelet's directory, the static pod manifests, the gate
CACHE_DIR="/var/cache/$CASE_ID"       # the kubelet release binary (kept between runs: the cleanup does not remove it)
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
KUBELET_DIR="$LIB_BASE/kubelet"
KCONF="$KUBELET_DIR/config.yaml"
MANIFESTS="$LIB_BASE/manifests"
GATE="$LIB_BASE/gate"                 # the readiness probe of the pod gate tests the file $GATE/open
NODE="node1"                          # static pods are named <name>-<node>: gate-node1, steady-node1, never-node1
KPORT=18250                           # kubelet, https
KRO=18255                             # kubelet, read-only http
KVER="v1.34.1"
IMG="localhost/$CASE_ID/node:1"       # busybox as an image; it is the sandbox image and the image of the three pods

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
CTR="sudo ctr -a $CTD_SOCK -n k8s.io"

echo "[setup] checking the stack under test is installed: containerd + crictl (the node's runtime and its client)..."
echo "[setup] The case runs a private containerd and a private kubelet (no API server) with their own sockets, roots and ports: the machine's own are not touched."
for b in containerd ctr crictl python3 sudo sha256sum curl; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

for p in "$KPORT" "$KRO"; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$"; then echo "[setup] ERROR: port $p is in use on this machine (the kubelet of the case needs 127.0.0.1:$KPORT and 127.0.0.1:$KRO)"; exit 1; fi
done

echo "[setup] making sure a static busybox (the image's programs) is installed..."
command -v busybox >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" busybox-static; }
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
case "$(uname -m)" in
    x86_64) ARCH=amd64; KSHA="5a72c596c253ea0b0e5bcc6f29903fd41d1d542a7cadf3700c165a2a041a8d82" ;;
    aarch64|arm64) ARCH=arm64; KSHA="6a66bc08d6c637fcea50c19063cf49e708fde1630a7f1d4ceca069a45a87e6f1" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

KUBELET="$CACHE_DIR/$KVER-$ARCH/kubelet"      # named kubelet: the process name is the name of the binary
echo "[setup] the kubelet $KVER ($ARCH), the release binary of dl.k8s.io checked against its pinned sha256 (cached in $CACHE_DIR)..."
sudo mkdir -p "$(dirname "$KUBELET")"
if [ "$(sudo sha256sum "$KUBELET" 2>/dev/null | cut -d' ' -f1)" != "$KSHA" ]; then
    sudo rm -f "$KUBELET" "$KUBELET.part"
    sudo curl -fsSL --retry 3 --retry-delay 2 -o "$KUBELET.part" "https://dl.k8s.io/release/$KVER/bin/linux/$ARCH/kubelet" || { echo "[setup] ERROR: the kubelet could not be downloaded from dl.k8s.io"; exit 1; }
    [ "$(sudo sha256sum "$KUBELET.part" | cut -d' ' -f1)" = "$KSHA" ] || { echo "[setup] ERROR: the kubelet download does not match the pinned sha256"; sudo rm -f "$KUBELET.part"; exit 1; }
    sudo mv "$KUBELET.part" "$KUBELET"
fi
sudo chmod 755 "$KUBELET"
"$KUBELET" --version

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/etc" "$KUBELET_DIR" "$MANIFESTS"
sudo mkdir -p "$GATE"; sudo chmod 777 "$GATE"
sudo chmod 755 "$LIB_BASE" "$KUBELET_DIR" "$MANIFESTS"
cd "$WORK_DIR"

echo "[setup] building the node image offline (OCI layout, Docker media types): busybox with every applet; it is the pods' sandbox image too..."
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
                     "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}, "history": [{"created_by": "bench68684356 setup"}]}, separators=(",", ":")).encode()
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

echo "[setup] the node's kubelet (standalone: no API server, no kubeconfig): configuration $KCONF; it runs the static pods of $MANIFESTS on the node's containerd and judges their readiness probes itself..."
sudo tee "$KCONF" >/dev/null <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 127.0.0.1
port: $KPORT
readOnlyPort: $KRO
healthzPort: 0
authentication:
  anonymous: {enabled: true}
  webhook: {enabled: false}
authorization: {mode: AlwaysAllow}
cgroupDriver: cgroupfs
cgroupsPerQOS: false
enforceNodeAllocatable: []
failSwapOn: false
makeIPTablesUtilChains: false
imageGCHighThresholdPercent: 100
imageGCLowThresholdPercent: 99
evictionHard: {memory.available: "1Mi", nodefs.available: "1%", imagefs.available: "1%", nodefs.inodesFree: "1%"}
staticPodPath: $MANIFESTS
rootDirectory: $KUBELET_DIR/root
containerRuntimeEndpoint: unix://$CTD_SOCK
resolvConf: ""
EOF
sudo chmod 644 "$KCONF"

mkpod() {   # $1 = pod name, $2 = the exec readiness probe (YAML lines, indented for the probe)
sudo tee "$MANIFESTS/$1.yaml" >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: bench
spec:
  hostNetwork: true
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $IMG
    imagePullPolicy: Never
    command: ["/bin/sh", "-c", "while :; do sleep 1; done"]
    readinessProbe:
$2
      periodSeconds: 3
      timeoutSeconds: 5
      successThreshold: 1
      failureThreshold: 2
    volumeMounts: [{name: gate, mountPath: /gate}]
  volumes:
  - name: gate
    hostPath: {path: $GATE, type: Directory}
EOF
}
echo "[setup] three static pods, one container each, host network, an exec readiness probe every 3 s: gate (its answer follows the file $GATE/open, but only after the file has been in the same state for 3 s: a gate that is open or closed for less is ignored), steady (always passes), never (always fails)..."
GATE_PROBE=$(cat <<'EOS'
      exec:
        command:
        - /bin/sh
        - -c
        - |
          now=$(date +%s); cur=0; [ -f /gate/open ] && cur=1
          if [ "$cur" != "$(cat /tmp/cur 2>/dev/null)" ]; then echo $cur > /tmp/cur; echo $now > /tmp/since; fi
          if [ $((now - $(cat /tmp/since))) -ge 3 ]; then echo $cur > /tmp/eff; fi
          [ "$(cat /tmp/eff 2>/dev/null)" = 1 ]
EOS
)
mkpod gate "$GATE_PROBE"
mkpod steady '      exec: {command: ["/bin/true"]}'
mkpod never '      exec: {command: ["/bin/false"]}'

echo "[setup] node-ctl: start, stop and status of the node (the containerd, then the kubelet); node-crictl: crictl of this containerd (both call sudo themselves)..."
cat > "$WORK_DIR/bin/node-ctl" <<'EOF'
#!/bin/bash
# node-ctl start|stop|restart|status [containerd|kubelet]: the node = the containerd and the kubelet of this exercise, both without the word (it calls sudo itself).
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
CPID="@RUN@/containerd.pid"; KPID="@RUN@/kubelet.pid"
alive() { local p; [ -s "$1" ] && p=$(cat "$1") && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$2" ] && [ "$(awk '/^State:/ {print $2}' "/proc/$p/status" 2>/dev/null)" != "Z" ]; }
stop_one() {
    alive "$1" "$2" || return 0
    local p; p=$(cat "$1"); kill -TERM "$p"
    for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && kill -KILL "$p"
    return 0
}
start_ctd() {
    if ! alive "$CPID" containerd; then
        setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" >> "$4" 2>&1 </dev/null' _ "$CPID" "@CONTAINERD@" "@CTDCONF@" "@RUN@/containerd.log" </dev/null >/dev/null 2>&1
        for _ in $(seq 1 60); do "@CTR@" -a "@SOCK@" version >/dev/null 2>&1 && break; sleep 0.5; done
        "@CTR@" -a "@SOCK@" version >/dev/null 2>&1 || { echo "containerd did not come up; the end of its log:"; tail -5 "@RUN@/containerd.log" | cut -c1-200; return 1; }
    fi
}
start_kubelet() {
    if ! alive "$KPID" kubelet; then
        setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" --hostname-override "$4" --cert-dir "$5" >> "$6" 2>&1 </dev/null' _ "$KPID" "@KUBELET@" "@KCONF@" "@NODE@" "@KDIR@/pki" "@RUN@/kubelet.log" </dev/null >/dev/null 2>&1
        for _ in $(seq 1 60); do python3 -c 'import urllib.request,sys; urllib.request.urlopen("http://127.0.0.1:@KRO@/pods", timeout=2)' >/dev/null 2>&1 && break; sleep 1; done
        python3 -c 'import urllib.request,sys; urllib.request.urlopen("http://127.0.0.1:@KRO@/pods", timeout=2)' >/dev/null 2>&1 || { echo "the kubelet did not come up; the end of its log:"; tail -5 "@RUN@/kubelet.log" | cut -c1-200; return 1; }
    fi
}
do_start() {
    case "$1" in containerd) start_ctd ;; kubelet) start_kubelet ;; "") start_ctd && start_kubelet ;; *) echo "usage: node-ctl start|stop|restart [containerd|kubelet]"; return 2 ;; esac && echo "started"
}
do_stop() {
    case "$1" in containerd) stop_one "$CPID" containerd ;; kubelet) stop_one "$KPID" kubelet ;; "") stop_one "$KPID" kubelet; stop_one "$CPID" containerd ;; *) echo "usage: node-ctl start|stop|restart [containerd|kubelet]"; return 2 ;; esac && echo "stopped"
}
case "$1" in
    start) do_start "$2" ;;
    stop) do_stop "$2" ;;
    restart) do_stop "$2"; do_start "$2" ;;
    status) if alive "$CPID" containerd && alive "$KPID" kubelet; then echo "active (containerd pid $(cat "$CPID"), kubelet pid $(cat "$KPID"))"; else echo "inactive"; exit 3; fi ;;
    *) echo "usage: node-ctl start|stop|restart|status [containerd|kubelet]"; exit 2 ;;
esac
EOF
sed -i -e "s|@RUN@|$RUN_BASE|g" -e "s|@CONTAINERD@|$(command -v containerd)|g" -e "s|@CTDCONF@|$CTD_CONF|g" -e "s|@CTR@|$(command -v ctr)|g" -e "s|@SOCK@|$CTD_SOCK|g" \
    -e "s|@KUBELET@|$KUBELET|g" -e "s|@KCONF@|$KCONF|g" -e "s|@NODE@|$NODE|g" -e "s|@KDIR@|$KUBELET_DIR|g" -e "s|@KRO@|$KRO|g" "$WORK_DIR/bin/node-ctl"
chmod 755 "$WORK_DIR/bin/node-ctl"
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd (socket $CTD_SOCK; it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/node-crictl"

sudo touch "$RUN_BASE/containerd.log" "$RUN_BASE/kubelet.log"
echo "[setup] starting the node: containerd, the node image into it, then the kubelet (it creates the sandboxes and containers of the three pods by itself)..."
"$WORK_DIR/bin/node-ctl" start containerd >/dev/null || { echo "[setup] ERROR: the private containerd did not come up"; sudo tail -8 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
$CTR images import "$STATE_DIR/node.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the node image"; exit 1; }
for _ in $(seq 1 10); do $CRICTL inspecti "$IMG" >/dev/null 2>&1 && break; sleep 1; done
$CRICTL inspecti "$IMG" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not see the node image"; exit 1; }
"$WORK_DIR/bin/node-ctl" start kubelet >/dev/null || { echo "[setup] ERROR: the kubelet did not come up"; sudo tail -8 "$RUN_BASE/kubelet.log" | cut -c1-250; exit 1; }
echo "  -> containerd $(sudo ctr -a "$CTD_SOCK" version | awk '/Server/ {f=1} f && /Version/ {print $2; exit}') on $CTD_SOCK, kubelet $KVER on 127.0.0.1:$KPORT / $KRO"

echo "[setup] waiting for the kubelet to run the three pods and to judge them (steady: Ready; gate and never: NotReady; every container running)..."
OK=0
for _ in $(seq 1 90); do
    if python3 - "$KRO" <<'PYEOF' 2>/dev/null
import json, sys, urllib.request
d = json.load(urllib.request.urlopen("http://127.0.0.1:%s/pods" % sys.argv[1], timeout=3))
r = {}
for it in d["items"]:
    c = [x for x in it["status"].get("conditions", []) if x["type"] == "Ready"]
    cs = it["status"].get("containerStatuses") or [{}]
    r[it["metadata"]["name"]] = (bool(c) and c[0]["status"] == "True", "running" in cs[0].get("state", {}))
want = {"gate-node1": (False, True), "steady-node1": (True, True), "never-node1": (False, True)}
sys.exit(0 if r == want else 1)
PYEOF
    then OK=1; break; fi
    sleep 1
done
[ "$OK" = 1 ] || { echo "[setup] ERROR: the kubelet did not bring the three pods to the expected state; the end of its log:"; sudo tail -8 "$RUN_BASE/kubelet.log" | cut -c1-250; exit 1; }
echo "  -> OK"

echo "[setup] recording the state (root-only): hashes of the node's files and manifests, the processes (pid and start time), the ids of the sandboxes and containers..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" MANIFESTS="$MANIFESTS" KCONF="$KCONF" CTD_CONF="$CTD_CONF" KUBELET="$KUBELET" \
    CTD_SOCK="$CTD_SOCK" GATE="$GATE" KRO="$KRO" KPORT="$KPORT" NODE="$NODE" IMG="$IMG" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout)
def proc(pidfile, comm):
    pid = int(open(pidfile).read())
    assert open("/proc/%d/comm" % pid).read().strip() == comm, comm + " is not running"
    return {"pid": pid, "start": open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]}
pods = {}
sandboxes = {s["metadata"]["name"]: s for s in crictl("pods")["items"]}
ctrs = {c["podSandboxId"]: c for c in crictl("ps", "-a")["containers"]}
for n in ("gate", "steady", "never"):
    full = "%s-%s" % (n, E["NODE"])
    s = sandboxes[full]; c = ctrs[s["id"]]
    assert s["state"] == "SANDBOX_READY" and c["state"] == "CONTAINER_RUNNING", full
    pods[full] = {"sandbox": s["id"], "ctr": c["id"]}
files = [E["WORK_DIR"] + "/bin/node-ctl", E["WORK_DIR"] + "/bin/node-crictl", E["KUBELET"], E["KCONF"], E["CTD_CONF"]] + sorted(os.path.join(E["MANIFESTS"], f) for f in os.listdir(E["MANIFESTS"]))
d = {"files": {x: sha(x) for x in files}, "manifests": sorted(os.listdir(E["MANIFESTS"])), "img": E["IMG"], "ctd_sock": E["CTD_SOCK"], "gate": E["GATE"], "kro": E["KRO"], "kport": E["KPORT"],
     "containerd": proc(E["RUN_BASE"] + "/containerd.pid", "containerd"), "kubelet": proc(E["RUN_BASE"] + "/kubelet.pid", "kubelet"), "pods": pods}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
print("  -> %d files hashed, containerd pid %d, kubelet pid %d, pods %s" % (len(d["files"]), d["containerd"]["pid"], d["kubelet"]["pid"], ", ".join(sorted(pods))))
PYEOF

echo "[setup] removing the build inputs: no archive or generator is left (the image exists in containerd's store only)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mkimg.py
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node runs three pods under its kubelet; the CRI shows each of them Ready with a running container, the kubelet's judgement is a different thing."
