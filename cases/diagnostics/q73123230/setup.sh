#!/bin/bash
set -e

CASE_ID="bench73123230"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # state, socket, pid file and log of the node's containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (not in /run: it is mounted noexec on many hosts)
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_STATE="$RUN_BASE/containerd"
T_ROOT="$LIB_BASE/containerd"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
FB_DIR="$WORK_DIR/fluent-bit"         # what the solution writes (pipeline.conf, parsers.conf) and the lab's main.conf
APP_REF="$CASE_ID.local/app:1"        # the image of the workload
PAUSE_REF="$CASE_ID.local/pause:1"    # the sandbox ("pause") image of the pod
COLLECTOR_PORT=19873                  # the lab's local JSON collector (main.conf's output points at it)

# The pinned Fluent Bit. It is downloaded once from the official apt repository of the project, its checksum is verified against the repository's
# index, and it is unpacked (not installed) under FB_CACHE, which cleanup.sh keeps (like crictl in /usr/local/bin). To use a binary of your own,
# set FLUENT_BIT_BIN to its path; to pin another version, set BENCH_FLUENT_BIT_VERSION.
FB_VERSION="${BENCH_FLUENT_BIT_VERSION:-3.2.10}"
FB_REPO="https://packages.fluentbit.io/ubuntu"
FB_CACHE="/var/cache/$CASE_ID"

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
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (tiny static programs, so nothing has to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] ensuring crictl is installed (the CRI client; same pinned version as the other containerd cases)..."
if ! command -v crictl >/dev/null 2>&1; then
    echo "[setup] crictl not found, downloading $CRICTL_VERSION..."
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
crictl --version

echo "[setup] ensuring the pinned Fluent Bit is there..."
FLB=""
if [ -n "$FLUENT_BIT_BIN" ]; then
    [ -x "$FLUENT_BIT_BIN" ] || { echo "[setup] ERROR: FLUENT_BIT_BIN=$FLUENT_BIT_BIN is not an executable"; exit 1; }
    FLB="$FLUENT_BIT_BIN"
else
    ARCH=$(dpkg --print-architecture)
    FB_ROOT="$FB_CACHE/$FB_VERSION-$ARCH"
    if [ -x "$FB_ROOT/opt/fluent-bit/bin/fluent-bit" ] && "$FB_ROOT/opt/fluent-bit/bin/fluent-bit" --version 2>/dev/null | grep -q "v$FB_VERSION"; then
        FLB="$FB_ROOT/opt/fluent-bit/bin/fluent-bit"
    else
        . /etc/os-release
        TMP=$(mktemp -d)
        DEB=""
        for cn in "$VERSION_CODENAME" noble jammy; do
            [ -n "$cn" ] || continue
            curl -fsSL -m 90 "$FB_REPO/$cn/dists/$cn/main/binary-$ARCH/Packages" -o "$TMP/Packages" 2>/dev/null \
                || { curl -fsSL -m 90 "$FB_REPO/$cn/dists/$cn/main/binary-$ARCH/Packages.gz" -o "$TMP/Packages.gz" 2>/dev/null && gunzip -f "$TMP/Packages.gz"; } \
                || continue
            PICK=$(python3 - "$TMP/Packages" "$FB_VERSION" <<'PYEOF'
import sys

stanzas = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n\n")
rows = []
for st in stanzas:
    f = dict(l.split(": ", 1) for l in st.split("\n") if ": " in l and not l.startswith(" "))
    if f.get("Package") == "fluent-bit":
        rows.append(f)
for f in rows:
    if f.get("Version") == sys.argv[2]:
        print(f["Filename"], f["SHA256"])
        sys.exit(0)
sys.stderr.write("versions in this index: %s\n" % ", ".join(sorted({f.get("Version", "?") for f in rows})[:40]))
sys.exit(1)
PYEOF
            ) && { DEB="$cn $PICK"; break; } || echo "[setup] Fluent Bit $FB_VERSION is not in the index of $cn"
        done
        [ -n "$DEB" ] || { echo "[setup] ERROR: could not find Fluent Bit $FB_VERSION in $FB_REPO (set BENCH_FLUENT_BIT_VERSION to a version listed above)"; rm -rf "$TMP"; exit 1; }
        set -- $DEB
        echo "[setup] downloading $FB_REPO/$1/$2 ..."
        curl -fsSL -m 600 "$FB_REPO/$1/$2" -o "$TMP/fb.deb" || { echo "[setup] ERROR: could not download the Fluent Bit package"; rm -rf "$TMP"; exit 1; }
        echo "$3  $TMP/fb.deb" | sha256sum -c - >/dev/null || { echo "[setup] ERROR: the checksum of the package does not match the repository's index"; rm -rf "$TMP"; exit 1; }
        sudo rm -rf "$FB_ROOT"
        sudo mkdir -p "$FB_ROOT"
        sudo dpkg-deb -x "$TMP/fb.deb" "$FB_ROOT"
        if sudo ldd "$FB_ROOT/opt/fluent-bit/bin/fluent-bit" 2>&1 | grep -q "not found"; then
            echo "[setup] libraries the package depends on are missing; installing the package with apt to get them..."
            sudo -E apt-get update -qq
            sudo -E apt-get install -y -qq "${APT_OPTS[@]}" "$TMP/fb.deb"
        fi
        rm -rf "$TMP"
        FLB="$FB_ROOT/opt/fluent-bit/bin/fluent-bit"
    fi
fi
"$FLB" --version 2>&1 | head -1 | grep -q "Fluent Bit" || { echo "[setup] ERROR: $FLB does not run"; exit 1; }
"$FLB" --version 2>&1 | head -1

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$FB_DIR/bin" "$WORK_DIR/logs" "$WORK_DIR/data"
chmod 755 "$WORK_DIR" "$STATE_DIR" "$FB_DIR"
sudo mkdir -p "$RUN_BASE" "$T_STATE" "$T_ROOT"
echo "$FLB" > "$STATE_DIR/flb.path"
ln -s "$FLB" "$FB_DIR/bin/fluent-bit"
cp "$CASE_DIR"/helpers/{patch_config.py,mkimg.py,lab.py,verify.py,collector.py,flb.sh,naive.conf,naive-parsers.conf,main.conf,app.c,pause.c} "$STATE_DIR/"
cp "$STATE_DIR/main.conf" "$FB_DIR/main.conf"
echo "# parser definitions: the solution writes them here" > "$FB_DIR/parsers.conf"
cd "$WORK_DIR"

echo "[setup] compiling the programs of the images: the workload (a logger that writes one line per call) and the sandbox program..."
for p in app pause; do
    gcc -static -Os -s -w -o "$STATE_DIR/$p-bin" "$STATE_DIR/$p.c"
done

echo "[setup] the default containerd configuration of the installed version, for this node (own root, state and socket, NRI off, local sandbox image)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$T_ROOT" "$T_STATE" "$T_SOCK" "$LIB_BASE/cni" "$PAUSE_REF" \
    > "$STATE_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the containerd config"; exit 1; }
grep -q "max_container_log_line_size = 16384\$" "$STATE_DIR/containerd.toml" || { echo "[setup] ERROR: this containerd does not have the default max_container_log_line_size = 16384"; exit 1; }
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py collector.py flb.sh naive.conf naive-parsers.conf main.conf app.c pause.c | awk '{print $1}' > helpers.sha)
sha256sum "$FB_DIR/main.conf" | awk '{print $1}' > "$STATE_DIR/main.conf.sha"
sha256sum "$FB_DIR/parsers.conf" | awk '{print $1}' > "$STATE_DIR/parsers.conf.sha"

echo "[setup] starting the node's containerd (own socket $T_SOCK, own root and state)..."
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$STATE_DIR/containerd.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
UP=""
for _ in $(seq 1 80); do
    if [ -S "$T_SOCK" ] && "${CRI[@]}" version >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the node's containerd did not come up:"; sudo tail -5 "$RUN_BASE/containerd.log" | cut -c1-300; exit 1; }

echo "[setup] importing the two images into the 'k8s.io' namespace (the sandbox image and the image of the workload)..."
for pair in "pause:$PAUSE_REF" "app:$APP_REF"; do
    k=${pair%%:*}; ref=${pair#*:}
    python3 "$STATE_DIR/mkimg.py" "$ref" "$STATE_DIR/$k-bin" "$STATE_DIR/$k.tar" >/dev/null
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

echo "[setup] starting the lab's local JSON collector on 127.0.0.1:$COLLECTOR_PORT..."
if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1', $COLLECTOR_PORT)) == 0 else 1)"; then
    echo "[setup] ERROR: something already listens on 127.0.0.1:$COLLECTOR_PORT"; exit 1
fi
setsid -f python3 "$STATE_DIR/collector.py" "$COLLECTOR_PORT" "$STATE_DIR/records.jsonl" </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 20); do
    if python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:$COLLECTOR_PORT/', timeout=2).read()" >/dev/null 2>&1; then UP=1; break; fi
    sleep 0.25
done
[ -n "$UP" ] || { echo "[setup] ERROR: the collector did not come up"; exit 1; }

echo "[setup] one pod with two real CRI containers that log multi-line application events, line by line (alpha on stdout, beta on stderr)..."
python3 "$STATE_DIR/lab.py" up "$T_SOCK" "$WORK_DIR" || { echo "[setup] ERROR: the workloads did not come up"; exit 1; }
echo "  -> the CRI log files are in $WORK_DIR/logs (alpha_0.log, beta_0.log)"

echo "[setup] removing the build inputs the solution has no business with (the programs, the image generator)..."
rm -f "$STATE_DIR/app-bin" "$STATE_DIR/pause-bin"

echo "[setup] done. The pipeline is not written yet: $FB_DIR has the lab's main.conf, a parsers.conf with a comment only and no pipeline.conf."
