#!/bin/bash
set -e

# A mount made in the host's mount namespace never reaches container A (its namespace is private), and a process inside A's namespace
# cannot reach the host directory (its root is A's root, and a bind mount needs a source in the namespace it runs in). So: clone the
# directory's mount while still in the host namespace (open_tree, a detached mount), enter A's mount namespace (setns), and attach the
# clone there (move_mount) and make it private (a clone of a shared mount is a shared peer). Nothing of A is touched: same process,
# same namespaces, no shared or slave peers.
SOCK=/run/bench75052934/containerd.sock
CRI="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
APP_ID=$($CRI ps -q --name bench75052934-app --state running)
PID=$($CRI inspect -o go-template --template '{{.info.pid}}' "$APP_ID")
echo "[solution] container A: $APP_ID, host pid $PID"

sudo python3 - "$PID" /var/lib/bench75052934/tools /tools <<'PY'
import ctypes, os, sys

libc = ctypes.CDLL(None, use_errno=True)
# same numbers on x86_64 and aarch64
SYS_open_tree, SYS_move_mount = 428, 429
AT_FDCWD = -100
OPEN_TREE_CLONE, OPEN_TREE_CLOEXEC, AT_RECURSIVE = 1, 0o2000000, 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 4
CLONE_NEWNS = 0x00020000


def sc(num, *args):
    r = libc.syscall(ctypes.c_long(num), *args)
    if r < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return r


pid, src, dst = sys.argv[1:4]
tree = sc(SYS_open_tree, ctypes.c_int(AT_FDCWD), ctypes.c_char_p(src.encode()),
          ctypes.c_uint(OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE))
nsfd = os.open("/proc/%s/ns/mnt" % pid, os.O_RDONLY)
if libc.setns(nsfd, CLONE_NEWNS) != 0:
    e = ctypes.get_errno()
    raise OSError(e, os.strerror(e))
os.makedirs(dst, exist_ok=True)
sc(SYS_move_mount, ctypes.c_int(tree), ctypes.c_char_p(b""), ctypes.c_int(AT_FDCWD),
   ctypes.c_char_p(dst.encode()), ctypes.c_uint(MOVE_MOUNT_F_EMPTY_PATH))
# the clone keeps the propagation of the mount it was cloned from (here a shared one, a peer of the host's): make it private, as
# every other mount of A
MS_PRIVATE = 1 << 18
if libc.mount(None, dst.encode(), None, MS_PRIVATE, None) != 0:
    e = ctypes.get_errno()
    raise OSError(e, os.strerror(e))
print("attached %s at %s in the mount namespace of pid %s" % (src, dst, pid))
PY

sudo grep ' /tools ' "/proc/$PID/mountinfo"
