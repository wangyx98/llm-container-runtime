#!/bin/bash
# Oracle: runs the bundle as the solver left it (config.json; only args and the cgroup path are set by the oracle) with the lab's runc. Required: the lab and the rootfs are unchanged; config.json is the
# original except for the /test-proc mount, which is still a recursive bind (rbind) of /proc; the container starts; from the HOST: its user, PID and mount namespaces are not the host's, its uid_map is the
# bundle's, /test-proc is a procfs mount that is read-only, and through it the container reads the command line of a host process the oracle started (a new procfs of the container's PID namespace would not show it);
# a write-open of a file there is refused with "Read-only file system"; the container is running and is pid 1 in its namespace.
CASE_ID="bench50335957"
LIB="/var/lib/$CASE_ID"
BUNDLE="$LIB/bundle"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
RUNC="$LIB/bin/runc"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ -n "$(sudo cat "$STATE_DIR/ready" 2>/dev/null)" ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha' && sha256sum -c --quiet '$STATE_DIR/rootfs.sha'" >/dev/null 2>&1 || fail "runc, its wrapper or the rootfs of the lab was changed"
[ "$(sudo sh -c "find '$BUNDLE/rootfs' | sort" | sha256sum)" = "$(sudo sh -c "sha256sum < '$STATE_DIR/rootfs.list'")" ] || fail "files were added to or removed from the rootfs"

# the configuration: the original, except for the mount of /test-proc
sudo python3 - "$BUNDLE/config.json" "$STATE_DIR/config.orig.json" <<'PY' || exit 1
import json, sys
try:
    cur = json.load(open(sys.argv[1]))
except ValueError as e:
    print("[oracle] FAIL: config.json is not valid JSON: %s" % e); sys.exit(1)
orig = json.load(open(sys.argv[2]))
def bad(m):
    print("[oracle] FAIL: " + m); sys.exit(1)
for k in set(cur) | set(orig):
    if k != "mounts" and cur.get(k) != orig.get(k):
        bad("'%s' of config.json differs from the original (the namespaces, the id mapping, the process and the rest have to stay)" % k)
rest = lambda c: [m for m in c["mounts"] if m.get("destination") != "/test-proc"]
if rest(cur) != rest(orig):
    bad("the mounts other than /test-proc differ from the original")
tp = [m for m in cur["mounts"] if m.get("destination") == "/test-proc"]
if len(tp) != 1:
    bad("there must be exactly one mount at /test-proc, found %d" % len(tp))
m = tp[0]; o = [x for x in orig["mounts"] if x.get("destination") == "/test-proc"][0]
if m.get("type") != "bind" or m.get("source") != "/proc":
    bad("/test-proc is not a bind mount of the host's /proc: type=%r source=%r" % (m.get("type"), m.get("source")))
opts = m.get("options") or []
if "rbind" not in opts or "rw" in opts or "rrw" in opts:
    bad("the mount has to stay a recursive (rbind) and not read-write bind: options=%r" % opts)
PY

# the run: a derived bundle (same config; the probe is told the pid of a host process; own cgroup)
rm -rf "$WORK_DIR/ob"; mkdir -p "$WORK_DIR/ob"
setsid sleep "3000.$RANDOM$RANDOM" </dev/null >/dev/null 2>&1 &
sentinel=$!
cleanup_run() { sudo timeout -k 3 20 "$RUNC" delete -f oracle >/dev/null 2>&1; kill -KILL "$sentinel" 2>/dev/null; }
trap cleanup_run EXIT
sleep 0.3
python3 - "$BUNDLE/config.json" "$WORK_DIR/ob/config.json" "$sentinel" <<'PY' || fail "could not derive the bundle to run"
import json, sys
c = json.load(open(sys.argv[1]))
c["root"]["path"] = "/var/lib/bench50335957/bundle/rootfs"
c["process"]["args"] = ["/probe", sys.argv[3]]
c["linux"]["cgroupsPath"] = "/bench50335957/oracle"
json.dump(c, open(sys.argv[2], "w"))
PY
sudo timeout -k 3 30 "$RUNC" run -d --pid-file "$WORK_DIR/ob/pid" -b "$WORK_DIR/ob" oracle </dev/null >"$WORK_DIR/ob/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "the container does not start (runc exit $rc): $(tail -c 400 "$WORK_DIR/ob/out")"
ok=0
for _ in $(seq 1 50); do grep -q READY "$WORK_DIR/ob/out" 2>/dev/null && { ok=1; break; }; sleep 0.2; done
[ "$ok" = 1 ] || fail "the container started but its program did not get ready: $(tail -c 400 "$WORK_DIR/ob/out")"
pid=$(sudo cat "$WORK_DIR/ob/pid")
[ -n "$pid" ] || fail "no pid for the container"
state=$(sudo "$RUNC" state oracle 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
[ "$state" = "running" ] || fail "the container is not running: $state"

sudo python3 - "$pid" "$sentinel" "$WORK_DIR/ob/out" <<'PY' || exit 1
import os, sys
pid, sentinel, outf = sys.argv[1], sys.argv[2], sys.argv[3]
def bad(m):
    print("[oracle] FAIL: " + m); sys.exit(1)
out = open(outf).read()
f = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
if f.get("pid") != "1":
    bad("the program is not pid 1 of its own PID namespace: %r" % f.get("pid"))
for ns in ("user", "pid", "mnt"):
    if os.readlink("/proc/%s/ns/%s" % (pid, ns)) == os.readlink("/proc/%s/ns/%s" % (sentinel, ns)):
        bad("the container shares the %s namespace of the host (the user, PID and mount namespaces have to stay)" % ns)
um = open("/proc/%s/uid_map" % pid).read().split()
if um != ["0", "100000", "65536"]:
    bad("uid_map of the container is %s, not the bundle's 0 100000 65536" % um)
want = open("/proc/%s/cmdline" % sentinel).read().replace("\0", " ").strip()
if f.get("hostcmd") != want:
    bad("through /test-proc the container read %r for the host process %s, expected %r (it is not the host's /proc)" % (f.get("hostcmd"), sentinel, want))
mi = [l.split() for l in open("/proc/%s/mountinfo" % pid).read().splitlines()]
tp = [l for l in mi if l[4] == "/test-proc"]
if len(tp) != 1:
    bad("%d mounts at /test-proc in the container" % len(tp))
l = tp[0]; sep = l.index("-")
if l[sep + 1] != "proc" or l[3] != "/":
    bad("/test-proc is not a procfs mount of its root: root=%s fstype=%s" % (l[3], l[sep + 1]))
if "ro" not in l[5].split(","):
    bad("/test-proc is not read-only on the host's side: %s" % l[5])
if f.get("wopen") != "Read-only file system":
    bad("a write-open of /test-proc/self/oom_score_adj gave %r, expected 'Read-only file system'" % f.get("wopen"))
print("[oracle] PASS: container pid %s runs in its own user/PID/mount namespaces; /test-proc is the host's /proc (read a host process through it), read-only (%s), a write-open is refused with 'Read-only file system'" % (pid, l[5]))
PY
