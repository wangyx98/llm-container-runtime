#!/bin/bash
# The pods and containers of a CRI node are kept in the containerd namespace "k8s.io"; plain `ctr` looks at the namespace "default", which is empty.
# crictl is the CRI client and shows the CRI view: `crictl ps -a` all containers, `crictl images` the images, `crictl exec` runs a command inside a
# container as the user the container was configured to run as (not as root). The node's containerd is not at the default socket, so the endpoint
# is given. The three names (namespace, pod, container) are the labels the CRI puts on every container.
set -e
cat > /tmp/bench71705752/inspect-node.sh <<'SCRIPT'
#!/bin/bash
# inspect-node.sh POD_NAMESPACE POD_NAME CONTAINER_NAME OUTPUT_DIR
set -e
SOCK=/run/bench71705752/containerd/containerd.sock
CRI=(sudo crictl --runtime-endpoint "unix://$SOCK" --image-endpoint "unix://$SOCK")
ns=$1 pod=$2 name=$3 out=$4
mkdir -p "$out"

"${CRI[@]}" ps -a -q --no-trunc > "$out/containers.txt"
"${CRI[@]}" images --no-trunc | awk 'NR > 1 { print $1 ":" $2 }' > "$out/images.txt"

id=$("${CRI[@]}" ps -a -q --no-trunc \
        --label "io.kubernetes.pod.namespace=$ns" --label "io.kubernetes.pod.name=$pod" --label "io.kubernetes.container.name=$name")
[ "$(printf '%s\n' "$id" | grep -c .)" = 1 ] || { echo "no single container $ns/$pod/$name" >&2; exit 1; }

"${CRI[@]}" exec "$id" /bin/cat /data/token.txt > "$out/token.txt"
"${CRI[@]}" exec "$id" /bin/id -u > "$out/uid.txt"
SCRIPT
chmod +x /tmp/bench71705752/inspect-node.sh

bash /tmp/bench71705752/inspect-node.sh prod rabbitmq-0 rabbitmq /tmp/bench71705752/out
