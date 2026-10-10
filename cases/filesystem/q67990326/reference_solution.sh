#!/bin/bash
set -e

# The thread's answer, made to work: 'ctr snapshots mounts DIR KEY' only PRINTS the mount command for a snapshot. KEY has to be the key of
# the container's own ACTIVE snapshot (the container's "SnapshotKey"), not the image's layers (committed, or a view of them: those hold
# the image's older files, not what the container wrote). The command is run (read-only) and the file is copied out like a stream.
mkdir -p /tmp/bench67990326/out
cat > /tmp/bench67990326/cp.sh <<'EOF'
#!/bin/bash
# usage: cp.sh CONTAINER:PATH DEST   (CONTAINER: the name or the id of a container of this node's containerd; like 'docker cp')
set -eu
SOCK=/run/bench67990326/containerd.sock
CRI="crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
CTR="ctr -a $SOCK -n k8s.io"
spec=$1 dest=$2
name=${spec%%:*} src=${spec#*:}
id=$($CRI ps -a -q --name "^${name}\$" 2>/dev/null | head -1)
[ -n "$id" ] || id=$($CRI ps -a -q --id "$name" 2>/dev/null | head -1)
[ -n "$id" ] || { echo "no container $name" >&2; exit 1; }
key=$($CTR containers info "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SnapshotKey"])')
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
cmd=$($CTR snapshots mounts "$mnt" "$key")
$cmd -o ro
cp -- "$mnt/${src#/}" "$dest"
EOF
sudo bash /tmp/bench67990326/cp.sh bench67990326-app:/data/report.bin /tmp/bench67990326/out/report.bin
