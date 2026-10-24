#!/bin/bash
set -e

CASE_ID="bench65917162"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="/var/lib/$CASE_ID"                      # the host side: runc, the bundles, the root file system, the tools (the solution's mkct goes here)
RUN="/run/$CASE_ID"                          # runc's root (the state of the containers)
CACHE="/var/cache/$CASE_ID"                  # the downloaded runc (kept by cleanup, checked by sha256 at every setup)
BIN="$LIB/bin"                               # newct
ROOTFS="$LIB/rootfs"                         # the root file system of every container
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

echo "[setup] checking the tools: python3, curl, sudo, sha256sum, gcc..."
for c in python3 curl sudo sha256sum; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v gcc >/dev/null || { echo "[setup] ERROR: gcc could not be installed"; exit 1; }
[ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ] || { echo "[setup] NOT APPLICABLE: user namespaces are disabled (user.max_user_namespaces)"; exit 1; }
echo "  host: $(uname -m), kernel $(uname -r), user.max_user_namespaces $(cat /proc/sys/user/max_user_namespaces)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting the work dir (the record of what is true lives in a root-only subdirectory)..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
sudo install -d -m 755 "$LIB" "$BIN" "$ROOTFS" "$BUNDLES" "$BUNDLES/bad" "$LIB/etc" "$RUN" "$RUN/log"

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

echo "[setup] the root file system (init, and probe: the question's \`unshare -Umpfr mount -t proc proc /proc\` with a report), built offline..."
sudo tee "$STATE_DIR/init.c" >/dev/null <<'INIT_C_EOF'
#include <sys/wait.h>
#include <unistd.h>
int main(void) { for (;;) { while (waitpid(-1, NULL, WNOHANG) > 0) {} usleep(100000); } }
INIT_C_EOF
sudo tee "$STATE_DIR/probe.c" >/dev/null <<'PROBE_C_EOF'
/* probe [plain]: unshare user+mount+PID namespaces (plain: mount+PID only), as `unshare -Umpfr` does; in the child (pid 1 of the new PID namespace) mount a new proc on /proc;
   print one JSON line: the result of the mount, how many mounts below /proc the new mount namespace inherited, the pid the child sees for itself in the /proc it ends up with,
   and the pids that /proc lists. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <unistd.h>

static void wfile(const char *p, const char *s) { int fd = open(p, O_WRONLY); if (fd >= 0) { if (write(fd, s, strlen(s)) < 0) {} close(fd); } }
static int submounts(void) {
    FILE *f = fopen("/proc/self/mountinfo", "r"); char line[4096]; int n = 0;
    if (!f) return -1;
    while (fgets(line, sizeof line, f)) { int a, b; char mp[1024]; if (sscanf(line, "%d %d %*s %*s %1023s", &a, &b, mp) == 3 && !strncmp(mp, "/proc/", 6)) n++; }
    fclose(f); return n;
}
int main(int argc, char **argv) {
    char buf[64]; int uid = getuid(), gid = getgid(), plain = argc > 1 && !strcmp(argv[1], "plain");
    if (unshare((plain ? 0 : CLONE_NEWUSER) | CLONE_NEWNS | CLONE_NEWPID) < 0) { printf("{\"error\": \"unshare: %s\"}\n", strerror(errno)); return 1; }
    if (!plain) {
        wfile("/proc/self/setgroups", "deny");
        snprintf(buf, sizeof buf, "0 %d 1\n", uid); wfile("/proc/self/uid_map", buf);
        snprintf(buf, sizeof buf, "0 %d 1\n", gid); wfile("/proc/self/gid_map", buf);
    }
    pid_t p = fork();
    if (p < 0) return 1;
    if (p == 0) {
        int before = submounts();
        mount("none", "/", NULL, MS_REC | MS_PRIVATE, NULL);
        int rc = mount("proc", "/proc", "proc", 0, NULL), e = errno;
        pid_t c = fork();
        if (c == 0) { for (;;) pause(); }
        int self = 0; FILE *f = fopen("/proc/self/stat", "r"); if (f) { if (fscanf(f, "%d", &self) != 1) self = -1; fclose(f); }
        printf("{\"mount_rc\": %d, \"errno\": \"%s\", \"submounts_before\": %d, \"self_pid\": %d, \"pids\": [", rc, rc ? strerror(e) : "", before, self);
        DIR *d = opendir("/proc"); struct dirent *en; int ids[4096]; int n = 0;
        while (d && (en = readdir(d))) { int v = 0; const char *s = en->d_name; if (*s < '0' || *s > '9') continue; while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0'; if (!*s && n < 4096) ids[n++] = v; }
        for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (ids[j] < ids[i]) { int t = ids[i]; ids[i] = ids[j]; ids[j] = t; }
        for (int i = 0; i < n; i++) printf("%s%d", i ? ", " : "", ids[i]);
        printf("]}\n"); fflush(stdout);
        kill(c, 9);
        return 0;
    }
    waitpid(p, NULL, 0);
    return 0;
}
PROBE_C_EOF
sudo gcc -static -Os -s -w -o "$STATE_DIR/init" "$STATE_DIR/init.c"
sudo gcc -static -Os -s -w -o "$STATE_DIR/probe" "$STATE_DIR/probe.c"
sudo install -d -m 755 "$ROOTFS/bin" "$ROOTFS/proc" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/tmp" "$ROOTFS/etc"
sudo install -m 755 "$STATE_DIR/init" "$ROOTFS/bin/init"
sudo install -m 755 "$STATE_DIR/probe" "$ROOTFS/bin/probe"

echo "[setup] the bad bundle (runc's default spec; every capability the host lets runc have; no seccomp, no AppArmor, no user namespace of the container), newct, one running container..."
( cd "$WORK_DIR" && sudo "$LIB/runc" spec )
sudo env LIB="$LIB" WORK_DIR="$WORK_DIR" python3 - <<'PY_EOF'
import json, os
LIB, W = os.environ["LIB"], os.environ["WORK_DIR"]
names = ("CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID KILL SETGID SETUID SETPCAP LINUX_IMMUTABLE NET_BIND_SERVICE NET_BROADCAST NET_ADMIN NET_RAW IPC_LOCK IPC_OWNER "
         "SYS_MODULE SYS_RAWIO SYS_CHROOT SYS_PTRACE SYS_PACCT SYS_ADMIN SYS_BOOT SYS_NICE SYS_RESOURCE SYS_TIME SYS_TTY_CONFIG MKNOD LEASE AUDIT_WRITE AUDIT_CONTROL SETFCAP "
         "MAC_OVERRIDE MAC_ADMIN SYSLOG WAKE_ALARM BLOCK_SUSPEND AUDIT_READ PERFMON BPF CHECKPOINT_RESTORE").split()
last = int(open("/proc/sys/kernel/cap_last_cap").read())
bnd = int([l for l in open("/proc/self/status") if l.startswith("CapBnd")][0].split()[1], 16)
caps = ["CAP_" + n for i, n in enumerate(names) if i <= last and bnd >> i & 1]      # "--cap-add ALL": all that runc itself holds
c = json.load(open(W + "/config.json"))
c["process"]["terminal"] = False
c["process"]["args"] = ["/bin/init"]
for k in ("bounding", "effective", "inheritable", "permitted", "ambient"):
    c["process"]["capabilities"][k] = caps
c["root"] = {"path": LIB + "/rootfs", "readonly": False}
c["hostname"] = "closedboxx"
c["linux"]["cgroupsPath"] = "/bench65917162/template"
assert "seccomp" not in c["linux"] and "apparmorProfile" not in c["process"]
assert c["linux"]["maskedPaths"] and c["linux"]["readonlyPaths"]
assert not any(n["type"] == "user" for n in c["linux"]["namespaces"])
json.dump(c, open(LIB + "/bundles/bad/config.json", "w"), indent=1)
PY_EOF
sudo tee "$BIN/newct" >/dev/null <<'NEWCT_EOF'
#!/usr/bin/env python3
"""newct NAME [--unconfined]: a running container NAME from the bad bundle (bundles/bad/config.json, copied to bundles/NAME). With --unconfined both maskedPaths and readonlyPaths are
emptied (Docker's --security-opt systempaths=unconfined): only for the lab's own checks."""
import json, os, subprocess, sys

CASE = "bench65917162"
LIB, RUN = "/var/lib/" + CASE, "/run/" + CASE
name = sys.argv[1]
bundle = "%s/bundles/%s" % (LIB, name)
os.makedirs(bundle)
cfg = json.load(open(LIB + "/bundles/bad/config.json"))
cfg["linux"]["cgroupsPath"] = "/%s/%s" % (CASE, name)
if "--unconfined" in sys.argv:
    cfg["linux"]["maskedPaths"] = []
    cfg["linux"]["readonlyPaths"] = []
json.dump(cfg, open(bundle + "/config.json", "w"), indent=1)
log = open("%s/log/%s.log" % (RUN, name), "w")
subprocess.run([LIB + "/runc", "--root", RUN + "/runc", "run", "-d", "--bundle", bundle, name], stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True)
print(name)
NEWCT_EOF
sudo chmod 755 "$BIN/newct"
sudo sh -c "'$BIN/newct' closedboxx > /dev/null; echo closedboxx > '$LIB/etc/bad.id'; chmod 644 '$LIB/etc/bad.id'"

echo "[setup] fingerprint of the host-side files, the bad bundle included (the oracle checks it again)..."
sudo sh -c "( find '$LIB/runc' '$BIN' '$LIB/etc' '$ROOTFS' '$BUNDLES/bad' -type f -exec sha256sum {} + ) | sort | sha256sum > '$STATE_DIR/lab.sha'"

echo "[setup] done: the container $(cat "$LIB/etc/bad.id") runs from $BUNDLES/bad (sudo $LIB/runc --root $RUN/runc list)"
