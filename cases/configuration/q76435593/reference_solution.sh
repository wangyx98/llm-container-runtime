# containerd's hosts directory for the CRI (config_path) has a special entry, _default, used for every registry
# name that has no directory of its own. The mirror is the host of that entry; containerd adds ?ns=<registry> to the
# requests it sends to it, which is how the mirror tells the upstream registries apart. No restart is needed:
# the hosts files are read at every pull.
sudo mkdir -p /var/lib/bench76435593/certs.d/_default
sudo tee /var/lib/bench76435593/certs.d/_default/hosts.toml >/dev/null <<'TOML'
[host."http://127.0.0.1:8083"]
  capabilities = ["pull", "resolve"]
TOML
SOCK=unix:///run/bench76435593/containerd.sock
for r in alpha.registry.test beta.registry.test; do
    sudo crictl --runtime-endpoint "$SOCK" --image-endpoint "$SOCK" pull "$r/team/tool:1.0"
    sudo ctr -a /run/bench76435593/containerd.sock -n k8s.io run --rm "$r/team/tool:1.0" bench76435593-check /app hello </dev/null
done
