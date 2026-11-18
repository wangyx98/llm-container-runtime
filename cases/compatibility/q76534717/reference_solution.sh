#!/bin/bash
# The question's call goes to the TCP address 127.0.0.1:8080 of containerd, which does not serve the Containers service (it is served on containerd's own
# socket only). Use that socket (grpcurl's -unix) and give the namespace as a header, since the Containers API is per namespace and ctr's '-n k8s.io' is what
# the header carries. The proto file is needed because containerd offers no reflection.
set -e
W=/tmp/bench76534717
cat > $W/list.sh <<'LEOF'
#!/bin/bash
sudo /tmp/bench76534717/bin/grpcurl -plaintext -unix \
    -import-path /tmp/bench76534717/proto -proto containers.proto \
    -rpc-header 'containerd-namespace: k8s.io' \
    -d '{}' /run/bench76534717/containerd.sock \
    containerd.services.containers.v1.Containers/List
LEOF
chmod +x $W/list.sh
$W/list.sh
