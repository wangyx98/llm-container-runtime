"""reopen.py SOCK CONTAINER_ID : ask the CRI of the containerd at SOCK to reopen the log file of a running container (ReopenContainerLog).

This is what the kubelet does when it rotates a container log: it renames the file (log -> log.TIMESTAMP) and then asks the runtime to reopen the log
path, so the runtime writes to a new file under the old name. crictl has no command for it, and there is no gRPC library on a plain node, so this is a
minimal gRPC client (HTTP/2 over the unix socket, one unary call). It must be run as root (the socket is). Prints "sent" when the server answered
the call; whether the file was reopened is for the caller to check (the new file appears)."""
import socket
import struct
import sys

sock_path, cid = sys.argv[1:3]
METHOD = "/runtime.v1.RuntimeService/ReopenContainerLog"


def frame(kind, flags, stream, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


def literal(name, value):
    """an HPACK literal header field without indexing, new name, no Huffman coding"""
    return b"\x00" + bytes([len(name)]) + name + bytes([len(value)]) + value


def pair(index, value):
    """an HPACK literal header field without indexing, name from the static table"""
    return bytes([index]) + bytes([len(value)]) + value


headers = (b"\x83" + b"\x86"                      # :method POST, :scheme http
           + pair(0x04, METHOD.encode())          # :path
           + pair(0x01, b"localhost")             # :authority
           + literal(b"content-type", b"application/grpc")
           + literal(b"te", b"trailers"))
body = b"\x0a" + bytes([len(cid)]) + cid.encode()  # ReopenContainerLogRequest { string container_id = 1; }
message = b"\x00" + struct.pack(">I", len(body)) + body

s = socket.socket(socket.AF_UNIX)
s.settimeout(20)
s.connect(sock_path)
s.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(4, 0, 0) + frame(1, 4, 1, headers) + frame(0, 1, 1, message))
buf = b""
done = False
while not done:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
    while len(buf) >= 9:
        n = int.from_bytes(buf[:3], "big")
        if len(buf) < 9 + n:
            break
        kind, flags, stream = buf[3], buf[4], struct.unpack(">I", buf[5:9])[0] & 0x7fffffff
        buf = buf[9 + n:]
        if kind == 4 and not flags:              # the server's SETTINGS: acknowledge
            s.sendall(frame(4, 1, 0))
        elif kind == 7 or (kind == 3 and stream == 1):   # GOAWAY or RST_STREAM
            print("the server refused the call")
            sys.exit(1)
        elif stream == 1 and kind in (0, 1) and flags & 1:   # the end of the response
            done = True
if not done:
    print("no answer from the server")
    sys.exit(1)
print("sent")
