# ctr does not read the CRI tables of config.toml (the question's tables are not even read by containerd 2.x): it reads the
# hosts directory it is given with --hosts-dir. The directory is named after the registry, host:port, and its hosts.toml says
# that the registry is reached over plain HTTP. (No restart: ctr reads the directory on every pull.)
REG="registry.bench69103103.test:4657"
sudo mkdir -p "/etc/containerd/certs.d/$REG"
sudo tee "/etc/containerd/certs.d/$REG/hosts.toml" >/dev/null <<TOML
server = "http://$REG"

[host."http://$REG"]
  capabilities = ["pull", "resolve"]
TOML
sudo ctr -a /run/bench69103103/containerd.sock images pull --hosts-dir /etc/containerd/certs.d "$REG/82d4bb7b89/dockerimages/abc:v2.3.0"
sudo ctr -a /run/bench69103103/containerd.sock run --rm "$REG/82d4bb7b89/dockerimages/abc:v2.3.0" bench69103103-check /app hello </dev/null
