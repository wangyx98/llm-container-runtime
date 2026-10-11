#!/bin/bash
set -e

CASE_ID="bench75346313"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"              # sockets, pid files, logs and runtime state of the private containerd and dockerd
LIB_BASE="/var/lib/$CASE_ID"          # their roots and configs (not in /run: it is mounted noexec on many hosts)
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record and the helpers
TOOLS="$WORK_DIR/tools"               # the PATH of the daemon: the tools of the machine as the update left them (no apparmor_parser)
CSOCK="$RUN_BASE/containerd.sock"
AA_ENABLED=/sys/module/apparmor/parameters/enabled
AA_PROFILES=/sys/kernel/security/apparmor/profiles

echo "[setup] this case needs a VM whose kernel has AppArmor enabled and that runs no other Docker daemon (it unloads the docker-default profile)..."
for b in containerd ctr runc dockerd docker python3 gcc; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
PARSER=$(PATH="$PATH:/usr/sbin:/sbin" command -v apparmor_parser || true)
[ -n "$PARSER" ] || { echo "[setup] ERROR: apparmor_parser is not installed on this VM (the case needs the real one to restore): sudo apt install apparmor"; exit 1; }
[ "$(cat $AA_ENABLED 2>/dev/null)" = "Y" ] || { echo "[setup] ERROR: AppArmor is not enabled in this kernel ($AA_ENABLED is not Y): this case cannot run here"; exit 1; }
sudo test -r "$AA_PROFILES" || { echo "[setup] ERROR: $AA_PROFILES is not readable: securityfs is not mounted"; exit 1; }
dockerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

# any other dockerd would lose its docker-default profile below: it would not be able to start containers any more
for pid in $(pgrep -x dockerd 2>/dev/null); do
    grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null && continue   # a daemon that has exited and is not reaped yet
    echo "[setup] ERROR: another Docker daemon is running (pid $pid: $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-120))."
    echo "[setup]        This case unloads the docker-default AppArmor profile from the kernel; stop that daemon first (for example: sudo systemctl stop docker docker.socket)."
    exit 1
done

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$TOOLS"
chmod 755 "$WORK_DIR" "$STATE_DIR"
sudo mkdir -p "$RUN_BASE/exec" "$LIB_BASE/containerd" "$LIB_BASE/docker" "$LIB_BASE/etc"
cp "$CASE_DIR"/helpers/app.c "$CASE_DIR"/helpers/mkimg.py "$CASE_DIR"/helpers/mktools.py "$CASE_DIR"/helpers/patch_config.py "$STATE_DIR/"
cp "$CASE_DIR"/helpers/start-docker.sh "$WORK_DIR/start-docker.sh"
chmod 755 "$WORK_DIR/start-docker.sh"
sha256sum "$STATE_DIR"/app.c "$STATE_DIR"/mkimg.py "$STATE_DIR"/mktools.py "$STATE_DIR"/patch_config.py "$WORK_DIR"/start-docker.sh | awk '{print $1}' > "$STATE_DIR/helpers.sha"
echo "$PARSER" > "$STATE_DIR/parser.path"
cd "$WORK_DIR"

echo "[setup] the workload: a static program (serve / probe / attr) in a one-layer image, as an archive that 'docker load' takes..."
gcc -static -O2 -o "$STATE_DIR/app" "$STATE_DIR/app.c"
python3 "$STATE_DIR/mkimg.py" bench/app:1 "$STATE_DIR/app" "$WORK_DIR/app.tar" > "$STATE_DIR/image.json"
echo "  -> $WORK_DIR/app.tar holds bench/app:1"

echo "[setup] the tool set the update left: every tool of the machine except apparmor_parser, in $TOOLS (the PATH of the daemon)..."
N=$(python3 "$STATE_DIR/mktools.py" "$TOOLS" apparmor_parser)
[ -e "$TOOLS/runc" ] && [ ! -e "$TOOLS/apparmor_parser" ] || { echo "[setup] ERROR: could not build the tool set"; exit 1; }
echo "  -> $N tools, no apparmor_parser (the installed one is $PARSER)"

echo "[setup] starting the private containerd (it needs no AppArmor parser)..."
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE/containerd" "$RUN_BASE" "$CSOCK" \
    | sudo tee "$LIB_BASE/etc/config.toml" >/dev/null
sudo sha256sum "$LIB_BASE/etc/config.toml" | awk '{print $1}' > "$STATE_DIR/config.sha"
sudo setsid -f bash -c 'echo $$ > "$1"; exec containerd --config "$2" >"$3" 2>&1 </dev/null' \
    _ "$RUN_BASE/containerd.pid" "$LIB_BASE/etc/config.toml" "$RUN_BASE/containerd.log" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$CSOCK" ] && sudo ctr -a "$CSOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || { echo "[setup] ERROR: the private containerd did not come up"; sudo tail -10 "$RUN_BASE/containerd.log"; exit 1; }
P=$(sudo cat "$RUN_BASE/containerd.pid")
echo "$P $(sudo awk '{print $22}' /proc/$P/stat)" > "$STATE_DIR/containerd.id"

echo "[setup] the state after the update: the docker-default profile is not loaded in the kernel (a restart of Docker has to load it again)..."
if sudo grep -q '^docker-default ' "$AA_PROFILES"; then
    echo -n docker-default | sudo tee /sys/kernel/security/apparmor/.remove >/dev/null
fi
sudo grep -q '^docker-default ' "$AA_PROFILES" && { echo "[setup] ERROR: could not unload docker-default"; exit 1; }
echo "  -> docker-default is not loaded"

echo "[setup] the state after the update: Docker is started with the script of the case, the workload image is loaded and a container is started: it fails,"
echo "[setup] because dockerd has no apparmor_parser on its PATH (depending on the Docker version, the daemon itself may refuse to start)..."
DSOCK="$RUN_BASE/docker.sock"
set +e
bash "$WORK_DIR/start-docker.sh" > "$STATE_DIR/first-start.log" 2>&1
echo $? > "$STATE_DIR/first-start.rc"
echo none > "$STATE_DIR/first-run.rc"
: > "$STATE_DIR/first-run.log"
if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then
    docker -H "unix://$DSOCK" load -i "$WORK_DIR/app.tar" >> "$STATE_DIR/first-run.log" 2>&1
    docker -H "unix://$DSOCK" run -d --name bench75346313-probe bench/app:1 >> "$STATE_DIR/first-run.log" 2>&1
    echo $? > "$STATE_DIR/first-run.rc"
    docker -H "unix://$DSOCK" rm -f bench75346313-probe >/dev/null 2>&1
    docker -H "unix://$DSOCK" rmi bench/app:1 >/dev/null 2>&1
fi
set -e
{ cat "$STATE_DIR/first-start.log" "$STATE_DIR/first-run.log"; sudo grep -i apparmor "$RUN_BASE/dockerd.log" 2>/dev/null; } > "$STATE_DIR/evidence.log"
sed 's/^/  | /' "$STATE_DIR/evidence.log" | cut -c1-260 | head -12

echo "[setup] done. AppArmor is on, docker-default is not loaded, the tools of the daemon have no apparmor_parser: the lab's Docker cannot start containers."
