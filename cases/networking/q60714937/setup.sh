#!/bin/bash
set -e

CASE_ID="bench60714937"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
LIB_BASE="/var/lib/$CASE_ID"          # the kind binary
CACHE_DIR="/var/cache/$CASE_ID"       # the downloaded kind binary (kept by cleanup.sh)
DOCKER_MARKER="$LIB_BASE/docker_started_by_case"   # exists when this case started the (stopped) docker service: cleanup.sh stops it again
GW="10.249.60.1"                      # the gateway of the Docker network of the cluster = this machine = the registry
KIND_VERSION="v0.30.0"
# kindest/node v1.34.0, the image of the release notes of kind v0.30.0 (a different one can be given in BENCH60714937_NODE_IMAGE, always with its digest)
NODE_IMAGE="${BENCH60714937_NODE_IMAGE:-kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a}"
case "$(uname -m)" in
    x86_64|amd64)   KIND_ARCH="amd64"; KIND_SHA="517ab7fc89ddeed5fa65abf71530d90648d9638ef0c4cde22c2c11f8097b8889" ;;
    aarch64|arm64)  KIND_ARCH="arm64"; KIND_SHA="7ea2de9d2d190022ed4a8a4e3ac0636c8a455e460b9a13ccf19f15d07f4f00eb" ;;
    *)              echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking python3, curl and the docker client (kind runs the nodes as Docker containers)..."
for b in python3 curl docker; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] a running Docker daemon: if none answers, the docker service is started, and if that fails a dockerd of the lab (cleanup.sh stops what was started)..."
START_ERR=""
if ! sudo docker info >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl start docker.socket >/dev/null 2>&1 || true
        START_ERR=$(sudo systemctl start docker.service 2>&1 | tr '\n' ' ' | cut -c1-110)
        for _ in $(seq 1 40); do sudo docker info >/dev/null 2>&1 && break; sleep 1; done
        if sudo docker info >/dev/null 2>&1; then
            sudo mkdir -p "$LIB_BASE"
            sudo touch "$DOCKER_MARKER"
            echo "  -> the docker service was started by this case"
        fi
    fi
fi
PRIV_ERR=""
if ! sudo docker info >/dev/null 2>&1; then
    echo "  -> the docker service does not come up: starting a dockerd of the lab (own containerd, default socket)..."
    PRIV_ERR=$(bash "$CASE_DIR/helpers/start-docker.sh" 2>&1 | tail -3 | tr '\n' ' ' | cut -c1-200)
fi
if ! sudo docker info >/dev/null 2>&1; then
    # the harness shows only the last 300 characters of this output: the reason goes last, in one short line
    st() { echo "$(systemctl is-enabled "$1" 2>&1 | head -1)/$(systemctl is-active "$1" 2>&1 | head -1)"; }
    echo "[setup] ERROR: no Docker daemon. systemctl start docker said: '${START_ERR:-nothing}'; docker.service $(st docker.service), docker.socket $(st docker.socket), containerd.service $(st containerd.service); journal: $(sudo journalctl -u docker.service -n 1 --no-pager -o cat 2>/dev/null | cut -c1-90); own dockerd: ${PRIV_ERR:-not tried}"
    exit 1
fi

echo "[setup] making sure gcc is available (a tiny static program, so the image needs nothing to be downloaded)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] kind $KIND_VERSION ($KIND_ARCH): the release binary, sha256 checked, cached in $CACHE_DIR..."
sudo mkdir -p "$CACHE_DIR" "$LIB_BASE/bin"
KIND_CACHED="$CACHE_DIR/kind-$KIND_VERSION-$KIND_ARCH"
if ! { [ -f "$KIND_CACHED" ] && echo "$KIND_SHA  $KIND_CACHED" | sha256sum -c - >/dev/null 2>&1; }; then
    sudo curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$KIND_ARCH" -o "$KIND_CACHED.part" \
        || { echo "[setup] ERROR: could not download kind $KIND_VERSION"; exit 1; }
    echo "$KIND_SHA  $KIND_CACHED.part" | sudo sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the sha256 of the downloaded kind is not the pinned one"; sudo rm -f "$KIND_CACHED.part"; exit 1; }
    sudo mv "$KIND_CACHED.part" "$KIND_CACHED"
fi
sudo install -m 755 "$KIND_CACHED" "$LIB_BASE/bin/kind"
"$LIB_BASE/bin/kind" version

echo "[setup] the node image $NODE_IMAGE (pinned by digest)..."
if ! sudo docker image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
    sudo docker pull "$NODE_IMAGE" || { echo "[setup] ERROR: could not pull $NODE_IMAGE (set BENCH60714937_NODE_IMAGE to a kindest/node image with its digest if this digest is gone)"; exit 1; }
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$WORK_DIR/store"
chmod 755 "$WORK_DIR" "$STATE_DIR"
echo "$NODE_IMAGE" > "$WORK_DIR/node-image.txt"
cp "$CASE_DIR"/helpers/{mkoci.py,registry.py,lab.py,verify.py,create-cluster.sh,app.c} "$STATE_DIR/"
cp "$CASE_DIR/helpers/create-cluster.sh" "$WORK_DIR/create-cluster.sh"
chmod 755 "$WORK_DIR/create-cluster.sh"

echo "[setup] the Docker network $CASE_ID (10.249.60.0/24, gateway $GW: this machine, where the registry listens)..."
sudo docker network create --subnet 10.249.60.0/24 --gateway "$GW" "$CASE_ID" >/dev/null \
    || { echo "[setup] ERROR: could not create the Docker network (does 10.249.60.0/24 overlap with another network?)"; exit 1; }

echo "[setup] the image test/image:2.2.1 (a static program; a random label baked in) and the registry on $GW:5000 (plain HTTP)..."
gcc -static -Os -s -w -o "$STATE_DIR/app-bin" "$STATE_DIR/app.c"
python3 "$STATE_DIR/mkoci.py" init "$WORK_DIR/store" "$STATE_DIR/app-bin" > "$STATE_DIR/seed.json"
python3 "$STATE_DIR/mkoci.py" export "$WORK_DIR/store" 2.2.1 "$GW:5000/test/image:2.2.1" "$STATE_DIR/image-2.2.1.tar"
chmod 644 "$STATE_DIR/image-2.2.1.tar"
setsid -f bash -c 'echo $$ > "$1"; exec python3 "$2" "$3" 5000 "$4" "$5" >/dev/null 2>&1 </dev/null' \
    _ "$WORK_DIR/registry.pid" "$STATE_DIR/registry.py" "$GW" "$WORK_DIR/store" "$WORK_DIR/registry.log" </dev/null >/dev/null 2>&1
UP=""
for _ in $(seq 1 30); do
    if [ "$(curl -s --noproxy '*' -A bench60714937-lab -o /dev/null -w '%{http_code}' "http://$GW:5000/v2/" 2>/dev/null)" = 200 ]; then UP=1; break; fi
    sleep 0.5
done
[ -n "$UP" ] || { echo "[setup] ERROR: the registry does not answer on $GW:5000"; exit 1; }

echo "[setup] the cluster file (as the question has it: the HTTP mirror of the registry in a containerd patch) and the cluster: one control-plane node and two workers (a few minutes)..."
cat > "$WORK_DIR/kind-cluster.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CASE_ID
containerdConfigPatches:
- |-
  [plugins."io.containerd.cri.v1.runtime".registry.mirrors."$GW:5000"]
    endpoint = ["http://$GW:5000"]
nodes:
- role: control-plane
- role: worker
- role: worker
YAML
chmod 644 "$WORK_DIR/kind-cluster.yaml"
bash "$WORK_DIR/create-cluster.sh" || { echo "[setup] ERROR: kind could not create the cluster"; exit 1; }
chmod 644 "$WORK_DIR/kubeconfig" 2>/dev/null || true

echo "[setup] recording the lab..."
python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the record of the lab could not be written"; exit 1; }
sha256sum "$STATE_DIR"/mkoci.py "$STATE_DIR"/registry.py "$STATE_DIR"/lab.py "$STATE_DIR"/verify.py "$STATE_DIR"/create-cluster.sh "$STATE_DIR"/app.c | awk '{print $1}' > "$STATE_DIR/helpers.sha"

echo "[setup] done. kind cluster $CASE_ID (control-plane + 2 workers, file $WORK_DIR/kind-cluster.yaml, script $WORK_DIR/create-cluster.sh); registry $GW:5000 (plain HTTP) with test/image:2.2.1."
