#!/bin/bash
set -e

CASE_ID="bench77044676"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
DEMO_DIR="$LIB_BASE/demo"
CERTS="$LIB_BASE/certs.d"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NODE="bench77044676-node"
DEPLOY="flask-proj-deployment"
IMAGE="docker.io/library/flaskapp:v1"

KC="sudo $CTL_DIR/kubectl"
CTR="sudo $CTL_DIR/ctr"
CRICTL="sudo $CTL_DIR/crictl"

fail() { echo "  -> FAIL: $*"; exit 1; }
rec() { sudo cat "$STATE_DIR/$1"; }

sudo test -f "$STATE_DIR/pod.uid" || fail "the record of the lab is missing (setup did not run)"
MANIFEST="$(rec manifest.digest)"; CONFIG="$(rec config.digest)"
POD_UID="$(rec pod.uid)"; POD_NAME="$(rec pod.name)"

echo "[precondition] the node as recorded: containerd answers, the node is Ready and the original one, the files are untouched..."
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on its socket"
[ "$($KC get node "$NODE" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$(rec node.uid)" ] || fail "the Kubernetes API does not answer or the node is not the original one"
[ "$($KC get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ] || fail "the node is not Ready"
NOW="$(sudo sh -c 'cd /; sha256sum "$@" | awk "{print \$1}"' _ "$RUN_BASE/config.toml" "$CERTS/docker.io/hosts.toml" "$K3S_CONFIG" "$DEMO_DIR/flaskapp.tar" "$DEMO_DIR/deployment.yaml")"
[ "$NOW" = "$(rec files.sha)" ] || fail "a file of the lab was changed"
echo "  -> OK"

echo "[precondition] the three views of the image: ctr in the namespace the engineer used (default) shows it, the namespace k8s.io and the CRI (crictl images, what the kubelet asks) do not..."
[ "$($CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1 == r {print $3}')" = "$MANIFEST" ] || fail "ctr (namespace default) does not hold $IMAGE with the recorded manifest"
echo "  ctr -n default : $IMAGE $MANIFEST"
[ -z "$($CTR -n k8s.io images ls 2>/dev/null | awk -v r="$IMAGE" '$1 == r {print $1}')" ] || fail "ctr -n k8s.io already holds $IMAGE"
echo "  ctr -n k8s.io  : (no $IMAGE)"
$CRICTL images 2>/dev/null | grep -q 'docker.io/library/flaskapp' && fail "the CRI already lists flaskapp"
echo "  crictl images  : (no flaskapp)"
echo "  -> OK"

echo "[precondition] the Pod: the original one of the Deployment, waiting in ErrImagePull or ImagePullBackOff because the kubelet looked in the CRI, found nothing and tried docker.io; the Deployment is as the engineer wrote it..."
[ "$($KC get deployment "$DEPLOY" -o jsonpath='{.metadata.generation}')" = "$(rec deploy.generation)" ] || fail "the Deployment was changed"
[ "$($KC get deployment "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[*].image}|{.spec.template.spec.containers[*].imagePullPolicy}|{.spec.replicas}')" = "$IMAGE|IfNotPresent|1" ] || fail "the Deployment is not as the engineer wrote it"
[ "$($KC get pod "$POD_NAME" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$POD_UID" ] || fail "the original Pod is gone"
WAITING="$($KC get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')"
case "$WAITING" in ErrImagePull|ImagePullBackOff) ;; *) fail "the Pod does not wait for its image (state: '$WAITING')" ;; esac
$KC describe pod "$POD_NAME" 2>/dev/null | grep -q 'Failed to pull image.*127.0.0.1:9' || fail "the Pod's events do not show a failed pull from docker.io"
echo "  Pod $POD_NAME: $WAITING, the pull from docker.io failed"
echo "  -> OK"

echo "[precondition] controls: a pull from outside is impossible (crictl pull $IMAGE fails); an image that was put into k8s.io with ctr is seen by the CRI (the sandbox image of the pods)..."
$CRICTL pull "$IMAGE" >/dev/null 2>&1 && fail "crictl pull $IMAGE worked: docker.io is reachable"
$CTR -n k8s.io images ls -q 2>/dev/null | grep -q '^bench77044676.local/pause:1$' || fail "the sandbox image is not in k8s.io"
$CRICTL images 2>/dev/null | grep -q 'bench77044676.local/pause' || fail "the CRI does not list an image that ctr put into k8s.io"
[ "$($KC get pod "$POD_NAME" -o jsonpath='{.metadata.uid}')" = "$POD_UID" ] || fail "the Pod changed during the controls"
echo "  -> OK"

echo "[precondition] control: the oracle says FAIL while nothing is fixed..."
OUT="$(BENCH77044676_WAIT=10 bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed before any fix"
echo "$OUT" | grep -q 'does not list' || { echo "$OUT" | tail -3; fail "the oracle failed for another reason"; }
echo "  -> OK"

echo "[precondition] PASS - the image is in ctr's default namespace only and the Pod cannot start; no pull from outside is possible."
