# containerd does not read docker's config.json. The CRI takes the credentials of a registry from its hosts directory:
# hosts.toml of that registry (the directory /var/lib/bench72298729/certs.d/127.0.0.1:5000 here) may carry request headers,
# and an Authorization header with the Basic credentials of the account that `docker login` stored is sent with every request.
# hosts.toml is read on every pull: no restart needed.
REG="127.0.0.1:5000"
HOSTS="/var/lib/bench72298729/certs.d/$REG/hosts.toml"
AUTH=$(sudo python3 - "$REG" <<'PY'
import json, sys
print(json.load(open("/var/lib/bench72298729/docker/config.json"))["auths"][sys.argv[1]]["auth"])
PY
)
sudo tee "$HOSTS" >/dev/null <<TOML
server = "http://$REG"

[host."http://$REG"]
  capabilities = ["pull", "resolve"]

  [host."http://$REG".header]
    Authorization = "Basic $AUTH"
TOML
SOCK=unix:///run/bench72298729/containerd.sock
sudo crictl --runtime-endpoint "$SOCK" --image-endpoint "$SOCK" pull "$REG/qtech/graphql:latest"
