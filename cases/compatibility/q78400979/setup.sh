#!/bin/bash
set -e

# Same non-interactive apt settings as the other cases (needrestart pops up dialogs otherwise).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

GRPCURL_VERSION="1.9.1"

CASE_ID="bench78400979"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the private containerd, the registry
LIB_BASE="/var/lib/$CASE_ID"          # image store of the private containerd
SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"          # registry blobs, digests.json, requests.log (root-owned)
CERTS_DIR="$RUN_BASE/certs.d"
REG_PORT=15078
IMAGE_REF="127.0.0.1:$REG_PORT/$CASE_ID/app:latest"
NS="k8s.io"                           # the namespace the CRI uses

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PROTO_DIR="$WORK_DIR/proto"

echo "[setup] checking containerd, runc and the ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure curl, gcc and python3 are available (curl: grpcurl download and"
echo "[setup] this case's own checks; gcc: one tiny static program for the image, so the"
echo "[setup] same script works on x86_64 and arm64 and the image needs no download)..."
if ! command -v curl >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

case "$(uname -m)" in
    x86_64|amd64)   IMG_ARCH="amd64"; GRPCURL_ARCH="x86_64" ;;
    aarch64|arm64)  IMG_ARCH="arm64"; GRPCURL_ARCH="arm64" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

sudo mkdir -p "$LIB_BASE"
echo "[setup] ensuring grpcurl $GRPCURL_VERSION is installed (the gRPC client of the story)..."
if command -v grpcurl >/dev/null 2>&1; then
    echo "  -> already installed: $(command -v grpcurl)"
else
    rm -rf "$WORK_DIR"; mkdir -p "$STATE_DIR"
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPCURL_ARCH}.tar.gz" \
        -o "$STATE_DIR/grpcurl.tar.gz"
    tar -xzf "$STATE_DIR/grpcurl.tar.gz" -C "$STATE_DIR" grpcurl
    sudo install -m 0755 "$STATE_DIR/grpcurl" /usr/local/bin/grpcurl
    # cleanup.sh removes it again: other cases require that grpcurl is NOT on the machine
    echo /usr/local/bin/grpcurl | sudo tee "$LIB_BASE/grpcurl_installed_by_case" >/dev/null
fi
grpcurl -version 2>&1 | head -1

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$PROTO_DIR/runtime/v1" "$PROTO_DIR/containerd/services/images/v1"
cd "$WORK_DIR"

echo "[setup] writing the API definitions (.proto) for the installed containerd: the two"
echo "[setup] services the story is about, reduced to the messages needed here (field"
echo "[setup] numbers and names are those of containerd's own definitions)..."
cat > "$PROTO_DIR/runtime/v1/api.proto" <<'PEOF'
syntax = "proto3";

package runtime.v1;

// Kubernetes CRI image service (served by containerd's CRI plugin), reduced.
service ImageService {
    rpc ListImages(ListImagesRequest) returns (ListImagesResponse) {}
    rpc ImageStatus(ImageStatusRequest) returns (ImageStatusResponse) {}
    rpc PullImage(PullImageRequest) returns (PullImageResponse) {}
}

message ImageSpec {
    string image = 1;
    map<string, string> annotations = 2;
}

message AuthConfig {
    string username = 1;
    string password = 2;
    string auth = 3;
    string server_address = 4;
    string identity_token = 5;
    string registry_token = 6;
}

message ImageFilter {
    ImageSpec image = 1;
}

message ListImagesRequest {
    ImageFilter filter = 1;
}

message Image {
    string id = 1;
    repeated string repo_tags = 2;
    repeated string repo_digests = 3;
    uint64 size = 4;
}

message ListImagesResponse {
    repeated Image images = 1;
}

message ImageStatusRequest {
    ImageSpec image = 1;
    bool verbose = 2;
}

message ImageStatusResponse {
    Image image = 1;
    map<string, string> info = 2;
}

message PullImageRequest {
    ImageSpec image = 1;
    AuthConfig auth = 2;
}

message PullImageResponse {
    string image_ref = 1;
}
PEOF
cat > "$PROTO_DIR/containerd/services/images/v1/images.proto" <<'PEOF'
syntax = "proto3";

package containerd.services.images.v1;

// containerd's native image metadata service (served in every namespace), reduced.
// Requests are scoped to a namespace with the gRPC header "containerd-namespace".
service Images {
    rpc Get(GetImageRequest) returns (GetImageResponse);
    rpc List(ListImagesRequest) returns (ListImagesResponse);
    rpc Create(CreateImageRequest) returns (CreateImageResponse);
}

message Image {
    string name = 1;
    map<string, string> labels = 2;
    Descriptor target = 3;
}

message Descriptor {
    string media_type = 1;
    string digest = 2;
    int64 size = 3;
}

message GetImageRequest {
    string name = 1;
}

message GetImageResponse {
    Image image = 1;
}

message CreateImageRequest {
    Image image = 1;
}

message CreateImageResponse {
    Image image = 1;
}

message ListImagesRequest {
    repeated string filters = 1;
}

message ListImagesResponse {
    repeated Image images = 1;
}
PEOF

echo "[setup] compiling the workload: prints a line with a per-run random token and exits."
echo "[setup] The token exists only inside the image, so seeing it in the output of a"
echo "[setup] container proves that container runs THIS image..."
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
cat > "$STATE_DIR/workload.c" <<'CEOF'
#include <stdio.h>

int main(void) {
    puts("bench78400979-workload-ok token=" TOKEN);
    return 0;
}
CEOF
gcc -static -Os -s -DTOKEN="\"$TOKEN\"" -o "$STATE_DIR/workload" "$STATE_DIR/workload.c"
echo "$TOKEN" > "$STATE_DIR/token"

echo "[setup] building the image as registry content (layer, config, manifest: three blobs,"
echo "[setup] OCI format) and a minimal registry that serves it over plain HTTP on"
echo "[setup] 127.0.0.1:$REG_PORT and logs every request with its User-Agent..."
sudo mkdir -p "$REG_DIR"
cat > "$STATE_DIR/mkreg.py" <<'PYEOF'
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

out, binary, arch = sys.argv[1:4]
data = open(binary, "rb").read()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as t:
    for d in ("usr", "usr/bin"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode = tarfile.DIRTYPE, 0o755
        t.addfile(ti)
    ti = tarfile.TarInfo("usr/bin/workload")
    ti.size, ti.mode = len(data), 0o755
    t.addfile(ti, io.BytesIO(data))
tar = buf.getvalue()
diff_id = hashlib.sha256(tar).hexdigest()
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(tar)
layer = gz.getvalue()
layer_d = hashlib.sha256(layer).hexdigest()
cfg = json.dumps({
    "architecture": arch, "os": "linux",
    "config": {"Cmd": ["/usr/bin/workload"]},
    "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]},
}, sort_keys=True, separators=(",", ":")).encode()
cfg_d = hashlib.sha256(cfg).hexdigest()
man = json.dumps({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
               "digest": "sha256:" + cfg_d, "size": len(cfg)},
    "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                "digest": "sha256:" + layer_d, "size": len(layer)}],
}, sort_keys=True, separators=(",", ":")).encode()
man_d = hashlib.sha256(man).hexdigest()
os.makedirs(out + "/blobs", exist_ok=True)
for d, b in ((layer_d, layer), (cfg_d, cfg), (man_d, man)):
    open(out + "/blobs/sha256_" + d, "wb").write(b)
json.dump({
    "manifest": "sha256:" + man_d, "manifest_size": len(man),
    "config": "sha256:" + cfg_d, "config_size": len(cfg),
    "layer": "sha256:" + layer_d, "layer_size": len(layer),
}, open(out + "/digests.json", "w"))
PYEOF
python3 "$STATE_DIR/mkreg.py" "$STATE_DIR/reg" "$STATE_DIR/workload" "$IMG_ARCH"
sudo cp -r "$STATE_DIR/reg/." "$REG_DIR/"
cat > "$STATE_DIR/registry.py" <<'PYEOF'
import http.server
import json
import os
import sys

root, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(root + "/digests.json"))
MAN = open(root + "/blobs/sha256_" + d["manifest"].split(":")[1], "rb").read()
LOG = open(logfile, "a", buffering=1)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype, digest=None, head=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if digest:
            self.send_header("Docker-Content-Digest", digest)
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _serve(self, head):
        p = self.path.split("?")[0]
        LOG.write("%s %s ua=%s\n" % ("HEAD" if head else "GET", p, self.headers.get("User-Agent", "")))
        if p in ("/v2/", "/v2"):
            return self._send(200, b"{}", "application/json", head=head)
        parts = p.strip("/").split("/")
        if len(parts) >= 4 and parts[0] == "v2" and parts[-2] in ("manifests", "blobs"):
            kind, ref = parts[-2], parts[-1]
            if kind == "manifests" and ref in ("latest", d["manifest"]):
                return self._send(200, MAN, "application/vnd.oci.image.manifest.v1+json", d["manifest"], head)
            if kind == "blobs" and ref.startswith("sha256:"):
                f = root + "/blobs/sha256_" + ref.split(":")[1]
                if os.path.exists(f):
                    return self._send(200, open(f, "rb").read(), "application/octet-stream", ref, head)
        self._send(404, b'{"errors":[{"code":"NAME_UNKNOWN"}]}', "application/json", head=head)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)


class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S(("127.0.0.1", port), H).serve_forever()
PYEOF
sudo cp "$STATE_DIR/registry.py" "$REG_DIR/registry.py"
sudo touch "$REG_DIR/requests.log"
# setsid + all fds redirected: the registry must outlive this script and must not keep the
# harness's pipes open
sudo setsid -f bash -c 'echo $$ > "$1/registry.pid"; exec python3 "$1/registry.py" "$1" "$2" "$1/requests.log" >"$1/registry.out" 2>&1 </dev/null' _ "$REG_DIR" "$REG_PORT" </dev/null >/dev/null 2>&1
for _ in $(seq 1 40); do
    curl -sf --max-time 2 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -sf --max-time 2 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null || { echo "[setup] ERROR: registry did not come up"; exit 1; }
echo "  -> registry up, image $IMAGE_REF"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own"
echo "[setup] default config for the installed version, moved into that root/state, NRI off,"
echo "[setup] restrict_oom_score_adj on, CRI registry config directory set). The CRI plugin"
echo "[setup] only pulls from a plain-HTTP registry when told so by a hosts.toml, written"
echo "[setup] here for 127.0.0.1:$REG_PORT..."
sudo mkdir -p "$CERTS_DIR/127.0.0.1:$REG_PORT" "$LIB_BASE"
cat <<HEOF | sudo tee "$CERTS_DIR/127.0.0.1:$REG_PORT/hosts.toml" >/dev/null
server = "http://127.0.0.1:$REG_PORT"

[host."http://127.0.0.1:$REG_PORT"]
  capabilities = ["pull", "resolve"]
HEOF
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock, certs = sys.argv[1:5]
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
        line = f"{indent}restrict_oom_score_adj = true\n"
    elif section.endswith(".registry") and "cri" in section and k == "config_path":
        line = f"{indent}config_path = '{certs}'\n"
    sys.stdout.write(line)
PYEOF
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE" "$RUN_BASE" "$SOCK" "$CERTS_DIR" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
if ! sudo grep -q "config_path = '$CERTS_DIR'" "$RUN_BASE/config.toml"; then
    echo "[setup] ERROR: this containerd version's default config has no CRI registry config_path to patch"
    exit 1
fi
sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$RUN_BASE" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo ctr -a "$SOCK" version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $SOCK"

echo "[setup] recreating the engineer's mistake: the image is registered with the native"
echo "[setup] Images service (Images/Create) in the '$NS' namespace, pointing at the"
echo "[setup] manifest the registry serves. That call stores a metadata record only..."
cat > "$STATE_DIR/mkcreate.py" <<'PYEOF'
import json
import struct
import sys


def varint(n):
    out = b""
    while True:
        b = n & 0x7f
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def field(num, payload):
    return varint(num << 3 | 2) + varint(len(payload)) + payload


digests, ref = sys.argv[1:3]
d = json.load(open(digests))
desc = field(1, b"application/vnd.oci.image.manifest.v1+json") + field(2, d["manifest"].encode()) \
    + varint(3 << 3) + varint(d["manifest_size"])
image = field(1, ref.encode()) + field(3, desc)
msg = field(1, image)
sys.stdout.buffer.write(b"\x00" + struct.pack(">I", len(msg)) + msg)
PYEOF
sudo python3 "$STATE_DIR/mkcreate.py" "$REG_DIR/digests.json" "$IMAGE_REF" \
    | sudo curl -sS --http2-prior-knowledge --unix-socket "$SOCK" \
        -H 'content-type: application/grpc' -H 'te: trailers' -H "containerd-namespace: $NS" \
        -D "$STATE_DIR/create.hdr" --data-binary @- \
        "http://localhost/containerd.services.images.v1.Images/Create" -o /dev/null
if ! tr -d '\r' < "$STATE_DIR/create.hdr" | grep -qi '^grpc-status: *0$'; then
    echo "[setup] ERROR: Images/Create did not succeed:"; cat "$STATE_DIR/create.hdr"
    exit 1
fi
sudo ctr -a "$SOCK" -n "$NS" images ls "name==$IMAGE_REF" 2>/dev/null | sed 's/^/  -> /'

echo "[setup] removing the build inputs (the only thing left is the registry and the image's"
echo "[setup] metadata record)..."
rm -f "$STATE_DIR/workload" "$STATE_DIR/workload.c" "$STATE_DIR/mkreg.py" "$STATE_DIR/registry.py" \
      "$STATE_DIR/patch_config.py" "$STATE_DIR/mkcreate.py" "$STATE_DIR/grpcurl" "$STATE_DIR/grpcurl.tar.gz"
rm -rf "$STATE_DIR/reg" "$STATE_DIR/create.hdr"

echo "[setup] done. containerd lists $IMAGE_REF in '$NS' but holds none of its content."
