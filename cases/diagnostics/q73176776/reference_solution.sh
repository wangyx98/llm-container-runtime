#!/bin/bash
# crictl is the CRI client: `crictl logs` is the docker logs of a containerd node. It reads the container's CRI log file and prints stdout on its
# stdout and stderr on its stderr. The node's containerd is not at the default socket, so the endpoint is given.
set -e
cat > /tmp/bench73176776/logs.sh <<'SCRIPT'
#!/bin/bash
# the equivalent of `docker logs ID` for the containerd node of the lab
exec sudo crictl --runtime-endpoint unix:///run/bench73176776/containerd/containerd.sock logs "$1"
SCRIPT
chmod +x /tmp/bench73176776/logs.sh

bash /tmp/bench73176776/logs.sh "$(cat /tmp/bench73176776/target.id)"
