#!/bin/bash
set -e

CASE_ID="bench63515845"
RUN_BASE="/run/$CASE_ID"              # the lab's CRI-O: socket, run root, pid file, log
LIB_BASE="/var/lib/$CASE_ID"          # its configuration, storage root and the pods' log directories
CRIO_SOCK="$RUN_BASE/crio.sock"
CRIO_ROOT="$LIB_BASE/crio/root"       # CRI-O's image and container storage (containers/storage graph root)
CRIO_RUNROOT="$RUN_BASE/crio"         # its run root
IMG="localhost/$CASE_ID/reporter:1"   # the asker's program (and busybox) as an image, in CRI-O's store
PAUSE_IMG="localhost/$CASE_ID/pause:1"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK"

echo "[setup] checking the stack under test is installed: CRI-O + crictl (the node's runtime and its client)..."
echo "[setup] The case runs a private CRI-O with its own socket and storage: the machine's own services are not touched."
for b in crio crictl python3 sudo sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
crio --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure Go (the asker's language), skopeo (copies the images into CRI-O's store) and a static busybox (the image's shell) are installed..."
need=()
command -v go >/dev/null 2>&1 || need+=(golang-go)
command -v skopeo >/dev/null 2>&1 || need+=(skopeo)
command -v busybox >/dev/null 2>&1 || need+=(busybox-static)
if [ ${#need[@]} -gt 0 ]; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" "${need[@]}"
fi
go version; skopeo --version
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
CRICTL_BIN=$(command -v crictl)
ldd "$CRICTL_BIN" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $CRICTL_BIN is not a static program: it could not run in the image"; exit 1; }
case "$(uname -m)" in x86_64) GOARCH=amd64 ;; aarch64|arm64) GOARCH=arm64 ;; *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;; esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin" "$WORK_DIR/app" "$WORK_DIR/reporter/logs"
chmod 755 "$WORK_DIR" "$STATE_DIR" "$WORK_DIR/reporter" "$WORK_DIR/reporter/logs"
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/crio" "$LIB_BASE/cni/bin" "$LIB_BASE/cni/net.d" "$LIB_BASE/logs/web" "$LIB_BASE/logs/db"
sudo chmod -R 755 "$LIB_BASE/logs"
cd "$WORK_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of the daemon itself (exec keeps the pid);
# setsid + all three fds redirected so it outlives this script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] the asker's program (his code; only the command comes from the first argument, as 'cmdStr can be any docker or cri-o command' in the question)..."
cat > "$WORK_DIR/app/main.go" <<'GOEOF'
package main

import "os/exec"
import "fmt"
import "os"

func main() {
	cmdStr := "docker ps"
	if len(os.Args) > 1 {
		cmdStr = os.Args[1]
	}
	fmt.Printf("cmdStr is %s", cmdStr)
	out, _ := exec.Command("/bin/sh", "-c", cmdStr).Output()
	fmt.Printf("output is %s", out)
}
GOEOF
chmod 644 "$WORK_DIR/app/main.go"
printf 'package main\n\nimport "time"\n\nfunc main() { time.Sleep(1 << 62) }\n' > "$STATE_DIR/pause.go"
export GOCACHE="$STATE_DIR/gocache" GOPATH="$STATE_DIR/gopath" GO111MODULE=off CGO_ENABLED=0 GOARCH="$GOARCH" GOOS=linux
go build -o "$STATE_DIR/cmdrun" "$WORK_DIR/app/main.go"
go build -o "$STATE_DIR/pause" "$STATE_DIR/pause.go"
unset GOCACHE GOPATH GO111MODULE CGO_ENABLED GOARCH GOOS

echo "[setup] building the two images offline, in 'docker save' format: the reporter (busybox with every applet, and the asker's program as /app/cmdrun) and the sandbox image of the pods..."
cat > "$STATE_DIR/mksave.py" <<'PYEOF'
import hashlib, io, json, subprocess, sys, tarfile
out, name, arch, entry, bb, cmdrun = sys.argv[1:7]
def info(n, size, mode, kind=tarfile.REGTYPE, link=""):
    t = tarfile.TarInfo(n); t.size = size; t.mode = mode; t.mtime = 0; t.type = kind; t.linkname = link; return t
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    if entry == "/app/cmdrun":
        for d, m in (("bin", 0o755), ("app", 0o755), ("tmp", 0o1777)):
            t.addfile(info(d, 0, m, tarfile.DIRTYPE))
        data = open(bb, "rb").read()
        t.addfile(info("bin/busybox", len(data), 0o755), io.BytesIO(data))
        for a in subprocess.run([bb, "--list"], capture_output=True, text=True).stdout.split():
            if a != "busybox": t.addfile(info("bin/" + a, 0, 0o755, tarfile.SYMTYPE, "busybox"))
        data = open(cmdrun, "rb").read()
        t.addfile(info("app/cmdrun", len(data), 0o755), io.BytesIO(data))
    else:
        data = open(cmdrun, "rb").read()
        t.addfile(info(entry.lstrip("/"), len(data), 0o755), io.BytesIO(data))
layer = buf.getvalue()
diff_id = "sha256:" + hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Entrypoint": [entry], "Env": ["PATH=/usr/local/bin:/usr/bin:/bin"]},
                  "rootfs": {"type": "layers", "diff_ids": [diff_id]}, "history": [{"created_by": "bench63515845 setup"}]}).encode()
ch = hashlib.sha256(cfg).hexdigest()
man = json.dumps([{"Config": ch + ".json", "RepoTags": [name], "Layers": [ch[:16] + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for n, d in ((ch + ".json", cfg), (ch[:16] + "/layer.tar", layer), ("manifest.json", man)):
        t.addfile(info(n, len(d), 0o644), io.BytesIO(d))
print(ch)
PYEOF
python3 "$STATE_DIR/mksave.py" "$STATE_DIR/reporter.tar" "$IMG" "$GOARCH" /app/cmdrun "$BB" "$STATE_DIR/cmdrun" >/dev/null
python3 "$STATE_DIR/mksave.py" "$STATE_DIR/pause.tar" "$PAUSE_IMG" "$GOARCH" /pause "$BB" "$STATE_DIR/pause" >/dev/null

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

echo "[setup] the two images are copied into CRI-O's own storage ($CRIO_ROOT) with skopeo, before CRI-O starts (no registry is involved)..."
echo '{"default":[{"type":"insecureAcceptAnything"}]}' | sudo tee "$LIB_BASE/crio/policy.json" >/dev/null
sudo mkdir -p "$CRIO_ROOT" "$CRIO_RUNROOT"
sudo skopeo copy --quiet --policy "$LIB_BASE/crio/policy.json" "docker-archive:$STATE_DIR/pause.tar" "containers-storage:[overlay@$CRIO_ROOT+$CRIO_RUNROOT]$PAUSE_IMG"
sudo skopeo copy --quiet --policy "$LIB_BASE/crio/policy.json" "docker-archive:$STATE_DIR/reporter.tar" "containers-storage:[overlay@$CRIO_ROOT+$CRIO_RUNROOT]$IMG"

echo "[setup] the private CRI-O: own socket $CRIO_SOCK, storage root $CRIO_ROOT, run root $CRIO_RUNROOT, no registries, no NRI; its pods use the node's network (no CNI)..."
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
for i in "$IMG" "$PAUSE_IMG"; do $CRICTL inspecti "$i" >/dev/null 2>&1 || { echo "[setup] ERROR: CRI-O does not see the image $i"; exit 1; }; done
echo "  -> CRI-O $($CRICTL version 2>/dev/null | awk '/RuntimeVersion/ {print $2}') up on $CRIO_SOCK"

echo "[setup] the wrapper node-crictl (crictl of this CRI-O; it calls sudo itself)..."
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's CRI-O (socket $CRIO_SOCK; it calls sudo itself)
exec sudo $CRICTL_BIN --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK "\$@"
EOF
chmod 755 "$WORK_DIR/bin/node-crictl"

echo "[setup] the node's workloads: two pods (web, db), each with one container that sleeps and carries a per-run nonce in its environment..."
mkpod() {   # $1 = name, $2 = directory of the log
    cat > "$STATE_DIR/$1-pod.json" <<JEOF
{"metadata":{"name":"$1","namespace":"bench","uid":"u-$1-$$","attempt":1},"log_directory":"$2","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
}
declare -A POD CTR NONCE
for n in web db; do
    NONCE[$n]="nonce-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
    mkpod "$n" "$LIB_BASE/logs/$n"
    cat > "$STATE_DIR/$n-ctr.json" <<JEOF
{"metadata":{"name":"app"},"image":{"image":"$IMG"},"command":["/bin/sh","-c","exec sleep 1000000"],"envs":[{"key":"BENCH_NONCE","value":"${NONCE[$n]}"}],"log_path":"app.log","linux":{}}
JEOF
    POD[$n]=$($CRICTL runp "$STATE_DIR/$n-pod.json" 2>/dev/null | tail -1)
    [ -n "${POD[$n]}" ] || { echo "[setup] ERROR: pod $n did not start"; sudo tail -5 "$RUN_BASE/crio.log" | cut -c1-250; exit 1; }
    CTR[$n]=$($CRICTL create "${POD[$n]}" "$STATE_DIR/$n-ctr.json" "$STATE_DIR/$n-pod.json" 2>&1 | tail -1)
    $CRICTL start "${CTR[$n]}" >/dev/null 2>&1 || { echo "[setup] ERROR: container of $n did not start"; exit 1; }
done

echo "[setup] the reporter pod, as it runs on the asker's node: the asker's program with the command 'crictl ps --no-trunc -a --quiet', as a non-root user..."
cat > "$WORK_DIR/reporter/pod.json" <<JEOF
{
  "metadata": {"name": "reporter", "namespace": "bench", "uid": "u-reporter-$$", "attempt": 1},
  "log_directory": "$WORK_DIR/reporter/logs",
  "linux": {"security_context": {"namespace_options": {"network": 2}}}
}
JEOF
cat > "$WORK_DIR/reporter/container.json" <<JEOF
{
  "metadata": {"name": "reporter"},
  "image": {"image": "$IMG"},
  "args": ["crictl ps --no-trunc -a --quiet"],
  "log_path": "reporter.log",
  "linux": {"security_context": {"run_as_user": {"value": 1000540000}, "run_as_group": {"value": 1000540000}}}
}
JEOF
chmod 644 "$WORK_DIR/reporter/pod.json" "$WORK_DIR/reporter/container.json"
RPOD=$($CRICTL runp "$WORK_DIR/reporter/pod.json" 2>/dev/null | tail -1)
[ -n "$RPOD" ] || { echo "[setup] ERROR: the reporter pod did not start"; exit 1; }
RCTR=$($CRICTL create "$RPOD" "$WORK_DIR/reporter/container.json" "$WORK_DIR/reporter/pod.json" 2>&1 | tail -1)
$CRICTL start "$RCTR" >/dev/null 2>&1 || { echo "[setup] ERROR: the reporter container did not start"; exit 1; }
for _ in $(seq 1 30); do
    ST=$($CRICTL inspect "$RCTR" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null || true)
    [ "$ST" = "CONTAINER_EXITED" ] && break
    sleep 1
done
[ "$ST" = "CONTAINER_EXITED" ] || { echo "[setup] ERROR: the reporter container did not finish ($ST)"; exit 1; }
sudo chmod -R a+rX "$WORK_DIR/reporter/logs"

echo "[setup] recording the state (root-only): the CRI-O process (pid + start time + program), hashes of CRI-O's configuration and the wrapper, the image ids, the workloads' ids, pids and nonces..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" IMG="$IMG" PAUSE_IMG="$PAUSE_IMG" CRIO_SOCK="$CRIO_SOCK" CRICTL_BIN="$CRICTL_BIN" \
    RPOD="$RPOD" RCTR="$RCTR" WEB_POD="${POD[web]}" WEB_CTR="${CTR[web]}" WEB_NONCE="${NONCE[web]}" DB_POD="${POD[db]}" DB_CTR="${CTR[db]}" DB_NONCE="${NONCE[db]}" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
def crictl(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CRIO_SOCK"], "--image-endpoint", "unix://" + E["CRIO_SOCK"]] + list(a), capture_output=True, text=True).stdout
def ident(name):
    pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
    s = open("/proc/%d/stat" % pid).read()
    return [pid, int(s[s.rindex(")") + 2:].split()[19]), os.readlink("/proc/%d/exe" % pid)]
targets = {}
for n in ("web", "db"):
    c = json.loads(crictl("inspect", E[n.upper() + "_CTR"]))
    pid = c["info"]["pid"]
    assert c["status"]["state"] == "CONTAINER_RUNNING" and pid > 1, "target %s is not running" % n
    assert ("BENCH_NONCE=" + E[n.upper() + "_NONCE"]).encode() in open("/proc/%d/environ" % pid, "rb").read().split(b"\0"), "pid %d of %s is not the container's process" % (pid, n)
    targets[n] = {"pod": E[n.upper() + "_POD"], "ctr": E[n.upper() + "_CTR"], "pid": pid, "nonce": E[n.upper() + "_NONCE"]}
img = json.loads(crictl("inspecti", E["IMG"]))["status"]["id"]
files = [E["LIB_BASE"] + "/crio/crio.conf", E["LIB_BASE"] + "/crio/policy.json", E["WORK_DIR"] + "/bin/node-crictl"]
d = {"daemons": {"crio": ident("crio")}, "files": {f: sha(f) for f in files}, "img": E["IMG"], "img_id": img.replace("sha256:", ""),
     "pause_img": E["PAUSE_IMG"], "crio_sock": E["CRIO_SOCK"], "crictl_bin": E["CRICTL_BIN"], "targets": targets,
     "reporter": {"pod": E["RPOD"], "ctr": E["RCTR"]}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF

echo "[setup] removing the build inputs: no archive, generator or built program is left (the image exists in CRI-O's store only; the asker's source stays in $WORK_DIR/app)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mksave.py "$STATE_DIR"/cmdrun "$STATE_DIR"/pause "$STATE_DIR"/pause.go "$STATE_DIR"/gocache "$STATE_DIR"/gopath
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node runs two workloads (web, db); the reporter pod ran the asker's program and printed nothing."
