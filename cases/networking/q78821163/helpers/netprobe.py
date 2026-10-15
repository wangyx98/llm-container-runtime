"""netprobe.py NAME ADDR CA : what a client in the pod's network namespace sees (the lab runs it with nsenter --net=POD): one UDP DNS question for NAME at ADDR:53 (A record), then
https://NAME/ at the address the DNS server gave, checked against the CA file, GET /v2/ . Prints one JSON object {"dns": ADDRESS or null, "https": STATUS or null, "error": TEXT}."""
import json
import socket
import ssl
import struct
import sys

name, server, ca = sys.argv[1:4]
res = {"dns": None, "https": None, "error": ""}
try:
    q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(q, (server, 53))
    r = s.recv(512)
    if struct.unpack(">H", r[6:8])[0] >= 1:
        res["dns"] = socket.inet_ntoa(r[-4:])
    ctx = ssl.create_default_context(cafile=ca)
    c = socket.create_connection((res["dns"], 443), timeout=5)
    t = ctx.wrap_socket(c, server_hostname=name)
    t.sendall(("GET /v2/ HTTP/1.1\r\nHost: %s\r\nUser-Agent: bench78821163-lab\r\nConnection: close\r\n\r\n" % name).encode())
    head = t.recv(100).decode("latin-1")
    res["https"] = int(head.split()[1])
    t.close()
except Exception as e:
    res["error"] = "%s: %s" % (type(e).__name__, e)
print(json.dumps(res))
