#!/bin/bash
set -e

CONTAINER="bench70089899"
BUNDLE_DIR="/tmp/bench70089899/bundle"
OUT="/tmp/bench70089899/stacktrace.txt"

echo "[solution] finding the stuck process. 'runc create' re-executes itself"
echo "[solution] as a 'runc init' child that does the actual container setup;"
echo "[solution] that child is the one wedged. (The top-level 'runc create'"
echo "[solution] just waits on it, and it installs a catch-all signal handler"
echo "[solution] that swallows SIGQUIT, so signalling it yields no dump.)"
CREATE_PID=$(pgrep -f "^runc create --bundle $BUNDLE_DIR $CONTAINER\$" | head -1)
# runc re-executes in stages, so brief intermediate `runc init` processes can
# exist next to the real one. The stuck one is the one running the hook,
# i.e. the one that has a child process.
INIT_PID=""
for cand in $(pgrep -P "$CREATE_PID" -f '^runc init'); do
    if [ -n "$(pgrep -P "$cand")" ]; then INIT_PID="$cand"; break; fi
done
echo "[solution] runc create pid=$CREATE_PID, runc init pid=$INIT_PID"

echo "[solution] its stderr isn't a file we can open by name, so tap the fd"
echo "[solution] directly through /proc BEFORE signalling, so the dump lands"
echo "[solution] in our reader instead of sitting unread in the pipe..."
sudo readlink "/proc/$INIT_PID/fd/2"
sudo cat "/proc/$INIT_PID/fd/2" > "$OUT" &
READER_PID=$!
sleep 1

echo "[solution] SIGQUIT makes the Go runtime print every goroutine's stack to"
echo "[solution] stderr and exit..."
sudo kill -QUIT "$INIT_PID"

echo "[solution] waiting for the reader to hit EOF (every writer of that pipe"
echo "[solution] exits once runc init dies and runc create reports the failure)..."
for _ in $(seq 1 40); do
    kill -0 "$READER_PID" 2>/dev/null || break
    sleep 0.25
done
# don't hang forever if some other writer keeps the pipe open
kill "$READER_PID" 2>/dev/null || true
wait "$READER_PID" 2>/dev/null || true

echo "[solution] captured $(wc -l < "$OUT") lines; head:"
head -n 5 "$OUT"
echo "[solution] done."
exit 0
