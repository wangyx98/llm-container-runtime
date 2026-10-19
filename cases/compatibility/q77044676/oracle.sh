#!/bin/bash
set -e

CASE_ID="bench77044676"
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
WAIT="${BENCH77044676_WAIT:-330}"     # the kubelet retries a failed pull after at most five minutes

KC="sudo $CTL_DIR/kubectl"
CTR="sudo $CTL_DIR/ctr"
CRICTL="sudo $CTL_DIR/crictl"

fail() { echo "[oracle] FAIL: $*"; exit 1; }
rec() { sudo cat "$STATE_DIR/$1"; }
# one value out of a JSON document on stdin: jget 'expression of d'
jget() { python3 -c 'import sys, json; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

sudo test -f "$STATE_DIR/pod.uid" || fail "the record of the lab is missing (setup did not run)"
MANIFEST="$(rec manifest.digest)"; CONFIG="$(rec config.digest)"; NONCE="$(rec nonce)"
POD_UID="$(rec pod.uid)"; POD_NAME="$(rec pod.name)"

echo "[oracle] 0/6 the node and its configuration must be as they were: containerd and the Kubernetes API answer, the node is the same one and Ready, and the files nobody may change (containerd's configuration, the registry configuration that makes docker.io unreachable, k3s' configuration, flaskapp.tar, the Deployment's YAML) are unchanged..."
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on its socket"
[ "$($KC get node "$NODE" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$(rec node.uid)" ] || fail "the Kubernetes API does not answer or the node is not the original one"
[ "$($KC get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ] || fail "the node is not Ready"
[ "$($KC get node "$NODE" -o jsonpath='{.spec.unschedulable}')" = "" ] || fail "the node was cordoned"
NOW="$(sudo sh -c 'cd /; sha256sum "$@" | awk "{print \$1}"' _ "$RUN_BASE/config.toml" "$CERTS/docker.io/hosts.toml" "$K3S_CONFIG" "$DEMO_DIR/flaskapp.tar" "$DEMO_DIR/deployment.yaml")"
[ "$NOW" = "$(rec files.sha)" ] || fail "a file that must stay as it is was changed (the containerd configuration, the registry configuration, the k3s configuration, flaskapp.tar or the Deployment's YAML)"

echo "[oracle] 1/6 the Deployment must be the one of the engineer, not edited: same object and generation (a changed image, pull policy or replica count makes a new generation), image $IMAGE, imagePullPolicy IfNotPresent, one replica..."
[ "$($KC get deployment "$DEPLOY" -o jsonpath='{.metadata.uid}')" = "$(rec deploy.uid)" ] || fail "the Deployment is not the original one (deleted and made again)"
[ "$($KC get deployment "$DEPLOY" -o jsonpath='{.metadata.generation}')" = "$(rec deploy.generation)" ] || fail "the Deployment was changed (its generation moved)"
[ "$($KC get deployment "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[*].image}|{.spec.template.spec.containers[*].imagePullPolicy}|{.spec.replicas}')" = "$IMAGE|IfNotPresent|1" ] || fail "the image, the pull policy or the replica count of the Deployment is not the original one"

echo "[oracle] 2/6 the CRI of this containerd (what the kubelet asks) must list $IMAGE with the image id of the engineer's image, and the namespace k8s.io must hold the same manifest..."
CRI_ID="$($CRICTL images -o json 2>/dev/null | python3 -c '
import sys, json
for i in json.load(sys.stdin).get("images", []):
    if "'"$IMAGE"'" in i.get("repoTags", []):
        print(i["id"])
')"
[ -n "$CRI_ID" ] || fail "crictl images (the CRI) does not list $IMAGE: the kubelet cannot see the image (the namespace of the CRI is k8s.io)"
case "$CRI_ID" in "$CONFIG"|"${CONFIG#sha256:}") ;; *) fail "the CRI lists $IMAGE with the id $CRI_ID, not the engineer's image ($CONFIG)";; esac
[ "$($CTR -n k8s.io images ls 2>/dev/null | awk -v r="$IMAGE" '$1 == r {print $3}')" = "$MANIFEST" ] || fail "ctr -n k8s.io does not hold $IMAGE with the manifest $MANIFEST"

echo "[oracle] 3/6 the ORIGINAL Pod (same name, same uid, not deleted and made again) must be Running and Ready, not restarted, from the engineer's image..."
GOT=""
for _ in $(seq 1 $((WAIT / 5))); do
    GOT="$($KC get pod "$POD_NAME" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    p = json.load(sys.stdin)
except ValueError:
    print("GONE"); raise SystemExit
cs = (p["status"].get("containerStatuses") or [{}])[0]
w = (cs.get("state") or {}).get("waiting") or {}
print(p["metadata"]["uid"], p["status"].get("phase"), cs.get("ready"), cs.get("restartCount"), cs.get("imageID"), cs.get("containerID"), w.get("reason") or "-")
')"
    case "$GOT" in
        GONE|"") fail "the original Pod $POD_NAME is gone: it was deleted (or its Deployment was changed) and another Pod took over" ;;
        "$POD_UID Running True 0 "*) break ;;
    esac
    case "$GOT" in "$POD_UID "*) ;; *) fail "the Pod $POD_NAME is not the original one any more ($GOT)" ;; esac
    sleep 5
done
case "$GOT" in "$POD_UID Running True 0 "*) ;; *) fail "the original Pod did not become Running and Ready within ${WAIT}s (now: ${GOT#$POD_UID })" ;; esac
read -r _ _ _ _ IMAGE_ID CONTAINER_ID _ <<< "$GOT"
case "$IMAGE_ID" in *"${CONFIG#sha256:}"*|*"${MANIFEST#sha256:}"*) ;; *) fail "the Pod runs the image $IMAGE_ID, not the engineer's image";; esac

echo "[oracle] 4/6 the Pod's log must carry the nonce that only the engineer's image holds, and the container must still be the same one a few seconds later..."
sleep 6
$KC logs "$POD_NAME" 2>/dev/null | grep -q "bench77044676-flaskapp $NONCE port=5001" || fail "the log of the Pod does not carry the nonce of the engineer's image"
[ "$($KC get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].containerID}|{.status.containerStatuses[0].restartCount}')" = "$CONTAINER_ID|0" ] || fail "the container of the Pod was restarted"

echo "[oracle] 5/6 the image must have come from the node's own store: the Pod's events say 'already present on machine' and never 'Successfully pulled'..."
EV="$($KC get events --field-selector "involvedObject.name=$POD_NAME" -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null)"
echo "$EV" | grep -q 'already present on machine' || fail "the Pod's events do not show that the image was already on the machine"
echo "$EV" | grep -q 'Successfully pulled' && fail "the Pod's image was pulled from a registry"

echo "[oracle] 6/6 the Pod is on this node..."
[ "$($KC get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}')" = "$NODE" ] || fail "the Pod is not on the node $NODE"

echo "[oracle] ALL CHECKS PASSED: the original Pod of the Deployment runs the engineer's image, which the CRI of the node lists under $IMAGE; the Deployment and the registry configuration are unchanged."
