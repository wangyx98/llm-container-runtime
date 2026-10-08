# containerd looks the credentials of a registry up in registry.configs by the registry as the image reference names it,
# host AND port: the engineer's table is keyed registry.foo.test, the registry is registry.foo.test:5443, so nothing matches.
# The table is read when containerd starts.
sudo sed -i "s/registry\.configs\.'registry\.foo\.test'\.auth/registry.configs.'registry.foo.test:5443'.auth/" /run/bench65576292/config.toml
sudo /var/lib/bench65576292/bin/containerdctl restart
for i in $(seq 1 30); do sudo ctr -a /run/bench65576292/containerd.sock version >/dev/null 2>&1 && break; sleep 1; done
sleep 3
SOCK=unix:///run/bench65576292/containerd.sock
sudo crictl --runtime-endpoint "$SOCK" --image-endpoint "$SOCK" pull registry.foo.test:5443/library/myimage:latest
