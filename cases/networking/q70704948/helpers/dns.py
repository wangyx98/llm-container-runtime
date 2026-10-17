"""dns.py ADDR LOG MODE [NAME IP] : a name server on ADDR:53 (UDP and TCP) for the lab's network namespace.

MODE corp   answers NAME with the A record IP (and the empty answer for AAAA of NAME); every other name is NXDOMAIN. This is the corporate name server.
MODE stale  answers NXDOMAIN for every name. This is the old resolver that does not know the internal download site.
Every query is one line of LOG: time, client address, name, type, answer."""
import socket
import struct
import sys
import threading
import time

addr, log, mode = sys.argv[1:4]
name = sys.argv[4].lower() if len(sys.argv) > 4 else ""
ip = sys.argv[5] if len(sys.argv) > 5 else ""
lock = threading.Lock()


def note(src, qname, qtype, what):
    with lock, open(log, "a") as f:
        f.write("%s %s %s %s %s\n" % (time.strftime("%H:%M:%S"), src, qname, qtype, what))


def parse(req):
    """-> (question section bytes, qname, qtype) or None"""
    if len(req) < 17:
        return None
    i, labels = 12, []
    while i < len(req) and req[i]:
        labels.append(req[i + 1:i + 1 + req[i]].decode("ascii", "replace"))
        i += 1 + req[i]
    if i + 5 > len(req):
        return None
    qtype = struct.unpack("!H", req[i + 1:i + 3])[0]
    return req[12:i + 5], ".".join(labels).lower(), qtype


def reply(req, src):
    q = parse(req)
    if q is None:
        return None
    question, qname, qtype = q
    rd = req[2] & 1
    if mode == "corp" and qname == name and qtype in (1, 28):
        rcode, answers = 0, (b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(ip)) if qtype == 1 else b""
        what = ip if qtype == 1 else "NODATA"
    else:
        rcode, answers, what = 3, b"", "NXDOMAIN"
    note(src, qname, {1: "A", 28: "AAAA"}.get(qtype, str(qtype)), what)
    head = req[:2] + struct.pack("!BBHHHH", 0x80 | (rd & 1), 0x80 | rcode, 1, 1 if answers else 0, 0, 0)
    return head + question + answers


def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((addr, 53))
    while True:
        data, src = s.recvfrom(1500)
        out = reply(data, src[0])
        if out:
            s.sendto(out, src)


def tcp_client(c, src):
    try:
        c.settimeout(5)
        n = c.recv(2)
        if len(n) == 2:
            data = b""
            while len(data) < struct.unpack("!H", n)[0]:
                chunk = c.recv(4096)
                if not chunk:
                    break
                data += chunk
            out = reply(data, src)
            if out:
                c.sendall(struct.pack("!H", len(out)) + out)
    except OSError:
        pass
    finally:
        c.close()


def tcp():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((addr, 53))
    s.listen(16)
    while True:
        c, src = s.accept()
        threading.Thread(target=tcp_client, args=(c, src[0]), daemon=True).start()


threading.Thread(target=udp, daemon=True).start()
tcp()
