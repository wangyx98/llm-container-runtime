import fcntl, socket, struct, sys
# netcfg.py ADDR... : loopback up and each ADDR/32 as an alias of lo, inside the current network namespace (no 'ip' needed)
SIOCSIFADDR, SIOCSIFNETMASK, SIOCSIFFLAGS, SIOCGIFFLAGS = 0x8916, 0x891C, 0x8914, 0x8913
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
def req(name, rest): return struct.pack("16s", name.encode()) + rest
def sa(addr): return struct.pack("HH4s8x", socket.AF_INET, 0, socket.inet_aton(addr))
fl = struct.unpack("16sH", fcntl.ioctl(s, SIOCGIFFLAGS, req("lo", b"\0" * 24))[:18])[1]
fcntl.ioctl(s, SIOCSIFFLAGS, req("lo", struct.pack("H", fl | 1 | 0x40) + b"\0" * 22))
for i, a in enumerate(sys.argv[1:], 1):     # one alias label per address: a second address on the same label would replace the first
    fcntl.ioctl(s, SIOCSIFADDR, req("lo:%d" % i, sa(a)))
    fcntl.ioctl(s, SIOCSIFNETMASK, req("lo:%d" % i, sa("255.255.255.255")))
print("lo up", sys.argv[1:])
