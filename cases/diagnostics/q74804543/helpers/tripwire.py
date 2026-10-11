"""tripwire.py PORT LOGFILE : the "registry" the image names point at. It holds nothing: it answers every HTTP request with 404, and it
records every connection made to it (one line each, whatever the protocol: a pull over https counts too). A node that runs an image it
already has never connects to a registry."""
import socket
import sys
import threading
import time

port, logfile = int(sys.argv[1]), sys.argv[2]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(16)
lock = threading.Lock()


def handle(conn, peer):
    with lock, open(logfile, "a") as f:
        f.write("%.3f connection from port %d\n" % (time.time(), peer[1]))
    try:
        conn.settimeout(2)
        head = conn.recv(1024)
        if head.split(b" ")[0] in (b"GET", b"HEAD", b"POST"):
            body = b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
    except OSError:
        pass
    finally:
        conn.close()


while True:
    c, p = srv.accept()
    threading.Thread(target=handle, args=(c, p), daemon=True).start()
