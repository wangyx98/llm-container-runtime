#!/bin/bash
set -e

CASE_ID="bench78821163"
APP_DIR="/tmp/$CASE_ID/app"
SOCK="/run/$CASE_ID/containerd.sock"
CTR="sudo ctr -a $SOCK -n $CASE_ID"

# 1. the program: put the container in the network namespace of the pod and give it the DNS server of the node network as its resolver
python3 - "$APP_DIR/main.go" <<'PYEOF'
import sys

p = sys.argv[1]
s = open(p).read()
s = s.replace('''	mnts := []specs.Mount{''', '''	resolv := "/tmp/bench78821163/resolv.conf"
	if err := os.WriteFile(resolv, []byte("nameserver 10.78.21.1\\n"), 0o644); err != nil {
		log.Fatal(err)
	}
	mnts := []specs.Mount{
		{Destination: "/etc/resolv.conf", Type: "bind", Source: resolv, Options: []string{"rbind", "ro"}},''')
s = s.replace('''	container, err := cli.NewContainer(''', '''	specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: "/run/netns/bench78821163-pod"}))

	container, err := cli.NewContainer(''')
open(p, "w").write(s)
PYEOF
gofmt -l "$APP_DIR" >/dev/null 2>&1 || true
(cd "$APP_DIR" && GOFLAGS=-mod=mod go build -o dind .)

# 2. the container that is running was made with the old program (its network namespace cannot change): remove it and make a new one
$CTR tasks kill -s KILL dind >/dev/null 2>&1 || true
for _ in $(seq 1 20); do $CTR tasks delete dind >/dev/null 2>&1 && break; sleep 0.5; done
$CTR containers delete dind >/dev/null 2>&1 || true
sudo "$APP_DIR/dind" --address "$SOCK" --namespace "$CASE_ID" --name dind --image "$CASE_ID.local/dind:1" --data "/var/lib/$CASE_ID/dind-data" --ca "/var/lib/$CASE_ID/pki/ca.crt"
