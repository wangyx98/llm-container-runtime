#!/bin/bash
set -e

CONTAINER="bench70089899"
WORK_DIR="/tmp/bench70089899"
BUNDLE_DIR="$WORK_DIR/bundle"
# Everything below lives in a hidden subdirectory. The task.txt never names
# any of these paths: the model is told only that runc's stderr goes
# "somewhere you don't have a file path for".
STATE_DIR="$WORK_DIR/.bench"
STUCK_HOOK="$STATE_DIR/hook.sh"
STDERR_FIFO="$STATE_DIR/runc-stderr"
HOLDER_PIDFILE="$STATE_DIR/stderr_holder.pid"
LAUNCHER_PIDFILE="$STATE_DIR/launcher.pid"
CREATE_PIDFILE="$STATE_DIR/runc_create.pid"
INIT_PIDFILE="$STATE_DIR/runc_init.pid"
STACKTRACE_FILE="$WORK_DIR/stacktrace.txt"

echo "[setup] checking runc is present (it ships with the base image as part"
echo "[setup] of the containerd install, the same as in the other cases)..."
command -v runc
sudo runc --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] building a minimal OCI bundle at $BUNDLE_DIR ..."
mkdir -p "$BUNDLE_DIR/rootfs" "$STATE_DIR"
( cd "$BUNDLE_DIR" && runc spec )

# The hook stands in for whatever wedged the real asker's container. In
# practice that could be a hung OCI hook, a device plugin that never
# answers, or a blocking syscall. It simply never returns.
#
# Why createContainer and not createRuntime: createRuntime hooks are run by
# the top-level `runc create` process, and that process registers a
# catch-all signal.Notify (runc's signal forwarder). The forwarder swallows
# SIGQUIT, so no stack dump is ever produced. createContainer hooks run
# inside the `runc init` child, from prepareRootfs(). That process keeps
# Go's default SIGQUIT behavior (dump every goroutine to stderr, then
# exit), which is the behavior the SO answer relies on. Both were verified
# empirically against runc 1.3.5 while building this case.
echo "[setup] writing a createContainer hook that never returns..."
cat > "$STUCK_HOOK" <<'EOF'
#!/bin/sh
exec sleep infinity
EOF
chmod +x "$STUCK_HOOK"

echo "[setup] patching config.json: no terminal, plus the never-returning"
echo "[setup] createContainer hook (deliberately with NO timeout field)..."
python3 - "$BUNDLE_DIR/config.json" "$STUCK_HOOK" <<'PYEOF'
import json
import sys

path, hook = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["/bin/true"]  # never reached; the hook blocks first
cfg["hooks"] = {"createContainer": [{"path": hook, "args": [hook]}]}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
sha256sum "$BUNDLE_DIR/config.json" | awk '{print $1}' > "$STATE_DIR/config.json.sha256"

# Wire runc's stderr to a FIFO that has a reader attached which never
# actually reads. This mimics a supervising daemon holding the other end of
# runc's stderr pipe: writes succeed and sit in the pipe buffer, but there
# is no log file anyone can just `cat`.
#
# Every background process here gets its stdin/stdout/stderr redirected
# away from this script's own. Otherwise run_script()'s
# subprocess.run(capture_output=True) would wait for EOF on pipes that the
# background processes keep open forever, and setup.sh would "hang" until
# the harness timeout.
#
# setsid gives each background process its own session with no controlling
# terminal. Two reasons: (1) they survive this script exiting, including
# when someone runs setup.sh by hand from an interactive shell and later
# closes it; and (2) sudo only interposes a pseudo-terminal (Ubuntu's
# default `Defaults use_pty`) when it has a controlling tty. With a pty in
# the way, runc's fd 2 would point at sudo's relay instead of the FIFO, and
# sudo would race the solution for the bytes.
echo "[setup] creating the stderr FIFO and its silent holder..."
rm -f "$STDERR_FIFO"
mkfifo "$STDERR_FIFO"
setsid sleep infinity < "$STDERR_FIFO" > /dev/null 2>&1 &
echo $! > "$HOLDER_PIDFILE"

echo "[setup] launching 'sudo runc create' in the background (this is the"
echo "[setup] colleague's command that never returns)..."
setsid sudo runc create --bundle "$BUNDLE_DIR" "$CONTAINER" \
    < /dev/null > "$STATE_DIR/runc_create.stdout" 2> "$STDERR_FIFO" &
echo $! > "$LAUNCHER_PIDFILE"

# runc 1.3 re-executes itself in stages: `runc create` spawns a `runc init`,
# and short-lived intermediate `runc init` processes come and go before the
# final one (the one that actually runs the container hooks) settles. If we
# simply grabbed the first `runc init` we saw, we would sometimes record a
# process that exits a moment later (observed in ~1 of 7-15 runs).
# The final, genuinely stuck init is the one that has the never-returning
# hook as its child, so wait for that, then read the init pid off it.
echo "[setup] waiting for the final 'runc init' (the one running the stuck hook)..."
CREATE_PID=""
INIT_PID=""
for _ in $(seq 1 80); do
    CREATE_PID=$(pgrep -f "^runc create --bundle $BUNDLE_DIR $CONTAINER\$" | head -1 || true)
    if [ -n "$CREATE_PID" ]; then
        for cand in $(pgrep -P "$CREATE_PID" -f '^runc init' || true); do
            if [ -n "$(pgrep -P "$cand" -f '^sleep infinity' || true)" ]; then
                INIT_PID="$cand"
                break
            fi
        done
    fi
    [ -n "$INIT_PID" ] && break
    sleep 0.25
done
if [ -z "$INIT_PID" ]; then
    echo "[setup] FAIL: the stuck 'runc init' never appeared"
    ps -eo pid,ppid,stat,cmd | grep -E '[r]unc' || true
    exit 1
fi
# settle: confirm it is still the same live process a moment later
sleep 1
if ! sudo kill -0 "$INIT_PID" 2>/dev/null; then
    echo "[setup] FAIL: runc init $INIT_PID exited right after being picked"
    exit 1
fi
echo "$CREATE_PID" > "$CREATE_PIDFILE"
echo "$INIT_PID" > "$INIT_PIDFILE"
echo "  -> runc create pid=$CREATE_PID, runc init pid=$INIT_PID"

echo "[setup] making sure no stack trace file exists yet..."
rm -f "$STACKTRACE_FILE"

echo "[setup] done. runc is now hung inside the bench70089899 container's"
echo "[setup] init, with its stderr going to a pipe nobody is reading."
