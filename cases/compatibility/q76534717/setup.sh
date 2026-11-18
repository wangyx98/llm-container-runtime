#!/bin/bash
set -e

CASE_ID="bench76534717"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                 # containerd's root, the pinned programs (containerd, ctr, the real grpcurl)
RUN="/run/$CASE_ID"                     # containerd's socket and state, the log of grpcurl calls
CACHE="/var/cache/$CASE_ID"             # the downloaded releases (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"                # what the solution may use: bin/grpcurl (logging wrapper), proto/containers.proto; world-readable
STATE_DIR="$WORK_DIR/.bench"            # root-only: ids, nonces, hashes
SOCK="$RUN/containerd.sock"
CTD_VERSION="1.7.20"; GRPCURL_VERSION="1.9.1"
NS="k8s.io"

case "$(uname -m)" in
    x86_64|amd64)  KARCH="amd64"; GARCH="x86_64"
        CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67"; GRPCURL_SHA="588c9c429476d9ed66cd3b2ae32283a6da36e0cfbb7e446f5d6a1b68dc770214" ;;
    aarch64|arm64) KARCH="arm64"; GARCH="arm64"
        CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759"; GRPCURL_SHA="fc0d0453dd9f276fa2158f34ba1666f7fd4d6e4053f781d0945226ebe8914cb1" ;;
    *) echo "[setup] NOT APPLICABLE: no pinned programs for $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] port 8080 of the loopback must be free (the question's containerd serves a TCP address there)..."
python3 - <<'PYEOF'
import sys
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for l in open(f).read().splitlines()[1:]:
            c = l.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == 8080:
                sys.exit("[setup] ERROR: something already listens on port 8080")
    except OSError:
        pass
PYEOF

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
install -d -m 0755 "$WORK_DIR" "$WORK_DIR/bin" "$WORK_DIR/proto"
sudo install -d -m 0700 "$STATE_DIR"
sudo install -d -m 0755 "$LIB" "$LIB/bin" "$RUN" "$CACHE"

fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION and grpcurl v$GRPCURL_VERSION ($KARCH): from the cache $CACHE, else downloaded (sha256 checked)..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "grpcurl_${GRPCURL_VERSION}_linux_$GARCH.tar.gz" "https://github.com/fullstorydev/grpcurl/releases/download/v$GRPCURL_VERSION/grpcurl_${GRPCURL_VERSION}_linux_$GARCH.tar.gz" "$GRPCURL_SHA"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$BUILD" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
tar -xzf "$CACHE/grpcurl_${GRPCURL_VERSION}_linux_$GARCH.tar.gz" -C "$BUILD" grpcurl
sudo install -m 755 -o root -g root "$BUILD/bin/containerd" "$BUILD/bin/ctr" "$BUILD/grpcurl" "$LIB/bin/"
echo "  $("$LIB/bin/containerd" --version | cut -d' ' -f1-3), $("$LIB/bin/grpcurl" -version 2>&1)"

echo "[setup] the grpcurl the solution uses: $WORK_DIR/bin/grpcurl is the pinned program behind a wrapper that logs every call (arguments and exit code)..."
cat > "$WORK_DIR/bin/grpcurl" <<WEOF
#!/bin/sh
# grpcurl v$GRPCURL_VERSION; every call is appended to $RUN/grpcurl.log
rc=0
$LIB/bin/grpcurl "\$@" || rc=\$?
printf '%s rc=%s %s\n' "\$(date +%s)" "\$rc" "\$*" >> $RUN/grpcurl.log 2>/dev/null
exit \$rc
WEOF
chmod 755 "$WORK_DIR/bin/grpcurl"
sudo sh -c ": > '$RUN/grpcurl.log'; chmod 0666 '$RUN/grpcurl.log'"

echo "[setup] the proto of the Containers service (the Containers API of containerd, only the List and Get calls and the Container fields that matter;"
echo "[setup] field numbers as in containerd's api/services/containers/v1/containers.proto; adaptation: the full proto tree is not downloadable here)..."
cat > "$WORK_DIR/proto/containers.proto" <<'PEOF'
syntax = "proto3";
package containerd.services.containers.v1;

service Containers {
  rpc Get(GetContainerRequest) returns (GetContainerResponse);
  rpc List(ListContainersRequest) returns (ListContainersResponse);
}

message Container {
  string id = 1;
  map<string, string> labels = 2;
  string image = 3;
  string snapshotter = 6;
  string snapshot_key = 7;
}

message GetContainerRequest { string id = 1; }
message GetContainerResponse { Container container = 1; }
message ListContainersRequest { repeated string filters = 1; }
message ListContainersResponse { repeated Container containers = 1; }
PEOF

echo "[setup] containerd $CTD_VERSION as in the question's log: its own socket AND a TCP address 127.0.0.1:8080 (no CRI plugin)..."
sudo tee "$LIB/containerd.toml" >/dev/null <<TOMLEOF
version = 2
root = "$LIB/containerd"
state = "$RUN/state"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "$SOCK"
  tcp_address = "127.0.0.1:8080"
[plugins."io.containerd.internal.v1.opt"]
  path = "$LIB/opt"
TOMLEOF
sudo sh -c "setsid nohup env PATH='$LIB/bin:'\"\$PATH\" '$LIB/bin/containerd' --config '$LIB/containerd.toml' >'$RUN/containerd.log' 2>&1 </dev/null & echo \$! > '$RUN/containerd.pid'"
CTR="sudo $LIB/bin/ctr -a $SOCK"
for _ in $(seq 1 40); do
    [ -S "$SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
$CTR version >/dev/null 2>&1 || { echo "[setup] ERROR: containerd does not answer ($(sudo tail -c 300 "$RUN/containerd.log"))"; exit 1; }
grep -q 'address="127.0.0.1:8080"' "$RUN/containerd.log" || { echo "[setup] ERROR: containerd does not serve 127.0.0.1:8080"; exit 1; }

echo "[setup] an offline one-file image and two containers made with ctr (never started): '$NS' holds the"
echo "[setup] container to find, namespace 'default' holds a decoy; both have a random id and a nonce in a label..."
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, tag, arch = sys.argv[1:4]
layer = io.BytesIO()
with tarfile.open(fileobj=layer, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    ti = tarfile.TarInfo("x")
    ti.size, ti.mode, ti.mtime = 1, 0o755, 0
    lt.addfile(ti, io.BytesIO(b"x"))
layer = layer.getvalue()
diff = hashlib.sha256(layer).hexdigest()
cfg = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z", "config": {"Entrypoint": ["/x"]},
                  "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff]}}, sort_keys=True).encode()
cid = hashlib.sha256(cfg).hexdigest()
man = json.dumps([{"Config": cid + ".json", "RepoTags": [tag], "Layers": [diff + "/layer.tar"]}]).encode()


def add(t, n, p):
    ti = tarfile.TarInfo(n)
    ti.size, ti.mode, ti.mtime = len(p), 0o644, 0
    t.addfile(ti, io.BytesIO(p))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff + "/layer.tar", layer)
    add(t, cid + ".json", cfg)
    add(t, "manifest.json", man)
PYEOF
IMAGE="docker.io/library/$CASE_ID:1"
python3 "$BUILD/mkimage.py" "$BUILD/img.tar" "$IMAGE" "$KARCH"
for n in "$NS" default; do $CTR -n "$n" images import "$BUILD/img.tar" >/dev/null; done
CID=$CASE_ID-$(python3 -c 'import secrets; print(secrets.token_hex(4))'); NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
DID=$CASE_ID-decoy-$(python3 -c 'import secrets; print(secrets.token_hex(4))'); DNONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
$CTR -n "$NS" containers create --label "bench/nonce=$NONCE" "$IMAGE" "$CID" >/dev/null
$CTR -n default containers create --label "bench/nonce=$DNONCE" "$IMAGE" "$DID" >/dev/null
echo "  -> $CID in $NS, decoy $DID in default"

echo "[setup] recording the state (root-only): ids, nonces, the hashes of what the solution must not change..."
sudo python3 - "$STATE_DIR" "$CID" "$NONCE" "$DID" "$DNONCE" "$IMAGE" "$NS" "$LIB" "$RUN" "$WORK_DIR" <<'PYEOF'
import hashlib, json, os, sys

state, cid, nonce, did, dnonce, image, ns, lib, run, work = sys.argv[1:11]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()


def starttime(pid):
    s = open("/proc/%s/stat" % pid).read()
    return int(s[s.rindex(")") + 2:].split()[19])


pid = int(open(run + "/containerd.pid").read())
json.dump({"cid": cid, "nonce": nonce, "decoy_id": did, "decoy_nonce": dnonce, "image": image, "ns": ns,
           "containerd_pid": pid, "containerd_start": starttime(pid), "config_sha": sha(lib + "/containerd.toml"),
           "grpcurl_sha": sha(lib + "/bin/grpcurl"), "wrapper_sha": sha(work + "/bin/grpcurl"), "proto_sha": sha(work + "/proto/containers.proto")},
          open(state + "/state.json", "w"), indent=1)
os.chmod(state + "/state.json", 0o600)
PYEOF
echo "[setup] done. containerd serves its socket $SOCK and the TCP address 127.0.0.1:8080; nothing else is made."
