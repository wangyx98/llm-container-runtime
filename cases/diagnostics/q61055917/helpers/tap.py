"""tap.py SOCKET LOG : a unix socket at SOCKET that nothing should ever connect to. Every connection is written to LOG (one line) and closed at once.
It stands for the socket of another containerd of the host, which is not part of the node under test."""
import os
import socket
import sys
import time

path, log = sys.argv[1:3]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o666)
s.listen(16)
open(log, "a").close()
os.chmod(log, 0o644)
while True:
    c, _ = s.accept()
    with open(log, "a") as f:
        f.write("%s connection\n" % time.strftime("%H:%M:%S"))
    c.close()
