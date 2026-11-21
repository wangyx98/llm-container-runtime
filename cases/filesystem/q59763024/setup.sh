#!/bin/bash
set -e

CASE_ID="bench59763024"
RUN_BASE="/run/$CASE_ID"              # the node's containerd: socket, state, pid file, log, the container logs
LIB_BASE="/var/lib/$CASE_ID"          # containerd's configuration and root, the deployment files
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
DEPLOY="$LIB_BASE/deploy"             # the "deployment": pod.json and controller.json (what node-apply applies)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMG="localhost/$CASE_ID/controller:1"
PAUSE="localhost/$CASE_ID/pause:1"
PORT_START=/proc/sys/net/ipv4/ip_unprivileged_port_start

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL="sudo crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"

echo "[setup] checking the stack under test is installed: containerd, ctr and crictl (the node's runtime and its clients), openssl (the certificate of the image)..."
echo "[setup] The case runs a private containerd (own socket, root and state, the CRI on) and one pod on the host network (port 80): the machine's own containerd, docker and images are not touched."
for b in containerd ctr crictl python3 sudo openssl ss curl; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then echo "[setup] NOT APPLICABLE: something listens on port 80 of this machine (the controller of the exercise needs it, on the host network)"; exit 1; fi
if [ "$(cat $PORT_START)" -le 80 ]; then echo "[setup] NOT APPLICABLE: net.ipv4.ip_unprivileged_port_start is $(cat $PORT_START) on this machine: any user may bind port 80 and the exercise has nothing to show"; exit 1; fi

echo "[setup] making sure a static busybox with the httpd applet (the image's programs) is installed..."
command -v busybox >/dev/null 2>&1 || { sudo -E apt-get update -qq; sudo -E apt-get install -y -qq "${APT_OPTS[@]}" busybox-static; }
BB=$(command -v busybox)
ldd "$BB" 2>&1 | grep -qiE 'not a dynamic|statically linked' || { echo "[setup] ERROR: $BB is not a static busybox (install busybox-static)"; exit 1; }
"$BB" --list | grep -qx httpd || { echo "[setup] ERROR: $BB has no httpd applet"; exit 1; }
case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/bin"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/logs" "$LIB_BASE/etc" "$DEPLOY"
sudo chmod 755 "$LIB_BASE" "$LIB_BASE/etc" "$DEPLOY"
cd "$WORK_DIR"
cp "$PORT_START" "$STATE_DIR/port_start"          # restored by cleanup.sh whatever a solution did to it
sudo mkdir -p "$RUN_BASE" && sudo cp "$PORT_START" "$RUN_BASE/port_start.saved"

echo "[setup] the default certificate the controller stores at its start (a self-signed one, with a name of its own for this run)..."
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=bench-fake-$NONCE" -keyout "$STATE_DIR/fake.key" -out "$STATE_DIR/fake.pem" >/dev/null 2>&1 || { echo "[setup] ERROR: openssl could not make a certificate"; exit 1; }

echo "[setup] building the images offline (OCI layout, Docker media types): the controller (a busybox as it was written to the image: without any file capability; the program /entry.sh; the certificate; the directory /etc/ingress-controller/ssl owned by uid 33, mode 775) and the sandbox image..."
cat > "$STATE_DIR/mkimg.py" <<'PYEOF'
import gzip, hashlib, io, json, subprocess, sys, tarfile
arch, bb, pem, out, built = sys.argv[1:6]
DM, DC, DL = ("application/vnd.docker.distribution.manifest.v2+json", "application/vnd.docker.container.image.v1+json", "application/vnd.docker.image.rootfs.diff.tar.gzip")
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
def info(n, size, mode, kind=tarfile.REGTYPE, link="", uid=0, gid=0):
    t = tarfile.TarInfo(n); t.size = size; t.mode = mode; t.mtime = 1700000000; t.type = kind; t.linkname = link; t.uid = uid; t.gid = gid; return t
def gz(b):
    g = io.BytesIO()
    with gzip.GzipFile(fileobj=g, mode="wb", mtime=0) as f: f.write(b)
    return g.getvalue()
def layer(build):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=tarfile.PAX_FORMAT) as t: build(t)
    return b.getvalue()
def base(t):
    for d, m in (("bin", 0o755), ("tmp", 0o1777)): t.addfile(info(d, 0, m, tarfile.DIRTYPE))
    data = open(bb, "rb").read()
    t.addfile(info("bin/busybox", len(data), 0o755), io.BytesIO(data))
    for a in subprocess.run([bb, "--list"], capture_output=True, text=True).stdout.split():
        if a != "busybox": t.addfile(info("bin/" + a, 0, 0o755, tarfile.SYMTYPE, "busybox"))
ENTRY = b"""#!/bin/sh
echo "I0101 00:00:00 main.go:150] starting the controller as uid $(id -u)"
cp /ingress-template/default-fake-certificate.pem /etc/ingress-controller/ssl/default-fake-certificate.pem 2>/tmp/err || { echo "F ssl.go:389 unexpected error storing fake SSL Cert: could not create PEM certificate file /etc/ingress-controller/ssl/default-fake-certificate.pem: $(cat /tmp/err)"; exit 1; }
echo "I0101 00:00:00 ssl.go:389 stored the fake SSL certificate"
exec /bin/busybox httpd -f -p 80 -h /www
"""
def app(t):
    for d, m, u in (("etc", 0o755, 0), ("etc/ingress-controller", 0o755, 0), ("etc/ingress-controller/ssl", 0o775, 33), ("www", 0o755, 0), ("ingress-template", 0o755, 0)):
        t.addfile(info(d, 0, m, tarfile.DIRTYPE, uid=u, gid=u))
    for n, data, m in (("ingress-template/default-fake-certificate.pem", open(pem, "rb").read(), 0o644), ("www/healthz", b"ok\n", 0o644), ("entry.sh", ENTRY, 0o755)):
        t.addfile(info(n, len(data), m), io.BytesIO(data))
    t.addfile(info("www/fake-certificate", 0, 0o777, tarfile.SYMTYPE, "/etc/ingress-controller/ssl/default-fake-certificate.pem"))
def pause(t):
    t.addfile(info("pause-image", 0, 0o644))
bl, blobs, entries, report = layer(base), {}, [], {}
bl_gz = gz(bl); blobs[sha(bl_gz)[7:]] = bl_gz
for ref, extra in ((sys.argv[6], app), (sys.argv[7], pause)):
    l2 = layer(extra); l2_gz = gz(l2); blobs[sha(l2_gz)[7:]] = l2_gz
    entry = ["/entry.sh"] if extra is app else ["/bin/busybox", "sleep", "2000000000"]
    config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {"Env": ["PATH=/usr/local/bin:/usr/bin:/bin"], "Entrypoint": entry, "Cmd": []},
                         "rootfs": {"type": "layers", "diff_ids": [sha(bl), sha(l2)]}, "history": [{"created_by": "bench59763024 " + ref}]}, separators=(",", ":")).encode()
    man = json.dumps({"schemaVersion": 2, "mediaType": DM, "config": {"mediaType": DC, "digest": sha(config), "size": len(config)},
                      "layers": [{"mediaType": DL, "digest": sha(bl_gz), "size": len(bl_gz)}, {"mediaType": DL, "digest": sha(l2_gz), "size": len(l2_gz)}]}, separators=(",", ":")).encode()
    blobs[sha(config)[7:]] = config; blobs[sha(man)[7:]] = man
    entries.append({"mediaType": DM, "digest": sha(man), "size": len(man), "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}})
    report[ref] = sha(config)
with tarfile.open(out, "w") as t:
    for name, data in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", json.dumps({"schemaVersion": 2, "manifests": entries}).encode())):
        t.addfile(info(name, len(data), 0o644), io.BytesIO(data))
    for d, data in blobs.items(): t.addfile(info("blobs/sha256/" + d, len(data), 0o644), io.BytesIO(data))
json.dump({"ids": report, "bb_sha": hashlib.sha256(open(bb, "rb").read()).hexdigest(), "pem_sha": hashlib.sha256(open(pem, "rb").read()).hexdigest()}, open(built, "w"))
PYEOF
python3 "$STATE_DIR/mkimg.py" "$ARCH" "$BB" "$STATE_DIR/fake.pem" "$STATE_DIR/node.tar" "$STATE_DIR/built.json" "$IMG" "$PAUSE"

echo "[setup] the node's containerd: own configuration $CTD_CONF (a version-3 file), own socket $CTD_SOCK, own root; the CRI plugin on; the sandbox image $PAUSE is pinned; no NRI; no CNI (the pod uses the node's network)..."
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

echo "[setup] the deployment (the files $DEPLOY/pod.json and controller.json, the question's securityContext: runAsUser 101, privilege escalation allowed, drop ALL and add NET_BIND_SERVICE)..."
sudo tee "$DEPLOY/pod.json" >/dev/null <<EOF
{"metadata": {"name": "ingress-nginx-controller", "namespace": "ingress-nginx", "uid": "bench59763024-controller", "attempt": 0}, "log_directory": "$RUN_BASE/logs",
 "linux": {"security_context": {"namespace_options": {"network": 2}}}}
EOF
sudo tee "$DEPLOY/controller.json" >/dev/null <<EOF
{"metadata": {"name": "controller"}, "image": {"image": "$IMG"}, "command": ["/entry.sh"], "log_path": "controller.log",
 "linux": {"security_context": {"run_as_user": {"value": 101}, "run_as_group": {"value": 101}, "no_new_privs": false,
                                 "capabilities": {"drop_capabilities": ["ALL"], "add_capabilities": ["NET_BIND_SERVICE"]}}}}
EOF
sudo chmod 644 "$DEPLOY"/*.json

echo "[setup] node-ctr, node-crictl and node-apply (apply the deployment files: remove the controller pod, make it again from pod.json and controller.json); all call sudo themselves..."
cat > "$WORK_DIR/bin/node-ctr" <<EOF
#!/bin/sh
# node-ctr ARGS...: ctr against the node's containerd (socket $CTD_SOCK; it calls sudo itself). The CRI's images are in the namespace k8s.io
exec sudo $(command -v ctr) -a $CTD_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/node-crictl" <<EOF
#!/bin/sh
# node-crictl ARGS...: crictl against the node's containerd (socket $CTD_SOCK; it calls sudo itself)
exec sudo $(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK "\$@"
EOF
cat > "$WORK_DIR/bin/node-apply" <<EOF
#!/bin/bash
# node-apply: apply the deployment files $DEPLOY/pod.json and controller.json: the controller pod is removed and made again, the container started (like kubectl apply for this node)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
CR="$(command -v crictl) --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
for p in \$(\$CR pods --name ingress-nginx-controller -q 2>/dev/null); do \$CR stopp "\$p" >/dev/null 2>&1; \$CR rmp "\$p" >/dev/null 2>&1; done
: > "$RUN_BASE/logs/controller.log"
P=\$(\$CR runp $DEPLOY/pod.json 2>/dev/null | tail -1) || exit 1
[ -n "\$P" ] || { echo "node-apply: the pod could not be made"; exit 1; }
C=\$(\$CR create "\$P" $DEPLOY/controller.json $DEPLOY/pod.json 2>&1 | tail -1)
case "\$C" in *[!0-9a-f]*|"") echo "node-apply: the container could not be made: \$C"; exit 1 ;; esac
\$CR start "\$C" >/dev/null 2>&1 || { echo "node-apply: the container could not be started"; exit 1; }
sleep 1
echo "pod \$P"; \$CR ps -a --pod "\$P" 2>/dev/null
EOF
chmod 755 "$WORK_DIR/bin/node-ctr" "$WORK_DIR/bin/node-crictl" "$WORK_DIR/bin/node-apply"

echo "[setup] starting the node's containerd and importing the images..."
sudo touch "$RUN_BASE/containerd.log"
sudo setsid -f bash -c 'echo $$ > "$1"; exec "$2" --config "$3" >> "$4" 2>&1 </dev/null' _ "$RUN_BASE/containerd.pid" "$(command -v containerd)" "$CTD_CONF" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 && break; sleep 0.5; done
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up"; sudo tail -8 "$RUN_BASE/containerd.log" | cut -c1-250; exit 1; }
sudo ctr -a "$CTD_SOCK" -n k8s.io images import "$STATE_DIR/node.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: ctr could not import the images"; exit 1; }
for _ in $(seq 1 20); do $CRICTL inspecti "$IMG" >/dev/null 2>&1 && break; sleep 0.5; done
$CRICTL inspecti "$IMG" >/dev/null 2>&1 || { echo "[setup] ERROR: the CRI does not see the images"; exit 1; }

echo "[setup] applying the deployment: the controller pod starts, and the controller exits at once (first failure)..."
"$WORK_DIR/bin/node-apply" >/dev/null 2>&1 || { echo "[setup] ERROR: node-apply failed"; exit 1; }
for _ in $(seq 1 20); do [ "$($CRICTL ps -a -o json 2>/dev/null | python3 -c 'import json,sys; print(",".join(c["state"] for c in json.load(sys.stdin)["containers"]))' 2>/dev/null)" = "CONTAINER_EXITED" ] && break; sleep 0.5; done
echo "  -> the log of the controller: $(sudo tail -c 400 "$RUN_BASE/logs/controller.log" | grep -m1 'F ssl' | cut -c1-260)"

echo "[setup] recording the state (root-only): hashes of the node's files, the containerd process, the image ids, the host's port setting..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" RUN_BASE="$RUN_BASE" CTD_CONF="$CTD_CONF" NONCE="$NONCE" IMG="$IMG" PAUSE="$PAUSE" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF'
import hashlib, json, os, subprocess
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
built = json.load(open(E["STATE_DIR"] + "/built.json"))
pid = int(open(E["RUN_BASE"] + "/containerd.pid").read())
assert open("/proc/%d/comm" % pid).read().strip() == "containerd"
files = [E["WORK_DIR"] + "/bin/" + n for n in ("node-ctr", "node-crictl", "node-apply")] + [E["CTD_CONF"]]
d = {"files": {x: sha(x) for x in files}, "containerd": {"pid": pid, "start": open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]}, "ids": built["ids"], "bb_sha": built["bb_sha"], "pem_sha": built["pem_sha"],
     "cn": "bench-fake-" + E["NONCE"], "img": E["IMG"], "pause": E["PAUSE"], "port_start": open("/proc/sys/net/ipv4/ip_unprivileged_port_start").read().strip(), "ctd_sock": E["CTD_SOCK"]}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
print("  -> %d files hashed, containerd pid %d, 2 images, ip_unprivileged_port_start %s" % (len(d["files"]), pid, d["port_start"]))
PYEOF

echo "[setup] removing the build inputs: no archive, key or generator is left (the images exist in containerd's store only)..."
rm -rf "$STATE_DIR"/*.tar "$STATE_DIR"/mkimg.py "$STATE_DIR"/built.json "$STATE_DIR"/fake.key "$STATE_DIR"/fake.pem
sudo chown -R root:root "$STATE_DIR"; sudo chmod 0700 "$STATE_DIR"
echo "[setup] done. The node runs a private containerd with the controller pod's deployment applied; the controller exited at once with a permission error."
