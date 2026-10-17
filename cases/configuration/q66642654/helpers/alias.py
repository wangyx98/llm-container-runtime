#!/usr/bin/env python3
"""alias.py add|del|has IFACE:LABEL IP : the lab's registry address (10.66.64.45) as an alias of the loopback interface (no `ip` binary
needed; a /32, so no route of the range appears). The address is not in 127.0.0.0/8: containerd never treats it as a loopback registry, which it would pull from over plain HTTP without any setting."""
import fcntl
import socket
import struct
import sys

SIOCSIFADDR, SIOCSIFFLAGS, SIOCSIFNETMASK = 0x8916, 0x8914, 0x891C
IFF_UP, IFF_RUNNING = 0x1, 0x40


def has(ip):
    for ln in open("/proc/net/fib_trie"):
        if ln.strip() == "|-- " + ip:
            return True
    return False


def ifreq(name, family=socket.AF_INET, addr=None):
    return struct.pack("16sH2x4s8x", name.encode(), family, socket.inet_aton(addr)) if addr else struct.pack("16sH14x", name.encode(), 0)


def main(cmd, name, ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if cmd == "has":
        sys.exit(0 if has(ip) else 1)
    if cmd == "add":
        if has(ip):
            sys.exit("%s is already an address of this host" % ip)
        fcntl.ioctl(s, SIOCSIFADDR, ifreq(name, addr=ip))
        fcntl.ioctl(s, SIOCSIFNETMASK, ifreq(name, addr="255.255.255.255"))
        fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), IFF_UP | IFF_RUNNING))
    elif cmd == "del":
        try:
            fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sH14x", name.encode(), 0))
        except OSError:
            pass


main(*sys.argv[1:4])
