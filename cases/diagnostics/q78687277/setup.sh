#!/bin/bash
set -e

CASE_ID="bench78687277"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the node: containerd's root, its programs, the pod's definition, the tools, the directory of the probe (not in /run: it is often noexec)
RUN="/run/$CASE_ID"                          # containerd's state and socket, the pod's log directory, the directory /out of the container
CACHE="/var/cache/$CASE_ID"                  # the downloaded containerd, runc and crictl (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # nodectl, crictl (with the node's socket), execlab.py (the clients of the lab)
NODEBIN="$LIB/node/bin"                      # first in the PATH of the node's containerd: containerd, its shim and runc are found here
ETC="$LIB/etc"
PODS="$LIB/pods"
PROBE_DIR="$LIB/probe"                       # mounted read-only at /probe in the container: the solution puts its program there
LAB_DIR="$LIB/lab"                           # mounted read-only at /lab in the container: the lab's passive observer
OUT_DIR="$RUN/out"                           # mounted at /out in the container: the observer's logs and the socket of the checker
SOCK="$RUN/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
APP_REF="$CASE_ID.local/app:1"               # the workload: /bin/idle sleeps for ever
PAUSE_REF="$CASE_ID.local/pause:1"           # the sandbox image of the pod
CTD_VERSION="1.7.20"                         # the node's containerd: the CRI of the 1.7 line keeps an exec process alive when its client is gone (containerd 2.3 kills it half a second later)
RUNC_VERSION="v1.1.12"
CRICTL_VERSION="v1.34.0"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"
        CTD_SHA="e09410787b6f392748959177a84e024424f75d7aff33ea1c5b783f2260edce67"
        RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8"
        CRICTL_SHA="a8ff2a3edb37a98daf3aba7c3b284fe0aa5bff24166d896ab9ef64c8913c9f51" ;;
    aarch64|arm64)  KARCH="arm64"
        CTD_SHA="cf80cd305f7d1c23aaf0c57bc1c1e37089cad9130d533db6fe968cdebd16c759"
        RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8"
        CRICTL_SHA="c31d252e203df5f4cf37f314bd3092eb79087e791631c1e607087c74b6d0423f" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, tar, sudo, sha256sum, gcc..."
for c in python3 curl tar sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$NODEBIN" "$ETC" "$PODS" "$LAB_DIR" "$RUN" "$RUN/log"
sudo install -d -m 777 "$PROBE_DIR" "$OUT_DIR"
# cgroups of the pod are made below /$CASE_ID; one that is there now is not ours
sudo sh -c "find /sys/fs/cgroup -type d -path '*/$CASE_ID' 2>/dev/null | sort > '$STATE_DIR/cgroups.before'"

# a file is taken from the cache when its sha256 is right, else downloaded and checked
sudo install -d -m 755 "$CACHE"
fetch() {   # $1 = file name in the cache, $2 = url, $3 = sha256
    if [ -f "$CACHE/$1" ] && echo "$3  $CACHE/$1" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
    sudo rm -f "$CACHE/$1"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/$1" "$2" || { echo "[setup] ERROR: could not download $2"; exit 1; }
    echo "$3  $WORK_DIR/$1" | sha256sum -c --quiet - || { echo "[setup] ERROR: $1 does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/$1" "$CACHE/$1"
    rm -f "$WORK_DIR/$1"
}
echo "[setup] containerd $CTD_VERSION, runc $RUNC_VERSION and crictl $CRICTL_VERSION ($KARCH): from the cache $CACHE, else downloaded; the sha256 is checked either way..."
fetch "containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" "$CTD_SHA"
fetch "runc.$KARCH.$RUNC_VERSION" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" "$RUNC_SHA"
fetch "crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" "$CRICTL_SHA"
mkdir "$WORK_DIR/x"
tar -xzf "$CACHE/containerd-$CTD_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" bin/containerd bin/containerd-shim-runc-v2 bin/ctr
for b in containerd containerd-shim-runc-v2 ctr; do sudo install -m 755 -o root -g root "$WORK_DIR/x/bin/$b" "$NODEBIN/$b"; done
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$NODEBIN/runc"
tar -xzf "$CACHE/crictl-$CRICTL_VERSION-linux-$KARCH.tar.gz" -C "$WORK_DIR/x" crictl
sudo install -m 755 -o root -g root "$WORK_DIR/x/crictl" "$BIN/crictl.real"
rm -rf "$WORK_DIR/x"
echo "  $("$NODEBIN/containerd" --version), runc $("$NODEBIN/runc" --version | head -1), $("$BIN/crictl.real" --version)"

echo "[setup] writing and compiling box (the lab's one static program: pid 1 of the pod and of the container, it sleeps) and watch (the lab's passive observer)..."
sudo tee "$STATE_DIR/box.c" >/dev/null <<'BOX_C_EOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
BOX_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/box" "$STATE_DIR/box.c"
sudo tee "$STATE_DIR/watch.c" >/dev/null <<'WATCH_C_EOF'
/* watch LABEL [SECONDS] : what a process in an exec session can see of its streams, passively. It reads nothing but what comes (stdin is non-blocking), writes a dot a second to stdout, and logs to /out/LABEL.log
   a line each time anything it looks at changes: the type of stdin and stdout, poll() on both, the result of read() and write(), the window size of the terminal, /dev/tty, the signals it received; and "alive" a second. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t sigs[65];
static void h(int s) { sigs[s]++; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int secs = argc > 2 ? atoi(argv[2]) : 40;
    char path[160]; snprintf(path, sizeof path, "/out/%s.log", argv[1]);
    FILE *log = fopen(path, "w"); if (!log) return 2;
    setvbuf(log, NULL, _IOLBF, 0);
    int ss[] = {SIGHUP, SIGPIPE, SIGTTOU, SIGTTIN, SIGCONT, SIGWINCH, SIGINT, SIGTERM, SIGQUIT};
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = h;
    for (unsigned i = 0; i < sizeof ss / sizeof *ss; i++) sigaction(ss[i], &sa, NULL);
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    double t0 = now(), beat = 0; char prev[512] = "";
    struct timespec rt; clock_gettime(CLOCK_REALTIME, &rt);
    fprintf(log, "%6.2f start epoch=%ld.%03ld pid=%d tty0=%d tty1=%d\n", 0.0, (long)rt.tv_sec, rt.tv_nsec / 1000000, getpid(), isatty(0), isatty(1));
    while (now() - t0 < secs) {
        char cur[512]; struct stat s0, s1; fstat(0, &s0); fstat(1, &s1);
        struct pollfd p[2] = {{0, POLLIN, 0}, {1, POLLOUT, 0}};
        poll(p, 2, 0);
        char b[64]; errno = 0; ssize_t r = read(0, b, sizeof b); int e0 = r < 0 ? errno : 0;
        errno = 0; ssize_t w = write(1, ".", 1); int e1 = w < 0 ? errno : 0;
        struct winsize ws; int ioc = ioctl(1, TIOCGWINSZ, &ws) == 0;
        int t = open("/dev/tty", O_RDWR | O_NOCTTY); int et = t < 0 ? errno : 0; if (t >= 0) close(t);
        char sg[200] = ""; for (unsigned i = 0; i < sizeof ss / sizeof *ss; i++) if (sigs[ss[i]]) { char x[24]; snprintf(x, sizeof x, " sig%d=%d", ss[i], (int)sigs[ss[i]]); strcat(sg, x); }
        snprintf(cur, sizeof cur, "in:%s poll0=0x%x read=%zd/%s | out:%s poll1=0x%x write=%zd/%s winsz=%d | devtty=%s |%s",
                 S_ISCHR(s0.st_mode) ? "chr" : S_ISFIFO(s0.st_mode) ? "fifo" : "other", p[0].revents, r, e0 ? strerror(e0) : "-",
                 S_ISCHR(s1.st_mode) ? "chr" : S_ISFIFO(s1.st_mode) ? "fifo" : "other", p[1].revents, w, e1 ? strerror(e1) : "-", ioc, et ? strerror(et) : "ok", sg);
        if (strcmp(cur, prev)) { fprintf(log, "%6.2f state %s\n", now() - t0, cur); strcpy(prev, cur); }
        if (now() - beat >= 1) { fprintf(log, "%6.2f alive\n", now() - t0); beat = now(); }
        usleep(100000);
    }
    fprintf(log, "%6.2f end\n", now() - t0);
    return 0;
}
WATCH_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/watch" "$STATE_DIR/watch.c"
sudo install -m 755 -o root -g root "$STATE_DIR/watch" "$LAB_DIR/watch"

echo "[setup] the two images, built offline as OCI archives (nothing is pulled from a registry)..."
sudo tee "$STATE_DIR/mkimg.py" >/dev/null <<'MKIMG_PY_EOF'
"""mkimg.py OUT REF ENTRYPOINT_JSON BOX FILE...  : an OCI image archive with one layer: BOX as the first FILE, the other FILEs are symbolic links to it."""
import hashlib
import io
import json
import platform
import sys
import tarfile

out, ref, entry, box = sys.argv[1:5]
names = sys.argv[5:]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]
T = 1700000000


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for d in ("bin", "etc", "proc", "dev", "sys", "tmp"):
        ti = tarfile.TarInfo(d)
        ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, T
        t.addfile(ti)
    data = open(box, "rb").read()
    ti = tarfile.TarInfo(names[0])
    ti.size, ti.mode, ti.mtime = len(data), 0o755, T
    t.addfile(ti, io.BytesIO(data))
    for n in names[1:]:
        ti = tarfile.TarInfo(n)
        ti.type, ti.linkname, ti.mode, ti.mtime = tarfile.SYMTYPE, "/" + names[0], 0o777, T
        t.addfile(ti)
layer = buf.getvalue()
cfg = {"architecture": arch, "os": "linux", "config": {}, "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}
if json.loads(entry):
    cfg["config"]["Entrypoint"] = json.loads(entry)
config = json.dumps(cfg).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sha(layer), "size": len(layer)}]}).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": sha(manifest), "size": len(manifest),
                    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    for name, blob in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index), ("blobs/sha256/" + sha(layer)[7:], layer),
                       ("blobs/sha256/" + sha(config)[7:], config), ("blobs/sha256/" + sha(manifest)[7:], manifest)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(blob), T
        t.addfile(ti, io.BytesIO(blob))
MKIMG_PY_EOF
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/app.tar" "$APP_REF" '["/bin/idle"]' "$STATE_DIR/box" bin/box bin/idle
sudo python3 "$STATE_DIR/mkimg.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" '["/pause"]' "$STATE_DIR/box" pause

echo "[setup] execlab.py, the clients of the lab: what kubectl exec (here crictl exec, the same CRI streaming) does for a person at a terminal, and for a script with pipes..."
sudo tee "$BIN/execlab.py" >/dev/null <<'EXECLAB_PY_EOF'
"""execlab.py : the clients of the lab, for precondition.sh and oracle.sh (python3, as root).
Client(cid, argv, tty): runs `crictl exec -i [-t] CID ARGV...` the way kubectl exec -i [-t] is run.
  tty=True : the client runs on a terminal of its own and the "person" at it is a real terminal emulator: it answers the standard query "cursor position report" (ESC [ 6 n) with ESC [ 24 ; 80 R,
             and writes to the terminal what the test asks it to type (type()).
  tty=False: the client has a pipe as stdin that stays open and silent (a script that does not close its stdin), and its output is read and thrown away.
  kill(sig) ends the client the way a killed kubectl ends (SIGKILL), or a terminated one (SIGTERM); the pipe and the terminal are closed with it.
Collector(path): the unix socket (in the container's /out) on which the container reports; it records the time, the host pid of the process that connected (SO_PEERCRED: the kernel's word for who connected,
  whatever the pid namespaces) and the line it sent.
probe_pids(argv): the host pids of the processes of the container whose command line is exactly argv; nspid(pid): the pid the process has in its own pid namespace."""
import os
import pty
import signal
import socket
import struct
import subprocess
import threading
import time

LIB = "/var/lib/bench78687277"
RUN = "/run/bench78687277"
CRICTL = LIB + "/bin/crictl"
DSR = b"\x1b[6n"
REPLY = b"\x1b[24;80R"


def crictl(*args, timeout=60):
    return subprocess.run([CRICTL, "--timeout", "%ds" % timeout] + list(args), capture_output=True, text=True, timeout=timeout + 10)


def main_cid():
    r = crictl("ps", "--name", "^app$", "-q")
    ids = r.stdout.split()
    return ids[0] if ids else None


class Client:
    def __init__(self, cid, argv, tty, answer=True):
        self.cid, self.argv, self.tty, self.answer = cid, list(argv), tty, answer
        self.args = [CRICTL, "--timeout", "0s", "exec", "-i"] + (["-t"] if tty else []) + [cid] + self.argv
        self.out = b""
        self.dsr_seen = 0
        self.killed_at = None
        self.fd = None
        self.w_in = None
        self.proc = None
        self.pid = None
        self._pending = b""

    def start(self):
        if self.tty:
            self.pid, self.fd = pty.fork()
            if self.pid == 0:
                os.execv(self.args[0], self.args)
            import fcntl
            import termios
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            threading.Thread(target=self._pump_tty, daemon=True).start()
        else:
            r_in, self.w_in = os.pipe()
            self.proc = subprocess.Popen(self.args, stdin=r_in, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            os.close(r_in)
            self.pid = self.proc.pid
            threading.Thread(target=self._pump_pipe, daemon=True).start()
        return self

    def _pump_tty(self):
        while True:
            try:
                d = os.read(self.fd, 4096)
            except OSError:
                return
            if not d:
                return
            self.out += d
            self._pending += d
            while DSR in self._pending:
                self._pending = self._pending.split(DSR, 1)[1]
                self.dsr_seen += 1
                if self.answer:
                    try:
                        os.write(self.fd, REPLY)
                    except OSError:
                        return
            self._pending = self._pending[-3:]

    def _pump_pipe(self):
        for chunk in iter(lambda: self.proc.stdout.read1(4096), b""):
            self.out += chunk

    def type(self, data):
        os.write(self.fd, data)

    def alive(self):
        try:
            if self.tty:
                return os.waitpid(self.pid, os.WNOHANG) == (0, 0)
            return self.proc.poll() is None
        except ChildProcessError:
            return False

    def kill(self, sig=signal.SIGKILL):
        self.killed_at = time.time()
        try:
            os.kill(self.pid, sig)
        except ProcessLookupError:
            pass
        if self.tty:
            time.sleep(0.2)
            try:
                os.close(self.fd)
            except OSError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        else:
            try:
                os.close(self.w_in)
            except OSError:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def stop(self):
        if self.killed_at is None and self.alive():
            self.kill(signal.SIGKILL)


class Collector(threading.Thread):
    def __init__(self, path):
        super().__init__(daemon=True)
        if os.path.exists(path):
            os.unlink(path)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        os.chmod(path, 0o666)
        self.sock.listen(64)
        self.path = path
        self.events = []        # (time, host pid of the sender, text)
        self.start()

    def run(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            t = time.time()
            pid = struct.unpack("3i", c.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
            c.settimeout(2)
            data = b""
            try:
                while len(data) < 4096:
                    d = c.recv(4096)
                    if not d:
                        break
                    data += d
            except OSError:
                pass
            c.close()
            self.events.append((t, pid, data.decode("utf-8", "replace").strip()))

    def close(self):
        try:
            self.sock.close()
        finally:
            if os.path.exists(self.path):
                os.unlink(self.path)


def probe_pids(argv):
    want = [a.encode() for a in argv]
    found = []
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % p, "rb") as f:
                parts = f.read().split(b"\0")[:-1]
        except OSError:
            continue
        if parts == want:
            found.append(int(p))
    return found


def nspid(pid):
    try:
        for line in open("/proc/%d/status" % pid):
            if line.startswith("NSpid:"):
                return int(line.split()[-1])
    except OSError:
        pass
    return None
EXECLAB_PY_EOF
sudo chmod 644 "$BIN/execlab.py"

echo "[setup] crictl and nodectl for the node (the machine's own crictl and containerd are not used)..."
sudo tee "$BIN/crictl" >/dev/null <<CEOF
#!/bin/sh
# crictl for the node's containerd
exec $BIN/crictl.real -r unix://$SOCK -i unix://$SOCK "\$@"
CEOF
sudo tee "$BIN/nodectl" >/dev/null <<CEOF
#!/bin/bash
# nodectl start|stop|restart|status : starts and stops the node's containerd (configuration $ETC/containerd.toml; the PATH of the node starts with $NODEBIN). Must run as root.
PIDF="$RUN/containerd.pid"
[ "\$(id -u)" = 0 ] || { echo "nodectl: must run as root (use sudo)" >&2; exit 1; }
pid() { [ -s "\$PIDF" ] && cat "\$PIDF"; }
running() { local p; p=\$(pid) && [ -n "\$p" ] && [ "\$(cat /proc/\$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 $BIN/crictl version >/dev/null 2>&1; }
case "\${1:-}" in
    start)
        if running; then echo "nodectl: containerd is already running (pid \$(pid))"; exit 0; fi
        mkdir -p "$RUN" "$LIB/containerd"
        setsid -f bash -c 'echo \$\$ > "\$1"; exec env -i PATH="$NODEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" containerd --config "\$2"' _ "\$PIDF" "$ETC/containerd.toml" >> "$RUN/containerd.log" 2>&1 < /dev/null
        for _ in \$(seq 60); do up && { echo "nodectl: containerd started (pid \$(pid))"; exit 0; }; sleep 0.5; done
        echo "nodectl: containerd did not answer on $SOCK within 30 s; see $RUN/containerd.log" >&2; exit 1 ;;
    stop)
        p=\$(pid) || true
        if [ -n "\$p" ] && running; then
            kill -TERM "\$p" 2>/dev/null
            for _ in \$(seq 60); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
            kill -0 "\$p" 2>/dev/null && kill -KILL "\$p" 2>/dev/null
        fi
        rm -f "\$PIDF" "$SOCK" "$SOCK.ttrpc"
        echo "nodectl: containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) if running; then echo "containerd is running (pid \$(pid))"; else echo "containerd is not running"; exit 1; fi ;;
    *) echo "usage: nodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
sudo chmod 755 "$BIN/crictl" "$BIN/nodectl"

echo "[setup] the node's configuration: containerd's default (CRI plugin on, config version 2) with the node's directories, a local sandbox image and runc on the cgroupfs driver with its own root..."
sudo tee "$STATE_DIR/patch_config.py" >/dev/null <<'CONFIG_PY_EOF'
"""patch_config.py LIB RUN SOCK CNI PAUSE < default.toml > containerd.toml : containerd's default configuration with the node's directories (root, state, socket), no NRI,
a local sandbox image, runc on the cgroupfs driver with its own root."""
import re
import sys

lib, run, sock, cni, pause = sys.argv[1:6]
section = ""
runc_options = False
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
        runc_options = section.endswith(".runtimes.runc.options")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}/containerd'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}/containerd'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = f"{indent}restrict_oom_score_adj = true\n"      # do not require CAP_SYS_RESOURCE
    elif section.endswith(".cni") and k == "bin_dir":
        line = f"{indent}bin_dir = '{cni}/bin'\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = f"{indent}conf_dir = '{cni}/net.d'\n"
    elif k == "sandbox_image":
        line = f"{indent}sandbox_image = '{pause}'\n"
    elif runc_options and k == "SystemdCgroup":
        line = f"{indent}SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = f"{indent}Root = '{run}/runc'\n"
    sys.stdout.write(line)
CONFIG_PY_EOF
sudo env PATH="$NODEBIN:$PATH" containerd config default | sudo python3 "$STATE_DIR/patch_config.py" "$LIB" "$RUN" "$SOCK" "$LIB/cni" "$PAUSE_REF" | sudo tee "$ETC/containerd.toml" >/dev/null
sudo grep -q "$PAUSE_REF" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
sudo grep -q "Root = '$RUN/runc'" "$ETC/containerd.toml" || { echo "[setup] ERROR: could not set the root of runc in the configuration"; exit 1; }

echo "[setup] the pod's definition (crictl): one pod on the network of the node (there is no CNI), one container app (/bin/idle) with /probe (read-only), /lab (read-only) and /out..."
sudo tee "$PODS/main.pod.json" >/dev/null <<PEOF
{
  "metadata": {"name": "main", "namespace": "lab", "uid": "main-uid", "attempt": 1},
  "log_directory": "$RUN/log/main",
  "linux": {
    "cgroup_parent": "/$CASE_ID",
    "security_context": {"namespace_options": {"network": 2}}
  }
}
PEOF
sudo tee "$PODS/app.ctr.json" >/dev/null <<CEOF
{
  "metadata": {"name": "app"},
  "image": {"image": "$APP_REF"},
  "log_path": "app.log",
  "mounts": [
    {"container_path": "/probe", "host_path": "$PROBE_DIR", "readonly": true},
    {"container_path": "/lab", "host_path": "$LAB_DIR", "readonly": true},
    {"container_path": "/out", "host_path": "$OUT_DIR", "readonly": false}
  ],
  "linux": {}
}
CEOF

echo "[setup] starting the node and importing the two images (offline, namespace k8s.io)..."
sudo "$BIN/nodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$RUN/containerd.log" 2>/dev/null; exit 1; }
for t in app pause; do
    sudo "$NODEBIN/ctr" -a "$SOCK" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the image $t"; exit 1; }
done
sudo "$BIN/crictl" inspecti "$APP_REF" >/dev/null 2>&1 || { echo "[setup] ERROR: the image $APP_REF is not in the node"; exit 1; }

echo "[setup] starting the pod and its container..."
P=$(sudo "$BIN/crictl" runp "$PODS/main.pod.json") || { echo "[setup] ERROR: could not run the pod"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }
C=$(sudo "$BIN/crictl" create "$P" "$PODS/app.ctr.json" "$PODS/main.pod.json") || { echo "[setup] ERROR: could not create the container"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }
sudo "$BIN/crictl" start "$C" >/dev/null || { echo "[setup] ERROR: could not start the container"; sudo tail -5 "$RUN/containerd.log" | cut -c1-300; exit 1; }
for _ in $(seq 1 20); do [ "$(sudo "$BIN/crictl" inspect --output go-template --template '{{.status.state}}' "$C" 2>/dev/null)" = CONTAINER_RUNNING ] && break; sleep 0.5; done
[ "$(sudo "$BIN/crictl" inspect --output go-template --template '{{.status.state}}' "$C" 2>/dev/null)" = CONTAINER_RUNNING ] || { echo "[setup] ERROR: the container is not running"; exit 1; }
printf '%s %s\n' "$P" "$C" | sudo tee "$STATE_DIR/pod.txt" >/dev/null
sudo "$BIN/crictl" inspect --output go-template --template '{{.status.startedAt}}' "$C" | sudo tee "$STATE_DIR/started.txt" >/dev/null

echo "[setup] the record of what is true (hashes of the lab's files, the pod and the container with their IDs)..."
sudo sh -c "cd / && sha256sum '$NODEBIN/containerd' '$NODEBIN/containerd-shim-runc-v2' '$NODEBIN/runc' '$BIN/crictl.real' '$BIN/crictl' '$BIN/nodectl' '$BIN/execlab.py' '$ETC/containerd.toml' '$LAB_DIR/watch' '$STATE_DIR/box' '$PODS/main.pod.json' '$PODS/app.ctr.json' > '$STATE_DIR/lab.sha'"

echo "[setup] done. The node: $BIN/nodectl and $BIN/crictl (with sudo); the container app of the pod main runs /bin/idle; /probe in it is $PROBE_DIR, /out is $OUT_DIR."
