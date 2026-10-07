#!/bin/bash
# no 'set -e': every check reports its own failure
CASE_ID="bench68630961"
UNIT="$CASE_ID-containerd.service"
PREFIX="/opt/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
IMAGE="registry.invalid/$CASE_ID/app:1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }
prop() { systemctl show "$UNIT" -p "$1" --value 2>/dev/null; }
# the warnings and errors of the unit since this run's setup (earlier runs of the same unit name are not
# shown). Short on purpose: the harness reports only the last 500 characters of the oracle's output, and a
# long excerpt would push the FAIL line itself out of them.
journal_tail() {
    sudo journalctl -u "$UNIT" --since "@$(cat "$STATE_DIR/t0" 2>/dev/null || echo 0)" -p warning -n 3 \
        --no-pager -o cat 2>/dev/null | tail -c 220 | tr '\n' '|'
}
state_info() { echo "ActiveState=$(prop ActiveState) SubState=$(prop SubState) Result=$(prop Result) ExecMainStatus=$(prop ExecMainStatus)"; }

TARBALL_CTD=$(readlink -f "$PREFIX/bin/containerd")
CTR="sudo timeout -k 5 30 $PREFIX/bin/ctr -a $CTD_SOCK"
TOKEN=$(sudo cat "$STATE_DIR/token" 2>/dev/null)
[ -n "$TOKEN" ] || fail "setup records are missing"

# the pids of every process that runs the tarball's containerd binary (read as root: /proc/<pid>/exe)
ctd_pids() {
    sudo bash -c 'for p in /proc/[0-9]*; do
        [ "$(readlink -f "$p/exe" 2>/dev/null)" = "$1" ] && echo "${p#/proc/}"
    done' _ "$TARBALL_CTD"
}

# $1 = label for the container ids. containerd must answer on the socket, hold the image that was
# preloaded into its root, and run it.
rpc_and_image() {
    # the unit is active; a service that is still starting (Type=simple does not wait for readiness)
    # gets a few seconds before it counts as not answering
    for _ in $(seq 1 20); do
        $CTR version >/dev/null 2>&1 </dev/null && break
        sleep 1
    done
    $CTR version >/dev/null 2>&1 </dev/null || fail "containerd does not answer on $CTD_SOCK ($1); log: $(journal_tail)"
    $CTR images ls -q 2>/dev/null </dev/null | grep -qx "$IMAGE" \
        || fail "the containerd behind $CTD_SOCK does not have $IMAGE ($1): not the preloaded root"
    OUT=$($CTR run --rm "$IMAGE" "$CASE_ID-oracle-$1" 2>/dev/null </dev/null) \
        || fail "ctr run of the image failed ($1)"
    [ "$OUT" = "$TOKEN" ] || fail "the image did not print its marker ($1)"
}

# the service runs the tarball's containerd, inside the unit's own cgroup
runs_tarball_containerd() {
    local cg pids pid line cgp
    (cd "$PREFIX/bin" && sudo sha256sum -c "$STATE_DIR/tarball.sha256" >/dev/null 2>&1) \
        || fail "the binaries in $PREFIX/bin were changed ($1)"
    cg=$(prop ControlGroup)
    [ -n "$cg" ] || fail "the unit has no control group ($1)"
    pids=$(ctd_pids)
    [ -n "$pids" ] || fail "no process runs $TARBALL_CTD ($1): the service does not run the tarball's containerd"
    for pid in $pids; do
        cgp=$(sudo cat "/proc/$pid/cgroup" 2>/dev/null | awk -F: '$1=="0" || $2=="name=systemd" {print $3; exit}')
        case "$cgp" in
            "$cg"|"$cg"/*) ;;
            *) fail "the tarball's containerd (pid $pid) is not run by $UNIT (it is in '$cgp'): started by hand or by something else ($1)" ;;
        esac
    done
}

echo "[oracle] check 1: systemd knows $UNIT as a real unit file in a persistent place..."
LOAD=$(prop LoadState)
if [ "$LOAD" != "loaded" ]; then
    FOUND=$(sudo find /etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system \
                 -maxdepth 1 -name "$UNIT" 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        fail "$FOUND exists but systemd has not loaded it (LoadState=$LOAD): systemctl daemon-reload was not run"
    fi
    fail "systemd still has no $UNIT (LoadState=$LOAD): Unit not found"
fi
[ "$(prop Transient)" = "no" ] || fail "$UNIT is a transient unit (systemd-run): it is gone after a reboot"
FRAG=$(prop FragmentPath)
case "$FRAG" in
    ""|/run/*|/tmp/*|/var/tmp/*|/dev/shm/*) fail "the unit file is '$FRAG': not a persistent place, gone after a reboot" ;;
esac
sudo test -e "$FRAG" || fail "the unit file $FRAG does not exist"
[ "$(prop NeedDaemonReload)" = "no" ] || fail "the unit file changed on disk and systemd was not told (daemon-reload)"
echo "  -> OK ($FRAG)"

echo "[oracle] check 2: the service is active and running..."
ACTIVE=$(prop ActiveState); SUB=$(prop SubState)
if [ "$ACTIVE" != "active" ] || [ "$SUB" != "running" ]; then
    fail "$UNIT is not active and running: $(state_info); log: $(journal_tail)"
fi
echo "  -> OK (MainPID $(prop MainPID))"

echo "[oracle] check 3: the service runs the containerd binary of the tarball (not the host's, not a stand-in)..."
runs_tarball_containerd first
echo "  -> OK"

echo "[oracle] check 4: containerd answers on $CTD_SOCK, holds the preloaded image and runs it..."
rpc_and_image first
echo "  -> OK"

echo "[oracle] check 5: it comes up at boot: enabled in a persistent way, pulled in by the default target,"
echo "[oracle] and nothing in its command lives in a volatile directory..."
UFS=$(systemctl show "$UNIT" -p UnitFileState --value 2>/dev/null)
case "$UFS" in
    enabled) ;;
    enabled-runtime) fail "the unit is only enabled for this boot (enabled-runtime, --runtime)" ;;
    *) fail "the unit is not enabled (UnitFileState=$UFS): it would not start after a reboot" ;;
esac
systemctl list-dependencies --plain --all default.target 2>/dev/null | grep -qF "$UNIT" \
    || fail "default.target does not pull in $UNIT (check the [Install] section / systemctl enable)"
EXECS=$(prop ExecStart)
if echo "$EXECS" | grep -qE 'path=(/run|/tmp|/var/tmp|/dev/shm)/'; then
    fail "ExecStart runs a program from a volatile directory: $EXECS"
fi
echo "  -> OK ($UFS)"

echo "[oracle] check 6: a cold start, as after a reboot: stop the service, remove its runtime dir"
echo "[oracle] ($RUN_BASE, /run is empty after a boot), reload systemd, start the service..."
OLDPID=$(prop MainPID)
sudo timeout 90 systemctl stop "$UNIT" >/dev/null 2>&1 || fail "systemctl stop $UNIT failed or hung"
for _ in $(seq 1 20); do [ -z "$(ctd_pids)" ] && break; sleep 0.5; done
sudo rm -rf --one-file-system "$RUN_BASE"
sudo systemctl daemon-reload >/dev/null 2>&1
sudo timeout 90 systemctl start "$UNIT" >/dev/null 2>&1 \
    || fail "systemctl start $UNIT failed after the cold start: $(state_info); log: $(journal_tail)"
for _ in $(seq 1 40); do
    [ "$(prop ActiveState)" = "active" ] && sudo test -S "$CTD_SOCK" && break
    sleep 0.5
done
[ "$(prop ActiveState)" = "active" ] || fail "$UNIT is not active after the cold start: $(state_info); log: $(journal_tail)"
sudo test -S "$CTD_SOCK" || fail "$CTD_SOCK was not created after the cold start; log: $(journal_tail)"
[ "$(prop MainPID)" != "$OLDPID" ] || fail "the service was not restarted"
runs_tarball_containerd cold
rpc_and_image cold
echo "  -> OK (MainPID $OLDPID -> $(prop MainPID))"

echo "[oracle] check 7: nothing else was touched: the host's own containerd/docker units and binary..."
NOW=$(for u in containerd.service docker.service; do
        echo "$u $(systemctl show "$u" -p LoadState -p ActiveState -p MainPID --value 2>/dev/null | tr '\n' ' ')"
      done
      SB=$(readlink -f "$(command -v containerd)"); echo "binary $SB $(sha256sum "$SB" | cut -d' ' -f1)")
[ "$NOW" = "$(cat "$STATE_DIR/system.truth")" ] \
    || fail "the host's containerd/docker changed (was: $(tr '\n' ';' < "$STATE_DIR/system.truth"))"
echo "  -> OK"

echo "[oracle] all checks passed."
exit 0
