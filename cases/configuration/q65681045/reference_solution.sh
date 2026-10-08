# ctr does not read the CRI tables of config.toml (the tables of the question are in the wrong place, spelt wrong and keyed by an alias; containerd 2.x does not read them): it reads the
# hosts directory it is given with --hosts-dir. The directory is named after the registry of the image reference, host:port (not after an alias), and its hosts.toml says
# that the registry is reached over plain HTTP. (No restart: ctr reads the directory on every pull.)
REG="v048011.dom600.test:5000"
sudo mkdir -p "/etc/containerd/certs.d/$REG"
sudo tee "/etc/containerd/certs.d/$REG/hosts.toml" >/dev/null <<TOML
server = "http://$REG"

[host."http://$REG"]
  capabilities = ["pull", "resolve"]
TOML
sudo ctr -a /run/bench65681045/containerd.sock images pull --hosts-dir /etc/containerd/certs.d "$REG/myjenkins:latest"
sudo ctr -a /run/bench65681045/containerd.sock run --rm "$REG/myjenkins:latest" bench65681045-check /app hello </dev/null
