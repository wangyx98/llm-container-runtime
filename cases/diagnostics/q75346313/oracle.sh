#!/bin/bash
set -e

CASE_ID="bench75346313"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DSOCK="$RUN_BASE/docker.sock"
CSOCK="$RUN_BASE/containerd.sock"
AA_PROFILES=/sys/kernel/security/apparmor/profiles
NAME="bench75346313-web"
IMAGE="bench/app:1"
PROFILE="docker-default (enforce)"
RND=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
FRESH="bench75346313-check-$RND"

D() { docker -H "unix://$DSOCK" "$@"; }
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
trap 'D rm -f "$FRESH" >/dev/null 2>&1 || true' EXIT

# what a container runs under: the label of its init process, as the host's kernel sees it
label_of() {   # $1 = container
    local pid
    pid=$(D inspect -f '{{.State.Pid}}' "$1")
    [ "$pid" -gt 0 ] 2>/dev/null || { echo "no process"; return; }
    sudo cat "/proc/$pid/attr/current" 2>/dev/null | tr -d '\0\n' || true
}
# the container must be unable to do what a confined one cannot: every operation of 'app probe' is denied
probe() {      # $1 = container
    local out rc
    set +e; out=$(timeout -k 3 30 docker -H "unix://$DSOCK" exec "$1" /app probe 2>&1); rc=$?; set -e
    [ "$rc" -eq 0 ] || { echo "$out" | sed 's/^/  | /'; fail "$1: an operation that must be denied is allowed (or the probe did not run: exit $rc)"; }
    [ "$(echo "$out" | grep -c ': denied')" -ge 4 ] || { echo "$out" | sed 's/^/  | /'; fail "$1: the probe did not report its four operations as denied"; }
}
inspect() {    # $1 = container, then the fields to check
    D inspect "$1" | python3 -c '
import json, sys
c = json.load(sys.stdin)[0]
h = c["HostConfig"]
sec = h.get("SecurityOpt") or []
errs = []
if not c["State"]["Running"]:
    errs.append("it is not running (status %s)" % c["State"]["Status"])
if c["Config"]["Image"] != "bench/app:1":
    errs.append("its image is %s, not bench/app:1" % c["Config"]["Image"])
if h.get("Privileged"):
    errs.append("it is --privileged (that turns confinement off)")
if any("apparmor" in s and "docker-default" not in s for s in sec):
    errs.append("its security options turn the AppArmor profile off or change it: %s" % sec)
if c.get("AppArmorProfile") != "docker-default":
    errs.append("its AppArmor profile is %r, not docker-default" % c.get("AppArmorProfile"))
if errs:
    print("; ".join(errs)); sys.exit(1)'
}

echo "[oracle] the daemon of the lab is up, and it is the one the script starts: its socket, its data, its containerd..."
D info >/dev/null 2>&1 || fail "the Docker daemon does not answer on $DSOCK"
alive_same containerd || fail "the private containerd is not the process setup started (the solution must not replace it)"
[ "$(sudo sha256sum "$LIB_BASE/etc/config.toml" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config changed"
P=$(sudo cat "$RUN_BASE/dockerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = dockerd ] || fail "the daemon on $DSOCK is not the process the lab's script started"
sudo tr '\0' ' ' < /proc/$P/cmdline | grep -q -- "--data-root $LIB_BASE/docker" || fail "the daemon does not use the data root of the lab"
D info --format '{{json .SecurityOptions}}' | grep -q 'name=apparmor' || fail "the daemon does not report AppArmor among its security options"
echo "  -> OK"

echo "[oracle] the kernel has the docker-default profile, loaded by the daemon, enforced..."
sudo grep -qx 'docker-default (enforce)' "$AA_PROFILES" || fail "docker-default is not loaded in enforce mode"
echo "  -> OK"

echo "[oracle] the container $NAME from the lab's image: running, not privileged, no AppArmor override, and the kernel runs it under $PROFILE..."
D inspect "$NAME" >/dev/null 2>&1 || fail "there is no container $NAME"
MSG=$(inspect "$NAME" 2>&1) || fail "$NAME: $MSG"
L=$(label_of "$NAME")
[ "$L" = "$PROFILE" ] || fail "$NAME runs under '$L' (/proc/PID/attr/current), expected '$PROFILE'"
echo "  -> OK: /proc/PID/attr/current of $NAME is '$L'"

echo "[oracle] and what the profile is for: the container cannot do what a confined container must not (write /proc/sysrq-trigger, ...)..."
probe "$NAME"
echo "  -> OK"

echo "[oracle] a container the check starts now, by plain 'docker run': the daemon confines it the same way (it is the daemon's default, not one container's option)..."
D run -d --name "$FRESH" "$IMAGE" >/dev/null 2>&1 || fail "docker run of $IMAGE fails"
MSG=$(inspect "$FRESH" 2>&1) || fail "$FRESH: $MSG"
L=$(label_of "$FRESH")
[ "$L" = "$PROFILE" ] || fail "a new container runs under '$L', expected '$PROFILE'"
probe "$FRESH"
D rm -f "$FRESH" >/dev/null 2>&1 || true
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: Docker runs again, the container is confined by docker-default (enforce) and cannot do what the profile denies."
