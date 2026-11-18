#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench59759658"
RUN_BASE="/run/$CASE_ID"            # the node's containerd: socket, config, pid (BuildKit's socket is meant to be here too)
LIB_BASE="/var/lib/$CASE_ID"        # the node's containerd data, the tools (bin), the CNI plugins (cni), nerdctl's data root
CACHE="/var/cache/$CASE_ID"         # pinned downloads (kept by cleanup, sha256 checked at every setup)
WORK_DIR="/tmp/$CASE_ID"            # what the job has: the wrappers and the compose project
STATE_DIR="$WORK_DIR/.bench"        # root-only record of what is true
SOCK="$RUN_BASE/containerd.sock"
PROJECT="$WORK_DIR/app"
IMAGE="$CASE_ID-web:local"
NERDCTL_V="2.1.6"; BUILDKIT_V="v0.23.2"; CNI_V="v1.6.2"; COMPOSE_V="v2.35.1"

case "$(uname -m)" in
    x86_64|amd64)  A="amd64"; COMPOSE_ARCH="x86_64"
        SHA_NERDCTL="22857b373edea479a4534ba62cae1c77f2af38f0aac4c91c1c68cf09e29d6f9e"; SHA_BUILDKIT="2771c3403e3a1f75a83cde387a05365794d3b900c355e864772a36c3ce541f82"
        SHA_CNI="b8e811578fb66023f90d2e238d80cec3bdfca4b44049af74c374d4fae0f9c090"; SHA_COMPOSE="7bdb2ce2916e5dd0354e5d129892bf96fdcdb1a9ab8eed69b9173e131db4c230" ;;
    aarch64|arm64) A="arm64"; COMPOSE_ARCH="aarch64"
        SHA_NERDCTL="5c30be3ec118eb222bf635f8049c2f96b4c46d9343ec445058e9bc2ee9531c28"; SHA_BUILDKIT="6385ff70b2fb4134b50ac3183eea3a0b06c6f6129173940d73178ae0477368f1"
        SHA_CNI="01e0e22acc7f7004e4588c1fe1871cc86d7ab562cd858e1761c4641d89ebfaa4"; SHA_COMPOSE="a91e930a076b91e6c69f11d1dbe3c06729ae765fb9dbb3f97cb808e784647399" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m) (the pinned tools exist for x86_64 and aarch64)"; exit 1 ;;
esac
# name | url | sha256
DOWNLOADS=(
"nerdctl-$NERDCTL_V-$A.tgz|https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_V/nerdctl-$NERDCTL_V-linux-$A.tar.gz|$SHA_NERDCTL"
"buildkit-$BUILDKIT_V-$A.tgz|https://github.com/moby/buildkit/releases/download/$BUILDKIT_V/buildkit-$BUILDKIT_V.linux-$A.tar.gz|$SHA_BUILDKIT"
"cni-plugins-$CNI_V-$A.tgz|https://github.com/containernetworking/plugins/releases/download/$CNI_V/cni-plugins-linux-$A-$CNI_V.tgz|$SHA_CNI"
"docker-compose-$COMPOSE_V-$A|https://github.com/docker/compose/releases/download/$COMPOSE_V/docker-compose-linux-$COMPOSE_ARCH|$SHA_COMPOSE"
)

echo "[setup] checking what the case needs is installed (containerd and runc of this host are the runtime under test)..."
for c in containerd ctr runc python3 curl sudo sha256sum tar; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
containerd --version | head -1; runc --version | head -1
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] the tools (nerdctl $NERDCTL_V, BuildKit $BUILDKIT_V, CNI plugins $CNI_V, docker-compose $COMPOSE_V; $A): from $CACHE, else downloaded from GitHub; the sha256 is checked either way..."
sudo install -d -m 0755 "$CACHE"
for d in "${DOWNLOADS[@]}"; do
    IFS='|' read -r name url sha <<< "$d"
    if sudo test -f "$CACHE/$name" && echo "$sha  $CACHE/$name" | sudo sha256sum -c --quiet - 2>/dev/null; then continue; fi
    ok=""
    for _ in 1 2 3 4; do
        tmp=$(mktemp)
        if curl -fsSL --max-time 600 -o "$tmp" "$url" && echo "$sha  $tmp" | sha256sum -c --quiet - 2>/dev/null; then sudo install -m 0644 "$tmp" "$CACHE/$name"; ok=1; rm -f "$tmp"; break; fi
        rm -f "$tmp"; sleep 3
    done
    [ -n "$ok" ] || { echo "[setup] ERROR: could not download $name with the pinned sha256"; exit 1; }
done

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/bin" "$LIB_BASE/cni" "$LIB_BASE/cni-empty" "$LIB_BASE/data" "$LIB_BASE/nerdctl" "$LIB_BASE/cni-conf"
mkdir -p "$WORK_DIR/bin" "$PROJECT"
sudo install -d -m 0700 "$STATE_DIR"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
tar xzf "$CACHE/nerdctl-$NERDCTL_V-$A.tgz" -C "$BUILD" nerdctl
tar xzf "$CACHE/buildkit-$BUILDKIT_V-$A.tgz" -C "$BUILD"
sudo install -m 0755 "$BUILD/nerdctl" "$LIB_BASE/bin/nerdctl"
for b in buildkitd buildctl buildkit-runc; do sudo install -m 0755 "$BUILD/bin/$b" "$LIB_BASE/bin/$b"; done
sudo install -m 0755 "$CACHE/docker-compose-$COMPOSE_V-$A" "$LIB_BASE/bin/docker-compose"
sudo tar xzf "$CACHE/cni-plugins-$CNI_V-$A.tgz" -C "$LIB_BASE/cni" --no-same-owner
sudo chmod -R a+rX "$LIB_BASE"

# what exists on the host now, so that cleanup removes only what the case (or a solution) made
sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
[ -d /run/containerd ] || echo "NOEXIST" | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
pgrep -x buildkitd 2>/dev/null | sudo tee "$LIB_BASE/buildkitd.base" >/dev/null || true
for d in /run/buildkit /var/lib/buildkit; do [ -e "$d" ] || echo "$d" | sudo tee -a "$LIB_BASE/created_dirs" >/dev/null; done
sudo touch "$LIB_BASE/created_dirs"

echo "[setup] the application: a static program that prints one line with the nonce of this run, read from /nonce.txt, once a second; the compose project is ($PROJECT): a Dockerfile (FROM scratch), the compose file with a build: section, nonce.txt and the program..."
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
cat > "$BUILD/app.c" <<'CEOF'
#include <stdio.h>
#include <string.h>
#include <time.h>

int main(void) {
    char nonce[128] = "unknown";
    FILE *f = fopen("/nonce.txt", "r");
    if (f) { if (fgets(nonce, sizeof nonce, f)) nonce[strcspn(nonce, "\n")] = 0; fclose(f); }
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        printf("bench59759658-ok nonce=%s\n", nonce);
        fflush(stdout);
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
    }
}
CEOF
gcc -static -Os -s -o "$PROJECT/app" "$BUILD/app.c"
echo "$NONCE" > "$PROJECT/nonce.txt"
cat > "$PROJECT/Dockerfile" <<'DEOF'
FROM scratch
ARG BUILT_BY
LABEL bench59759658.built-by=$BUILT_BY
COPY nonce.txt /nonce.txt
COPY app /app
ENTRYPOINT ["/app"]
DEOF
cat > "$PROJECT/compose.yaml" <<YEOF
services:
  web:
    container_name: $CASE_ID-web
    image: $IMAGE
    build:
      context: .
      args:
        BUILT_BY: compose-$NONCE
    network_mode: none
YEOF
touch -d '2020-01-01 00:00:00' "$PROJECT/app" "$PROJECT/nonce.txt" "$PROJECT/Dockerfile" "$PROJECT/compose.yaml"
chmod -R a+rX "$PROJECT"
echo "$NONCE" | sudo tee "$STATE_DIR/nonce" >/dev/null

echo "[setup] the node (the pipeline's machine): a private containerd with its own socket $SOCK and its own data, nothing else of this host's is touched..."
cat > "$BUILD/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
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
    elif (section == "grpc" or "server.v1.grpc" in section) and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif (section == "ttrpc" or "server.v1.ttrpc" in section) and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF
sudo mkdir -p "$RUN_BASE"
containerd config default | python3 "$BUILD/patch_config.py" "$LIB_BASE/data" "$RUN_BASE" "$SOCK" | sudo tee "$RUN_BASE/config.toml" >/dev/null
sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$RUN_BASE" </dev/null >/dev/null 2>&1
for _ in $(seq 1 40); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the node's containerd did not come up; last log lines:"; sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null; exit 1; }
echo "  -> the node's containerd is up (pid $(sudo cat "$RUN_BASE/containerd.pid"))"

echo "[setup] the two tools of the job in $WORK_DIR/bin (run them as the current user; they call sudo themselves): 'nerdctl' is nerdctl pointed at the node's containerd, with its own data root and CNI config dir, and told that BuildKit is at $RUN_BASE/buildkitd.sock; 'docker-compose' is docker-compose $COMPOSE_V, which looks for a Docker API at $RUN_BASE/docker.sock (there is none on this node)..."
cat > "$WORK_DIR/bin/nerdctl" <<REOF
#!/bin/sh
# nerdctl for the node: its containerd, its data root, its CNI config dir; BuildKit is expected at $RUN_BASE/buildkitd.sock;
# CNI_PATH (where nerdctl looks for the CNI plugins) is what the caller sets, by default a directory without plugins (this host's /opt/cni/bin is not the node's)
exec sudo env PATH=$LIB_BASE/bin:/usr/sbin:/usr/bin:/sbin:/bin BUILDKIT_HOST=unix://$RUN_BASE/buildkitd.sock CNI_PATH="\${CNI_PATH:-$LIB_BASE/cni-empty}" $LIB_BASE/bin/nerdctl --address $SOCK --data-root $LIB_BASE/nerdctl --cni-netconfpath $LIB_BASE/cni-conf "\$@"
REOF
cat > "$WORK_DIR/bin/docker-compose" <<REOF
#!/bin/sh
# docker-compose for a machine that has no Docker: its Docker API socket does not exist
DOCKER_HOST=unix://$RUN_BASE/docker.sock exec $LIB_BASE/bin/docker-compose "\$@"
REOF
chmod 0755 "$WORK_DIR/bin/nerdctl" "$WORK_DIR/bin/docker-compose"

echo "[setup] recording the state (root-only): the node's containerd (process, configs) and the hashes of the tools, wrappers and project files..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" RUN_BASE="$RUN_BASE" python3 - <<'PYEOF'
import glob, hashlib, json, os

E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
pid = int(open(E["RUN_BASE"] + "/containerd.pid").read())
start = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
files = sorted(glob.glob(E["LIB_BASE"] + "/bin/*")) + sorted(glob.glob(E["LIB_BASE"] + "/cni/*")) + sorted(glob.glob(E["WORK_DIR"] + "/bin/*")) + sorted(glob.glob(E["WORK_DIR"] + "/app/*")) + [E["RUN_BASE"] + "/config.toml"]
d = {"pid": pid, "start": start, "files": {f: sha(f) for f in files if os.path.isfile(f)}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The node has containerd only (no Docker, no BuildKit running); the compose project is $PROJECT."
