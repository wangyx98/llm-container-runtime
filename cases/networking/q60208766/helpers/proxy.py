"""proxy.py LISTEN_HOST LISTEN_PORT LOG SRC REG_HOST REG_PORT API_IP API_PORT : the corporate HTTP proxy of the lab (CONNECT only). It tunnels to the lab's registry REG_HOST:REG_PORT from the
source address SRC (the only address the registry accepts), and refuses every other target with 403. The Kubernetes API API_IP:API_PORT is inside the cluster and the proxy cannot reach it:
it answers such a CONNECT with 200 and then answers the TLS ClientHello with a ServerHello of version 0x0301 (TLS 1.0, what an old appliance in front of the internet says), which makes a Go
client fail with "tls: server selected unsupported protocol version 301". Every request is logged as one JSON object per line in LOG:
{"event": "connect", "target": "host:port", "status": 200|403|502, "client"}."""
import json
import socket
import struct
import sys
import threading
import time

lhost, lport, log, src, rhost, rport, aip, aport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]), sys.argv[7], int(sys.argv[8])
LOCK = threading.Lock()


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with LOCK, open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def old_server_hello():
    """a TLS record with a ServerHello (handshake type 2) of version 0x0301"""
    body = b"\x03\x01" + bytes(32) + b"\x00" + b"\x00\x2f" + b"\x00" + b"\x00\x00"
    hs = b"\x02" + struct.pack(">I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs


def serve(c, addr):
    try:
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = c.recv(4096)
            if not chunk:
                return
            data += chunk
        first = data.split(b"\r\n", 1)[0].decode("latin-1").split()
        if len(first) < 2 or first[0] != "CONNECT":
            note(event="request", line=" ".join(first)[:80], status=403, client=addr[0])
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        target = first[1]
        if target == "%s:%d" % (aip, aport):
            note(event="connect", target=target, status=200, client=addr[0])
            c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            c.settimeout(5)
            try:
                c.recv(65536)           # the ClientHello
                c.sendall(old_server_hello())
                time.sleep(0.5)
            except OSError:
                pass
            return
        if target != "%s:%d" % (rhost, rport):
            note(event="connect", target=target, status=403, client=addr[0])
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        try:
            up = socket.create_connection((rhost, rport), timeout=10, source_address=(src, 0))
        except OSError:
            note(event="connect", target=target, status=502, client=addr[0])
            c.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return
        note(event="connect", target=target, status=200, client=addr[0])
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        t = threading.Thread(target=pipe, args=(up, c), daemon=True)
        t.start()
        pipe(c, up)
        t.join(5)
    finally:
        c.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((lhost, lport))
srv.listen(64)
while True:
    conn, a = srv.accept()
    threading.Thread(target=serve, args=(conn, a), daemon=True).start()
