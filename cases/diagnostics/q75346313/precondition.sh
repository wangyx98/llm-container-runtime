#!/bin/bash
set -e

CASE_ID="bench75346313"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
TOOLS="$WORK_DIR/tools"
DSOCK="$RUN_BASE/docker.sock"
CSOCK="$RUN_BASE/containerd.sock"
AA_PROFILES=/sys/kernel/security/apparmor/profiles

fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[precondition] AppArmor is on in this kernel, and the profile Docker needs, docker-default, is not loaded..."
[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = "Y" ] || fail "AppArmor is not enabled in this kernel"
sudo grep -q '^docker-default ' "$AA_PROFILES" && fail "docker-default is loaded: Docker would not need the parser to start"
echo "  -> OK"

echo "[precondition] the private containerd is the process setup started, its config is unchanged, and the helpers are as copied..."
alive_same containerd || fail "the private containerd is not the process setup started"
[ "$(sudo sha256sum "$LIB_BASE/etc/config.toml" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config changed"
(cd "$WORK_DIR" && sha256sum .bench/app.c .bench/mkimg.py .bench/mktools.py .bench/patch_config.py start-docker.sh | awk '{print $1}' | cmp -s - .bench/helpers.sha) || fail "a helper changed"
sudo ctr -a "$CSOCK" version >/dev/null 2>&1 || fail "containerd does not answer on $CSOCK"
echo "  -> OK"

echo "[precondition] Docker cannot start containers: the start of the daemon or the first container failed, and the evidence names AppArmor, docker-default and apparmor_parser..."
RC_START=$(st first-start.rc); RC_RUN=$(st first-run.rc)
{ [ "$RC_START" != 0 ] || { [ "$RC_RUN" != none ] && [ "$RC_RUN" != 0 ]; }; } \
    || fail "the daemon started and a container ran (first start rc=$RC_START, first run rc=$RC_RUN): this Docker does not need the parser here"
EV=$(st evidence.log)
echo "$EV" | grep -q 'apparmor_parser' && echo "$EV" | grep -q 'docker-default' && echo "$EV" | grep -qi 'AppArmor enabled on system' \
    || { echo "$EV" | tail -8 | cut -c1-300; fail "it failed, but not for the AppArmor parser (the evidence above): this Docker does not behave as the question says"; }
echo "$EV" | grep -i 'AppArmor enabled on system' | tail -1 | cut -c1-300 | sed 's/^/  | /'
if docker -H "unix://$DSOCK" info >/dev/null 2>&1; then
    [ -z "$(docker -H "unix://$DSOCK" ps -aq)" ] || fail "a container exists on the daemon"
    echo "  -> OK: the daemon is up (start rc=$RC_START), the first container failed (rc=$RC_RUN)"
else
    echo "  -> OK: the daemon is down (start rc=$RC_START)"
fi

echo "[precondition] the cause is the missing tool and nothing else: the tool set has no apparmor_parser, the VM has one, the rest of the tools are there..."
[ ! -e "$TOOLS/apparmor_parser" ] || fail "$TOOLS has an apparmor_parser"
env -i "PATH=$TOOLS" bash -c 'command -v apparmor_parser' >/dev/null 2>&1 && fail "apparmor_parser is on the PATH of the daemon"
PARSER=$(st parser.path)
[ -x "$PARSER" ] || fail "the parser that setup found ($PARSER) is gone"
for t in runc docker bash setsid; do
    [ -x "$TOOLS/$t" ] || fail "$TOOLS has no $t"
done
echo "  -> OK: the parser of this VM is $PARSER"

echo "[precondition] the workload is ready to load: the archive of bench/app:1 is there, no container process runs..."
[ -s "$WORK_DIR/app.tar" ] && tar tf "$WORK_DIR/app.tar" | grep -q '^manifest.json$' || fail "$WORK_DIR/app.tar is not an image archive"
[ -z "$(pgrep -x app || true)" ] || fail "a container process is running"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED: AppArmor on, docker-default not loaded, Docker cannot start containers for want of apparmor_parser."
