#!/bin/bash
set -e

CASE_ID="bench63752123"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the host side: runc, the bundles, the root file system, the tools (the solution's nsfork goes here)
RUN="/run/$CASE_ID"                          # runc's root (the state of the containers)
CACHE="/var/cache/$CASE_ID"                  # the downloaded runc (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # newct
ROOTFS="$LIB/rootfs"                         # the root file system of every container (read-only)
BUNDLES="$LIB/bundles"
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

echo "[setup] checking the tools: python3, curl, sudo, sha256sum, nsenter, gcc..."
for c in python3 curl sudo sha256sum nsenter; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
[ -w /proc/sys/kernel/ns_last_pid ] || sudo test -e /proc/sys/kernel/ns_last_pid || { echo "[setup] NOT APPLICABLE: this kernel has no /proc/sys/kernel/ns_last_pid (CONFIG_CHECKPOINT_RESTORE)"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), pid_max $(cat /proc/sys/kernel/pid_max)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$ROOTFS" "$BUNDLES" "$LIB/etc" "$RUN" "$RUN/log"

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
sudo install -m 755 -o root -g root "$CACHE/runc.$KARCH.$RUNC_VERSION" "$LIB/runc"
echo "  runc $("$LIB/runc" --version | head -1)"

echo "[setup] the root file system of the containers (one static program with the commands init, wr, cat, ls, id), built offline..."
sudo tee "$STATE_DIR/box.c" >/dev/null <<'BOX_C_EOF'
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *n = strrchr(argv[0], '/');
    n = n ? n + 1 : argv[0];
    if (!strcmp(n, "init")) {                        /* stays, and reaps whatever is handed to it */
        for (;;) { while (waitpid(-1, NULL, WNOHANG) > 0) {} usleep(100000); }
    }
    if (!strcmp(n, "wr") && argc > 2) {              /* wr FILE TEXT */
        FILE *f = fopen(argv[1], "w");
        if (!f) { fprintf(stderr, "wr: %s: ", argv[1]); perror(""); return 1; }
        if (fprintf(f, "%s\n", argv[2]) < 0 || fclose(f) != 0) { fprintf(stderr, "wr: %s: ", argv[1]); perror(""); return 1; }
        return 0;
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
    if (!strcmp(n, "id")) { printf("uid=%d gid=%d pid=%d\n", (int)getuid(), (int)getgid(), (int)getpid()); return 0; }
    fprintf(stderr, "%s: no such command (init, wr, cat, ls, id)\n", n);
    return 127;
}
BOX_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/box" "$STATE_DIR/box.c"
sudo install -d -m 755 "$ROOTFS/bin" "$ROOTFS/tmp" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/etc"
sudo install -m 755 "$STATE_DIR/box" "$ROOTFS/bin/box"
for c in init wr cat ls id; do sudo ln -sf box "$ROOTFS/bin/$c"; done

echo "[setup] the bundle template (runc spec: it keeps runc's default readonlyPaths, which include /proc/sys), newct, two containers..."
( cd "$WORK_DIR" && sudo "$LIB/runc" spec )
sudo mv "$WORK_DIR/config.json" "$LIB/etc/config.template.json"
sudo tee "$BIN/newct" >/dev/null <<'NEWCT_EOF'
#!/usr/bin/env python3
"""newct [--truth]: a new running container (runc's default spec: its own PID, mount, network, IPC and UTS namespaces; /proc/sys and other paths read-only);
its program is /bin/init. Prints its id, or with --truth the facts of it as JSON."""
import json, os, secrets, subprocess, sys, time

CASE = "bench63752123"
LIB, RUN = "/var/lib/" + CASE, "/run/" + CASE
RUNC = LIB + "/runc"
name = "ct" + secrets.token_hex(4)
bundle = "%s/bundles/%s" % (LIB, name)
os.makedirs(bundle)
cfg = json.load(open(LIB + "/etc/config.template.json"))
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["/bin/init"]
cfg["root"] = {"path": LIB + "/rootfs", "readonly": True}
cfg["hostname"] = name
cfg["linux"]["cgroupsPath"] = "/%s/%s" % (CASE, name)
json.dump(cfg, open(bundle + "/config.json", "w"), indent=1)
log = open("%s/log/%s.log" % (RUN, name), "w")
subprocess.run([RUNC, "--root", RUN + "/runc", "run", "-d", "--bundle", bundle, name], stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
pid = json.loads(subprocess.run([RUNC, "--root", RUN + "/runc", "state", name], capture_output=True, text=True, check=True).stdout)["pid"]
for _ in range(100):
    if os.path.exists("/proc/%d/root/bin/init" % pid):
        break
    time.sleep(0.05)
start = int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19])
if "--truth" in sys.argv:
    print(json.dumps({"container": name, "init_pid": pid, "init_start": start, "pidns": os.readlink("/proc/%d/ns/pid" % pid)}))
else:
    print(name)
NEWCT_EOF
sudo chmod 755 "$BIN/newct"
sudo sh -c "'$BIN/newct' > '$LIB/etc/target.id'; '$BIN/newct' > '$LIB/etc/other.id'; chmod 644 '$LIB/etc/target.id' '$LIB/etc/other.id'"

echo "[setup] fingerprint of the host-side files (the oracle checks it again)..."
sudo sh -c "( find '$LIB/runc' '$BIN' '$LIB/etc' '$ROOTFS' -type f -exec sha256sum {} + ; find '$ROOTFS' -type l -printf '%p -> %l\n' ) | sort | sha256sum > '$STATE_DIR/lab.sha'"

echo "[setup] done: containers $(cat "$LIB/etc/target.id") and $(cat "$LIB/etc/other.id") run (sudo $LIB/runc --root $RUN/runc list)"
