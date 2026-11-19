#!/bin/bash
set -e

WORK_DIR="/tmp/bench72183367"
K="$WORK_DIR/bin/k"
REG_HOST="127.0.0.1:15183"
NS="default"

# the credentials of the registry: what an engineer would do with 'docker login', but as a Kubernetes Secret, which is what
# the kubelet hands to CRI-O when it pulls (CRI-O does not read Kubernetes Secrets itself)
. <(sed 's/^/CRED_/' "$WORK_DIR/registry.cred")

echo "[solution] creating the Secret regcred (type kubernetes.io/dockerconfigjson) with the credentials of $REG_HOST in namespace $NS..."
"$K" -n "$NS" delete secret regcred --ignore-not-found >/dev/null
"$K" -n "$NS" create secret docker-registry regcred \
    --docker-server="$REG_HOST" --docker-username="$CRED_username" --docker-password="$CRED_password"

echo "[solution] imagePullSecrets of a pod cannot be changed once it exists: recreating the pod app with the Secret..."
"$K" -n "$NS" delete pod app --wait=true --ignore-not-found >/dev/null
{ cat "$WORK_DIR/pod.yaml"; printf '  imagePullSecrets:\n  - name: regcred\n'; } | "$K" apply -f - >/dev/null

echo "[solution] waiting for the pod app to run..."
for _ in $(seq 1 40); do
    [ "$("$K" -n "$NS" get pod app -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 2
done
"$K" -n "$NS" get pod app
