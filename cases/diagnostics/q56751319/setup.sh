#!/bin/bash
set -e

CASE_ID="bench56751319"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the cell: Garden's depot, the cell's runc, the tools (the solution's gexec goes here)
RUN="/run/$CASE_ID"                          # the cell's runc root, the list of instances, the log of the cell's runc
CACHE="/var/cache/$CASE_ID"                  # the downloaded runc (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # newcell, cfdot
PKG="$LIB/packages/runc"                     # like /var/vcap/packages/runc: bin/runc is the runc of the cell, runc.bin the program behind it
DEPOT="$LIB/data/garden/depot"               # one directory per container: <handle>/config.json (the bundle)
ROOTFS="$LIB/data/rootfs"                    # the root file system of every container (read-only)
ETC="$LIB/etc"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                 # the oracle's own record (root only)
RUNC_VERSION="v1.1.12"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
case "$(uname -m)" in
    x86_64|amd64)   KARCH="amd64"; RUNC_SHA="aadeef400b8f05645768c1476d1023f7875b78f52c7ff1967a6dbce236b8cbd8" ;;
    aarch64|arm64)  KARCH="arm64"; RUNC_SHA="879f910a05c95c10c64ad8eb7d5e3aa8e4b30e65587b3d68e009a3565aed5bb8" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking the tools: python3, curl, sudo, sha256sum, gcc..."
for c in python3 curl sudo sha256sum; do
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
sudo install -d -m 755 "$LIB" "$BIN" "$PKG/bin" "$ETC" "$DEPOT" "$ROOTFS" "$RUN" "$RUN/garden"

sudo install -d -m 755 "$CACHE"
if ! { [ -f "$CACHE/runc.$KARCH.$RUNC_VERSION" ] && echo "$RUNC_SHA  $CACHE/runc.$KARCH.$RUNC_VERSION" | sha256sum -c --quiet - 2>/dev/null; }; then
    echo "[setup] downloading runc $RUNC_VERSION ($KARCH)..."
    sudo rm -f "$CACHE/runc.$KARCH.$RUNC_VERSION"
    curl -fsSL --retry 3 --max-time 600 -o "$WORK_DIR/runc.dl" "https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$KARCH" \
        || { echo "[setup] ERROR: could not download runc"; exit 1; }
    echo "$RUNC_SHA  $WORK_DIR/runc.dl" | sha256sum -c --quiet - || { echo "[setup] ERROR: runc does not match its sha256"; exit 1; }
    sudo install -m 644 "$WORK_DIR/runc.dl" "$CACHE/runc.$KARCH.$RUNC_VERSION"
    rm -f "$WORK_DIR/runc.dl"
fi
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$PKG/runc.bin"
# the runc of the cell is a two-line wrapper that notes every call in a log (the oracle reads which runc commands the solution ran), then runs the real program
sudo tee "$PKG/bin/runc" >/dev/null <<WRAP_EOF
#!/bin/bash
printf '%s\t%s\n' "\$\$" "\$*" >> "$RUN/runc-calls.log"
exec "$PKG/runc.bin" "\$@"
WRAP_EOF
sudo chmod 755 "$PKG/bin/runc"
sudo install -m 622 /dev/null "$RUN/runc-calls.log"
echo "  runc $("$PKG/runc.bin" --version | head -1)"

echo "[setup] the root file system of the containers (one static program with the commands init, cat, ls, id), built offline..."
sudo tee "$STATE_DIR/box.c" >/dev/null <<'BOX_C_EOF'
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "init") && argc > 2) {            /* init FILE TEXT: write the file, then stay */
        FILE *f = fopen(argv[1], "w");
        if (!f) { perror(argv[1]); return 1; }
        fprintf(f, "%s\n", argv[2]);
        fclose(f);
        for (;;) pause();
    }
    if (!strcmp(n, "cat")) {
        char buf[4096];
        int rc = 0;
        for (int i = 1; i < argc; i++) {
            int fd = open(argv[i], O_RDONLY);
            ssize_t k;
            if (fd < 0) { perror(argv[i]); rc = 1; continue; }
            while ((k = read(fd, buf, sizeof buf)) > 0) if (write(1, buf, k) < 0) return 1;
            close(fd);
        }
        return rc;
    }
    if (!strcmp(n, "ls")) {
        DIR *d = opendir(argc > 1 ? argv[1] : ".");
        struct dirent *e;
        if (!d) { perror("ls"); return 1; }
        while ((e = readdir(d))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) puts(e->d_name);
        return 0;
    }
    if (!strcmp(n, "id")) { printf("uid=%d gid=%d\n", (int)getuid(), (int)getgid()); return 0; }
    fprintf(stderr, "%s: no such command (init, cat, ls, id)\n", n);
    return 127;
}
BOX_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/box" "$STATE_DIR/box.c"
sudo install -d -m 755 "$ROOTFS/bin" "$ROOTFS/tmp" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/etc" "$ROOTFS/home/vcap/app"
sudo install -m 755 "$STATE_DIR/box" "$ROOTFS/bin/box"
for c in init cat ls id; do sudo ln -sf box "$ROOTFS/bin/$c"; done

echo "[setup] the bundle template (runc spec), the runc root of the cell, the tools newcell and cfdot..."
( cd "$WORK_DIR" && sudo "$PKG/runc.bin" spec )
sudo mv "$WORK_DIR/config.json" "$ETC/config.template.json"
sudo sh -c "printf '%s\n' '$RUN/garden/runc' > '$ETC/runc-root'"
sudo tee "$BIN/newcell" >/dev/null <<'NEWCELL_EOF'
#!/usr/bin/env python3
"""newcell [--truth] [--fresh-root]: a new running container in the cell: the instance guid is its Garden handle, its bundle is DEPOT/<guid>, runc keeps its state
below a root; the file /tmp/rXXXXXXXX.txt exists only inside the container (tmpfs). Prints the guid, or with --truth the facts of it as JSON."""
import json, os, secrets, subprocess, sys, time, uuid

CASE = "bench56751319"
LIB, RUN = "/var/lib/" + CASE, "/run/" + CASE
RUNC = LIB + "/packages/runc/runc.bin"          # not the wrapper: the log is for the solution's calls only
DEPOT, ROOTFS = LIB + "/data/garden/depot", LIB + "/data/rootfs"

root = open(LIB + "/etc/runc-root").read().strip()
if "--fresh-root" in sys.argv:
    root = "%s/garden/r%s" % (RUN, secrets.token_hex(3))
os.makedirs(root, mode=0o700, exist_ok=True)
guid = str(uuid.uuid4())
fname = "/tmp/r%s.txt" % secrets.token_hex(4)
content = "vcap-" + secrets.token_hex(8)
bundle = "%s/%s" % (DEPOT, guid)
os.makedirs(bundle + "/processes")
cfg = json.load(open(LIB + "/etc/config.template.json"))
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["/bin/init", fname, content]
cfg["root"] = {"path": ROOTFS, "readonly": True}
cfg["hostname"] = guid[:8]
cfg["mounts"].append({"destination": "/tmp", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "nodev", "mode=1777"]})
cfg["linux"]["cgroupsPath"] = "/%s/garden/%s" % (CASE, guid)
json.dump(cfg, open(bundle + "/config.json", "w"), indent=1)
log = open("%s/garden/%s.log" % (RUN, guid), "w")
subprocess.run([RUNC, "--root", root, "run", "-d", "--bundle", bundle, guid], stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
pid = json.loads(subprocess.run([RUNC, "--root", root, "state", guid], capture_output=True, text=True, check=True).stdout)["pid"]
for _ in range(100):                            # the file appears when the container's init has written it
    try:
        if open("/proc/%d/root%s" % (pid, fname)).read().strip() == content:
            break
    except OSError:
        pass
    time.sleep(0.05)
else:
    sys.exit("newcell: the container did not come up")
start = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
with open(RUN + "/garden/instances.jsonl", "a") as f:
    f.write(json.dumps({"process_guid": str(uuid.uuid4()) + "-1", "index": 0, "instance_guid": guid, "state": "RUNNING"}) + "\n")
if "--truth" in sys.argv:
    print(json.dumps({"instance_guid": guid, "handle": guid, "runc_root": root, "init_pid": pid, "init_start": start, "file": fname, "content": content}))
else:
    print(guid)
NEWCELL_EOF
sudo chmod 755 "$BIN/newcell"
sudo tee "$BIN/cfdot" >/dev/null <<CFDOT_EOF
#!/bin/bash
# stand-in for cfdot (the Diego BBS client): the instances of the cell, one JSON object per line
[ "\$1" = actual-lrps ] || { echo "cfdot: only 'actual-lrps' is available here" >&2; exit 2; }
cat "$RUN/garden/instances.jsonl"
CFDOT_EOF
sudo chmod 755 "$BIN/cfdot"
sudo install -m 600 /dev/null "$RUN/garden/instances.jsonl"

echo "[setup] three app instances on the cell..."
for _ in 1 2 3; do sudo "$BIN/newcell" >/dev/null; done
sudo chmod 644 "$RUN/garden/instances.jsonl"

echo "[setup] fingerprint of the cell's files (the oracle checks it again)..."
sudo sh -c "( find '$PKG' '$BIN' '$ETC' '$ROOTFS' -type f -exec sha256sum {} + ; find '$PKG' '$BIN' '$ETC' '$ROOTFS' -type l -printf '%p -> %l\n' ) | sort | sha256sum > '$STATE_DIR/lab.sha'"
sudo sh -c "date +%s > '$STATE_DIR/ready'"

echo "[setup] done: the cell has $(sudo wc -l < "$RUN/garden/instances.jsonl") instances (see: $BIN/cfdot actual-lrps); the depot is $DEPOT"
