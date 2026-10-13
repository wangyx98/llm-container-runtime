"""proxy.py LISTEN_HOST LISTEN_PORT LOG SRC TARGET_HOST TARGET_PORT : the HTTP proxy of the lab (CONNECT only). It tunnels to TARGET_HOST:TARGET_PORT, from the source address SRC
(the only address the registry accepts), and refuses every other request or target with 403. Every request is logged as one JSON object per line in LOG:
{"event": "connect", "target": "host:port", "status": 200|403|502, "client"}."""
import json
import socket
import sys
import threading
import time

lhost, lport, log, src, thost, tport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with open(log, "a") as f:
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
        if target != "%s:%d" % (thost, tport):
            note(event="connect", target=target, status=403, client=addr[0])
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        try:
            up = socket.create_connection((thost, tport), timeout=10, source_address=(src, 0))
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
