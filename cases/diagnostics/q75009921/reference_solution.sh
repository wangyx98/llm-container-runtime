#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
WORK="/tmp/bench75009921"
OUT="$WORK/containers.txt"

# containerd's API is gRPC: HTTP/2 without TLS on the unix socket, and every call needs the
# "containerd-namespace" header (except the namespace calls). curl can speak HTTP/2 over a unix
# socket (--http2-prior-knowledge); a gRPC message is a 5-byte header (flag + big-endian length)
# followed by the protobuf. The requests here are empty messages, the answers are decoded below:
#   ListNamespacesRequest{} -> ListNamespacesResponse{ repeated Namespace namespaces = 1 }, Namespace{ string name = 1 }
#   ListContainersRequest{} -> ListContainersResponse{ repeated Container containers = 1 }, Container{ string id = 1 }
cat > "$WORK/decode.py" <<'PYEOF'
import sys


def varint(b, i):
    n = shift = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7F) << shift
        shift += 7
        if not c & 0x80:
            return n, i


def fields(b):
    i = 0
    while i < len(b):
        tag, i = varint(b, i)
        wt = tag & 7
        if wt == 2:
            ln, i = varint(b, i)
            yield tag >> 3, b[i:i + ln]
            i += ln
        elif wt == 0:
            _, i = varint(b, i)
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        else:
            raise SystemExit("unexpected wire type %d" % wt)


data = sys.stdin.buffer.read()
i = 0
while i + 5 <= len(data):
    ln = int.from_bytes(data[i + 1:i + 5], "big")
    msg = data[i + 5:i + 5 + ln]
    i += 5 + ln
    for num, val in fields(msg):
        if num == 1:                           # one Namespace / Container
            for n2, v2 in fields(val):
                if n2 == 1:                    # its name / id
                    print(v2.decode())
PYEOF

grpc_list() {   # $1 = service/method, then extra curl options
    printf '\x00\x00\x00\x00\x00' | sudo curl -sS --max-time 20 --http2-prior-knowledge --unix-socket "$SOCK" \
        -H 'content-type: application/grpc' -H 'te: trailers' "${@:2}" --data-binary @- "http://localhost/$1" \
        | python3 "$WORK/decode.py"
}

echo "[solution] listing the namespaces..."
NAMESPACES=$(grpc_list containerd.services.namespaces.v1.Namespaces/List)
echo "[solution] namespaces: $(echo $NAMESPACES)"

: > "$OUT"
for ns in $NAMESPACES; do
    grpc_list containerd.services.containers.v1.Containers/List -H "containerd-namespace: $ns" | sed "s/^/$ns /" >> "$OUT"
done

echo "[solution] done. $(wc -l < "$OUT") containers written to $OUT"
