#!/bin/bash
set -e

# The dump is in the container's own writable filesystem, not in its volume (that holds vold_data.json and an empty mount directory),
# and the image has no tool (cat, tar, cp) to read it from inside. The node can reach it directly: the root filesystem of a running
# container is visible on the node as /proc/<host pid>/root (the pid is in 'crictl inspect'); it is a plain file there, so a plain
# copy of it is the extraction (no tar, no kubectl cp; streamed by cp, not loaded into memory).
SOCK=/run/bench74546773/containerd.sock
WORK=/tmp/bench74546773
mkdir -p "$WORK/out"

cat > "$WORK/extract.sh" <<'EOF'
#!/bin/bash
# usage: extract.sh CONTAINER_NAME PATH_IN_CONTAINER DESTINATION_ON_THE_HOST
set -e
NAME=$1; SRC=$2; DST=$3
[ -n "$NAME" ] && [ -n "$SRC" ] && [ -n "$DST" ] || { echo "usage: extract.sh CONTAINER_NAME PATH_IN_CONTAINER DESTINATION" >&2; exit 2; }
SOCK=/run/bench74546773/containerd.sock
CRI="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
ID=$($CRI ps -q --name "^$NAME\$" --state running)
[ -n "$ID" ] || { echo "no running container named $NAME" >&2; exit 1; }
PID=$($CRI inspect -o go-template --template '{{.info.pid}}' "$ID")
mkdir -p "$(dirname "$DST")"
sudo cp --reflink=never --sparse=never "/proc/$PID/root$SRC" "$DST.part"
mv "$DST.part" "$DST"
echo "extracted $SRC of $NAME (host pid $PID) to $DST: $(stat -c %s "$DST") bytes"
EOF

bash "$WORK/extract.sh" bench74546773-app /var/dump/app.hprof "$WORK/out/app.hprof"
sha256sum "$WORK/out/app.hprof"
