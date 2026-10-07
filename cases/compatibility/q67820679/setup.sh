#!/bin/bash
set -e

CASE_ID="bench67820679"
RUN_BASE="/run/$CASE_ID"              # socket, pid files and runtime state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root
CTD_SOCK="$RUN_BASE/containerd.sock"
NS="bench67820679"                    # the containerd namespace of the container (NOT "default")
CONTAINER="bench67820679-app"

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ROOTFS="$STATE_DIR/rootfs"
OUT_DIR="$WORK_DIR/out"

CTR="sudo ctr -a $CTD_SOCK"

echo "[setup] checking containerd, ctr, runc and python3 are installed (the runtime under test; same"
echo "[setup] assumption as the other containerd cases)..."
for b in containerd ctr runc python3; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
containerd --version
# The container gets no image: its user-land (a shell, id, cat, sleep, ...) is the host's /usr, bind-mounted
# read-only, and /bin, /sbin, /lib, /lib64 are links into it (as in the other containerd cases that need
# a shell without downloading an image). That needs a host whose /bin, /sbin and /lib are links to /usr/...
for d in bin sbin lib; do
    [ -L "/$d" ] || { echo "[setup] ERROR: /$d is not a link into /usr on this host (merged-/usr layout needed)"; exit 1; }
done
[ -x /usr/bin/sleep ] && [ -x /bin/sh ] && [ -x /usr/bin/id ] || { echo "[setup] ERROR: sleep, id or sh missing on the host"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR" "$STATE_DIR"

# Detached daemon launcher: $1 pid file, $2 log file, rest = the command. The pid file gets the pid of
# the daemon itself (exec keeps the pid); setsid + all three fds redirected so it outlives this
# script and does not hold the harness's pipes open.
start_daemon() {
    sudo setsid -f bash -c 'echo $$ > "$1"; log="$2"; shift 2; exec "$@" >"$log" 2>&1 </dev/null' \
        _ "$1" "$2" "${@:3}" </dev/null >/dev/null 2>&1
}

echo "[setup] building the root file system of the container (empty directories, links into /usr, a"
echo "[setup] random token in /unique.txt and the script /probe.sh)..."
TOKEN="tok-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
mkdir -p "$ROOTFS"/{usr,proc,sys,dev,tmp,run,etc,out}
chmod 1777 "$ROOTFS/tmp"
for d in bin sbin lib lib64 lib32 libx32; do
    [ -L "/$d" ] && ln -s "$(readlink "/$d")" "$ROOTFS/$d"
done
printf '%s\n' "$TOKEN" > "$ROOTFS/unique.txt"
chmod 644 "$ROOTFS/unique.txt"
cat > "$ROOTFS/probe.sh" <<'PEOF'
#!/bin/sh
# Writes ONE line into /out/probe.txt telling what this process is: the token of the container, the
# user and group it runs as, its pid namespace and cgroup as it sees them, its pid in that namespace.
tok=$(cat /unique.txt) || exit 3
uid=$(id -u)
gid=$(id -g)
pidns=$(readlink /proc/self/ns/pid)
cg=$(cat /proc/self/cgroup | tr '\n' ',')
printf '%s|uid=%s|gid=%s|pidns=%s|cgroup=%s|nspid=%s\n' "$tok" "$uid" "$gid" "$pidns" "$cg" "$$" > "${PROBE_OUT:-/out/probe.txt}" || exit 2
exit 0
PEOF
chmod 755 "$ROOTFS/probe.sh"
sudo sh -c 'umask 077; printf "%s\n" "$1" > "$2"' _ "$TOKEN" "$STATE_DIR/token"

echo "[setup] creating the output directory the container mounts at /out (world-writable: the probe runs"
echo "[setup] as an unprivileged user, uid 1234)..."
mkdir -p "$OUT_DIR"
chmod 0777 "$OUT_DIR"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own default"
echo "[setup] config for the installed version, moved into that root/state, NRI off)..."
cat > "$STATE_DIR/patch_config.py" <<'PYEOF'
import re
import sys

lib, run, sock = sys.argv[1:4]
section = ""
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = f"{indent}root = '{lib}'\n"
    elif section == "" and k == "state":
        line = f"{indent}state = '{run}'\n"
    elif section == "grpc" and k == "address":
        line = f"{indent}address = '{sock}'\n"
    elif section == "ttrpc" and k == "address":
        line = f"{indent}address = '{sock}.ttrpc'\n"
    elif "nri" in section and k == "disable":
        line = f"{indent}disable = true\n"
    elif k == "restrict_oom_score_adj":
        # do not require CAP_SYS_RESOURCE (absent in unprivileged or nested environments)
        line = f"{indent}restrict_oom_score_adj = true\n"
    sys.stdout.write(line)
PYEOF
sudo mkdir -p "$RUN_BASE" "$LIB_BASE/containerd"
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CTD_SOCK" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
start_daemon "$RUN_BASE/containerd.pid" "$RUN_BASE/containerd.log" containerd --config "$RUN_BASE/config.toml"
for _ in $(seq 1 60); do
    [ -S "$CTD_SOCK" ] && $CTR version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! $CTR version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $CTD_SOCK"

echo "[setup] starting the container $CONTAINER in the containerd namespace $NS: a shell that loops"
echo "[setup] forever, as the unprivileged user 1234:1234, with the host's /usr (read-only) and $OUT_DIR"
echo "[setup] (at /out)..."
timeout -k 5 90 $CTR -n "$NS" run -d --rootfs \
    --user 1234:1234 \
    --mount "type=bind,src=/usr,dst=/usr,options=rbind:ro" \
    --mount "type=bind,src=$OUT_DIR,dst=/out,options=rbind:rw" \
    "$ROOTFS" "$CONTAINER" /bin/sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1 \
    || { echo "[setup] ERROR: ctr could not start the container"; sudo tail -5 "$RUN_BASE/containerd.log" 2>/dev/null; exit 1; }
PID=""
for _ in $(seq 1 30); do
    PID=$($CTR -n "$NS" tasks ls 2>/dev/null | awk -v n="$CONTAINER" '$1==n && $3=="RUNNING" {print $2}')
    [ -n "$PID" ] && break
    sleep 0.5
done
[ -n "$PID" ] || { echo "[setup] ERROR: the task of $CONTAINER is not RUNNING"; exit 1; }
echo "  -> $CONTAINER RUNNING, init pid $PID"

echo "[setup] recording the identity of the daemon and of the task (pid + start time, pid namespace)..."
P=$(cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"
echo "$PID $(sudo awk '{print $22}' /proc/$PID/stat)" > "$STATE_DIR/task.id"
sudo readlink "/proc/$PID/ns/pid" > "$STATE_DIR/task.pidns"
sudo readlink /proc/self/ns/pid > "$STATE_DIR/host.pidns"

echo "[setup] starting the event recorder (what containerd itself reports about tasks and execs; the"
echo "[setup] oracle reads it)..."
start_daemon "$STATE_DIR/events.pid" "$STATE_DIR/events.log" ctr -a "$CTD_SOCK" events
sleep 1
P=$(cat "$STATE_DIR/events.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/events.id"

echo "[setup] proving the recorder sees an exec (one exec of the harness; its exec ID is remembered, so"
echo "[setup] the oracle does not count it as the solution's)..."
HID="harness-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
echo "$HID" > "$STATE_DIR/ignore_ids"
timeout -k 5 30 $CTR -n "$NS" tasks exec --exec-id "$HID" "$CONTAINER" \
    /bin/sh -c 'PROBE_OUT=/tmp/harness.txt /probe.sh' </dev/null >/dev/null 2>&1 \
    || { echo "[setup] ERROR: the harness exec into $CONTAINER failed"; exit 1; }
for _ in $(seq 1 20); do
    grep -q "/tasks/exit .*\"id\":\"$HID\"" "$STATE_DIR/events.log" 2>/dev/null && break
    sleep 0.5
done
grep -q "/tasks/exit .*\"id\":\"$HID\"" "$STATE_DIR/events.log" \
    || { echo "[setup] ERROR: the event recorder did not see the harness exec"; exit 1; }
sudo rm -f "$ROOTFS/tmp/harness.txt"

echo "[setup] done. $CONTAINER runs in the namespace $NS of the private containerd; no solution has"
echo "[setup] exec'd into it yet."
