# ctr does not read the CRI section of config.toml: it reads the hosts directory given with --hosts-dir.
# The directory has the name of the registry being replaced: docker.io is served by the Nexus proxy.
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<'TOML'
server = "https://registry-1.docker.io"

[host."http://127.0.0.1:8181"]
  capabilities = ["pull", "resolve"]
TOML
sudo ctr -a /run/bench76729881/containerd.sock images pull --hosts-dir /etc/containerd/certs.d docker.io/benchorg/kubevip:0.6.1
sudo ctr -a /run/bench76729881/containerd.sock run --rm docker.io/benchorg/kubevip:0.6.1 bench76729881-check /app hello
