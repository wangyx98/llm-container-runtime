"""proxy.py LISTEN_HOST LISTEN_PORT LOG CRED SRC TARGET_NAME TARGET_ADDR TARGET_PORT : the corporate proxy of the lab: an HTTP proxy that wants credentials (Basic Proxy-Authorization; the user
name is on line 1 and the password on line 2 of the file CRED) and tunnels (CONNECT only) to ONE target: TARGET_NAME:TARGET_PORT, which only the proxy can resolve (it connects to TARGET_ADDR,
from the source address SRC, the only one the registry accepts). It answers 407 (Proxy-Authenticate: Basic) to a request without credentials or with wrong ones, and 403 to anything else (another
method, another target). Every request is logged as one JSON object per line in LOG: {"event": "connect", "target", "auth": "ok"|"none"|"bad", "status": 200|407|403|502, "client"} (a rejected
password is never written down, and neither is a correct one; "user" is the name that was given, only in a rejected request)."""
import base64
import json
import socket
import sys
import threading
import time

lhost, lport, log, cred, src, tname, taddr, tport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], int(sys.argv[8])
with open(cred) as f:
    USER, PASS = f.read().split("\n")[:2]


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


def reply(c, line, extra=""):
    c.sendall(("HTTP/1.1 %s\r\n%sContent-Length: 0\r\nConnection: close\r\n\r\n" % (line, extra)).encode())


def authenticate(headers):
    """-> (auth, user): auth is ok, none or bad"""
    for h in headers:
        k, _, v = h.partition(":")
        if k.strip().lower() == "proxy-authorization":
            kind, _, token = v.strip().partition(" ")
            if kind.lower() != "basic":
                return "bad", ""
            try:
                u, _, p = base64.b64decode(token.strip()).decode("utf-8", "replace").partition(":")
            except ValueError:
                return "bad", ""
            return ("ok" if (u, p) == (USER, PASS) else "bad"), u
    return "none", ""


def serve(c, addr):
    try:
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = c.recv(4096)
            if not chunk:
                return
            data += chunk
        lines = data.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        first = lines[0].split()
        auth, user = authenticate(lines[1:])
        if len(first) < 2 or first[0] != "CONNECT":
            note(event="request", line=" ".join(first)[:80], auth=auth, status=403, client=addr[0])
            return reply(c, "403 Forbidden")
        target = first[1]
        if auth != "ok":
            note(event="connect", target=target, auth=auth, status=407, client=addr[0], **({"user": user[:40]} if user else {}))
            return reply(c, "407 Proxy Authentication Required", 'Proxy-Authenticate: Basic realm="bench73394153"\r\n')
        if target != "%s:%d" % (tname, tport):
            note(event="connect", target=target, auth=auth, status=403, client=addr[0])
            return reply(c, "403 Forbidden")
        try:
            up = socket.create_connection((taddr, tport), timeout=10, source_address=(src, 0))
        except OSError:
            note(event="connect", target=target, auth=auth, status=502, client=addr[0])
            return reply(c, "502 Bad Gateway")
        note(event="connect", target=target, auth=auth, status=200, client=addr[0])
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
