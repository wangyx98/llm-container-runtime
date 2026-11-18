#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench73982083"
LIB_BASE="/opt/$CASE_ID"                 # the "VM image": containerd, shim, ctr, nerdctl, runc, the boot script, the pid of the VM's daemon (visible on the host)
CACHE="/var/cache/$CASE_ID"              # the pinned containerd and nerdctl releases (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"                 # what the "host" has: the two tools of the question and the client image tar
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
VM_SOCK="/run/k3s/containerd/containerd.sock"            # inside the VM only (where Rancher Desktop's containerd listens)
CLIENT_IMAGE="$CASE_ID-image:latest"
MARKER_NAME="$CASE_ID-marker"
CONTAINERD_VERSION="1.7.20"
NERDCTL_VERSION="1.3.1"

case "$(uname -m)" in
    x86_64|amd64)  IMG_ARCH="amd64"
                   CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67"
                   NCT_SHA="3ab552877100b336ebe3167aa57f66f99db763742f2bce9e6233644ef77fb7c9" ;;
    aarch64|arm64) IMG_ARCH="arm64"
                   CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759"
                   NCT_SHA="9e82a6a34c89d3e6a65dc8d77a3723d796d71e0784f54a0c762a2a1940294e3b" ;;
    *) echo "[setup] NOT APPLICABLE: no pinned containerd/nerdctl for $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking what the case needs is installed (runc is the runtime under test; containerd and nerdctl are pinned below)..."
for c in runc python3 curl tar sudo unshare nsenter sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
runc --version | head -1
if [ -e "$VM_SOCK" ] || [ -e /var/lib/rancher/k3s ]; then
    echo "[setup] NOT APPLICABLE: this host has k3s/Rancher paths of its own ($VM_SOCK or /var/lib/rancher/k3s): the case needs them to exist only inside the VM"; exit 1
fi

echo "[setup] ensuring gcc exists (one tiny static program goes into the client image; no registry is needed)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] containerd $CONTAINERD_VERSION and nerdctl $NERDCTL_VERSION ($IMG_ARCH): from $CACHE, else downloaded; the sha256 is checked either way..."
sudo install -d -m 0755 "$CACHE"
fetch() {   # $1 = cache file, $2 = sha256, $3 = URL
    if sudo test -f "$1" && echo "$2  $1" | sudo sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    local tmp; tmp=$(mktemp)
    curl -fsSL --retry 3 --max-time 600 -o "$tmp" "$3" || { rm -f "$tmp"; echo "[setup] ERROR: could not download $3"; exit 1; }
    echo "$2  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; echo "[setup] ERROR: $3 does not match its sha256"; exit 1; }
    sudo install -m 0644 "$tmp" "$1"; rm -f "$tmp"
}
fetch "$CACHE/containerd.tgz" "$CTD_SHA" "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-$IMG_ARCH.tar.gz"
fetch "$CACHE/nerdctl.tgz" "$NCT_SHA" "https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION/nerdctl-$NERDCTL_VERSION-linux-$IMG_ARCH.tar.gz"
sudo install -d -m 0755 "$LIB_BASE"
sudo tar -xzf "$CACHE/containerd.tgz" -C "$LIB_BASE" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
sudo tar -xzf "$CACHE/nerdctl.tgz" -C "$LIB_BASE/bin" nerdctl
sudo install -m 0755 "$(command -v runc)" "$LIB_BASE/bin/runc"     # the VM's PATH must not depend on the host's /usr/local
"$LIB_BASE/bin/containerd" --version
"$LIB_BASE/bin/nerdctl" --version

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/bin"
sudo install -d -m 0700 "$STATE_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the client image: the VM's own static nerdctl at /usr/local/bin/nerdctl and /sleeper (sleeps forever), written the way 'docker save' lays an image out..."
cat > "$BUILD/sleeper.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>
static void bye(int sig) { (void)sig; _exit(0); }
int main(void) { signal(SIGTERM, bye); signal(SIGINT, bye); for (;;) pause(); }
CEOF
gcc -static -Os -s -o "$BUILD/sleeper" "$BUILD/sleeper.c"
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, tag, arch, entry = sys.argv[1:5]
files = [a.split("=", 1) for a in sys.argv[5:]]       # dest=source ("dest=" is an empty directory)
layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    seen = set()

    def mkdir(d, mode=0o755):
        if d not in seen:
            seen.add(d)
            ti = tarfile.TarInfo(d)
            ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, mode, 0
            lt.addfile(ti)

    for dest, src in files:
        parts = dest.strip("/").split("/")
        for i in range(1, len(parts)):
            mkdir("/".join(parts[:i]))
        if not src:
            mkdir(dest.strip("/"), 0o1777 if dest.strip("/") == "tmp" else 0o755)
            continue
        data = open(src, "rb").read()
        ti = tarfile.TarInfo(dest.strip("/"))
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
        lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()
config = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
                     "config": {"Entrypoint": [entry], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]}},
                    sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": [tag], "Layers": [diff_id + "/layer.tar"]}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)
print(image_id)
PYEOF
python3 "$BUILD/mkimage.py" "$WORK_DIR/client.tar" "$CLIENT_IMAGE" "$IMG_ARCH" /sleeper \
    "usr/local/bin/nerdctl=$LIB_BASE/bin/nerdctl" "sleeper=$BUILD/sleeper" "tmp=" "var/lib/nerdctl=" "run/containerd=" >/dev/null
chmod 0644 "$WORK_DIR/client.tar"

echo "[setup] the VM: a new mount namespace whose /run, /var/lib and /usr/local are private tmpfs; containerd runs inside it with its socket and its store at the paths of Rancher Desktop's containerd, so neither exists on the host..."
cat > "$BUILD/boot.sh" <<'BEOF'
#!/bin/bash
# runs as root as the first process of a new mount namespace (unshare -m): this is the VM
V=$1
for d in /run /var/lib /usr/local; do mount -t tmpfs tmpfs "$d" || exit 1; done
mkdir -p /run/k3s/containerd /run/containerd /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/agent/etc/containerd /var/lib/nerdctl /usr/local/bin /usr/local/etc/nerdctl
install -m 0755 "$V/bin/nerdctl" /usr/local/bin/nerdctl
cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml <<'EOF'
version = 2
root = "/var/lib/rancher/k3s/agent/containerd"
state = "/run/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "/run/k3s/containerd/containerd.sock"
EOF
cat > /usr/local/etc/nerdctl/nerdctl.toml <<'EOF'
address = "/run/k3s/containerd/containerd.sock"
cgroup_manager = "cgroupfs"
EOF
readlink /proc/self/ns/mnt > "$V/vm.ns"
echo $$ > "$V/vm.pid"
export PATH="$V/bin:/usr/local/bin:$PATH"
exec containerd --config /var/lib/rancher/k3s/agent/etc/containerd/config.toml >"$V/containerd.log" 2>&1 </dev/null
BEOF
sudo install -m 0755 "$BUILD/boot.sh" "$LIB_BASE/boot.sh"
sudo rm -f "$LIB_BASE/vm.pid" "$LIB_BASE/vm.ns"
sudo setsid -f unshare -m --propagation private bash "$LIB_BASE/boot.sh" "$LIB_BASE" </dev/null >/dev/null 2>&1

echo "[setup] the tools of the question: 'rdctl shell CMD' runs CMD inside the VM; the host's nerdctl is the wrapper that Rancher Desktop puts in ~/.rd/bin (it forwards into the VM)..."
cat > "$WORK_DIR/bin/rdctl" <<REOF
#!/bin/sh
# rdctl shell COMMAND [ARGS...]: run COMMAND inside the VM
[ "\$1" = shell ] && [ \$# -ge 2 ] || { echo "usage: rdctl shell COMMAND [ARGS...]" >&2; exit 2; }
shift
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/vm.pid)/ns/mnt -- "\$@"
REOF
cat > "$WORK_DIR/bin/nerdctl" <<REOF
#!/bin/sh
# nerdctl of the host: forwarded into the VM, where the VM's nerdctl talks to the VM's containerd
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/vm.pid)/ns/mnt -- env NERDCTL_TOML=/usr/local/etc/nerdctl/nerdctl.toml /usr/local/bin/nerdctl "\$@"
REOF
chmod 0755 "$WORK_DIR/bin/rdctl" "$WORK_DIR/bin/nerdctl"
NC="$WORK_DIR/bin/nerdctl"
for _ in $(seq 1 40); do
    [ -s "$LIB_BASE/vm.pid" ] && "$NC" ps >/dev/null 2>&1 && break
    sleep 0.5
done
"$NC" ps >/dev/null 2>&1 || { echo "[setup] ERROR: the VM's containerd did not come up; last log lines:"; tail -20 "$LIB_BASE/containerd.log" 2>/dev/null; exit 1; }
echo "  -> the VM's containerd is up (pid $(cat "$LIB_BASE/vm.pid"))"

echo "[setup] the client image goes into the VM's image store; a marker container (with a per-run token) runs there, so that the VM's daemon can be told from any other..."
"$NC" load -i "$WORK_DIR/client.tar" >/dev/null
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
MARKER_ID=$("$NC" run -d --net none --pull never --name "$MARKER_NAME" --label "$CASE_ID.token=$TOKEN" "$CLIENT_IMAGE")
echo "  -> marker $MARKER_NAME ($MARKER_ID)"

echo "[setup] recording the state (root-only): the daemon's process, mount namespace and config, the token, the wrappers and the tar, the dockerd/containerd processes that exist now, the AppArmor profiles loaded now..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" TOKEN="$TOKEN" MARKER_ID="$MARKER_ID" python3 - <<'PYEOF'
import hashlib, json, os, subprocess

E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
pid = int(open(E["LIB_BASE"] + "/vm.pid").read())
s = open("/proc/%d/stat" % pid).read()
vm_sha = lambda path: subprocess.run(["nsenter", "--mount=/proc/%d/ns/mnt" % pid, "--", "sha256sum", path], capture_output=True, text=True).stdout.split()[0]


def daemons():
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                if os.path.basename(os.readlink("/proc/%s/exe" % d)) in ("containerd", "dockerd"):
                    out.append(int(d))
            except OSError:
                pass
    return out


aa = ""
if os.path.exists("/sys/kernel/security/apparmor/profiles"):
    aa = open("/sys/kernel/security/apparmor/profiles").read()
d = {"token": E["TOKEN"], "marker_id": E["MARKER_ID"], "pid": pid, "start": int(s[s.rindex(")") + 2:].split()[19]),
     "vm_ns": open(E["LIB_BASE"] + "/vm.ns").read().strip(), "host_ns": os.readlink("/proc/self/ns/mnt"),
     "config_sha": vm_sha("/var/lib/rancher/k3s/agent/etc/containerd/config.toml"), "toml_sha": vm_sha("/usr/local/etc/nerdctl/nerdctl.toml"),
     "wrappers": {w: sha(E["WORK_DIR"] + "/bin/" + w) for w in ("rdctl", "nerdctl")}, "tar_sha": sha(E["WORK_DIR"] + "/client.tar"),
     "daemons_before": daemons(), "aa_had_nerdctl_default": "nerdctl-default" in aa}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The VM's containerd and a marker container run inside the VM; the host sees no socket of it; the client image is in the VM's image store; nothing runs the client yet."
