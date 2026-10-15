#!/bin/bash
# create-cluster.sh : (re)creates the kind cluster bench60714937 from /tmp/bench60714937/kind-cluster.yaml, on the Docker network bench60714937 (the one the registry is on).
# It deletes the cluster first when it exists. Run it with bash; it needs sudo (Docker). The node image is pinned by digest.
set -e
CASE_ID="bench60714937"
KIND="/var/lib/$CASE_ID/bin/kind"
NODE_IMAGE="$(cat /tmp/$CASE_ID/node-image.txt)"
KIND_ENV="KIND_EXPERIMENTAL_DOCKER_NETWORK=$CASE_ID"

sudo docker network inspect "$CASE_ID" >/dev/null 2>&1 || sudo docker network create --subnet 10.249.60.0/24 --gateway 10.249.60.1 "$CASE_ID" >/dev/null
sudo env "$KIND_ENV" "$KIND" delete cluster --name "$CASE_ID" >/dev/null 2>&1 || true
sudo docker network inspect "$CASE_ID" >/dev/null 2>&1 || sudo docker network create --subnet 10.249.60.0/24 --gateway 10.249.60.1 "$CASE_ID" >/dev/null
sudo env "$KIND_ENV" "$KIND" create cluster --name "$CASE_ID" --image "$NODE_IMAGE" --config "/tmp/$CASE_ID/kind-cluster.yaml" --kubeconfig "/tmp/$CASE_ID/kubeconfig" --wait 240s

# create returns when the control plane is up; wait until the three nodes are Ready
for _ in $(seq 1 120); do
    READY=$(sudo docker exec "$CASE_ID-control-plane" kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
    [ "$READY" = 3 ] && break
    sleep 2
done
sudo docker exec "$CASE_ID-control-plane" kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
