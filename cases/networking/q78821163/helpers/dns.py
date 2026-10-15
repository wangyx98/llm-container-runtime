"""dns.py HOST LOG NAME ADDR : the DNS server of the lab (UDP and TCP, port 53 on HOST). NAME has one A record, ADDR (TTL 1: nothing is cached for long); an AAAA question for NAME gets an
empty answer (NOERROR); every other name is answered NXDOMAIN. Every question is logged in LOG as one JSON object {"event": "dns", "qname", "qtype", "src", "proto", "t"}."""
import json
import socket
import struct
import sys
import threading
import time

host, log, name, addr = sys.argv[1:5]
lock = threading.Lock()
NAME = name.lower().rstrip(".")


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with lock, open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


def parse(q):
    labels, i = [], 12
    while i < len(q) and q[i]:
        n = q[i]
        labels.append(q[i + 1:i + 1 + n].decode("latin-1"))
        i += n + 1
    return ".".join(labels).lower(), struct.unpack(">H", q[i + 1:i + 3])[0], i + 5


def answer(q, src, proto):
    if len(q) < 17:
        return None
    qname, qtype, end = parse(q)
    note(event="dns", qname=qname, qtype={1: "A", 28: "AAAA"}.get(qtype, str(qtype)), src=src, proto=proto)
    head = q[:2]
    question = q[12:end]
    if qname == NAME and qtype == 1:
        rr = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 1, 4) + socket.inet_aton(addr)
        return head + struct.pack(">HHHHH", 0x8580, 1, 1, 0, 0) + question + rr
    rcode = 0 if qname == NAME else 3
    return head + struct.pack(">HHHHH", 0x8580 | rcode, 1, 0, 0, 0) + question


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((host, 53))
    while True:
        q, a = s.recvfrom(512)
        try:
            r = answer(q, a[0], "udp")
        except Exception:
            r = None
        if r:
            s.sendto(r, a)


def tcp_conn(c, a):
    try:
        c.settimeout(5)
        raw = c.recv(2)
        n = struct.unpack(">H", raw)[0]
        q = b""
        while len(q) < n:
            q += c.recv(n - len(q))
        r = answer(q, a[0], "tcp")
        if r:
            c.sendall(struct.pack(">H", len(r)) + r)
    except Exception:
        pass
    finally:
        c.close()


def tcp():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, 53))
    s.listen(16)
    while True:
        c, a = s.accept()
        threading.Thread(target=tcp_conn, args=(c, a), daemon=True).start()


threading.Thread(target=udp, daemon=True).start()
tcp()
