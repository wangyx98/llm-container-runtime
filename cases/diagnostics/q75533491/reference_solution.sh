#!/bin/bash
set -e
# Reference solution for q75533491.
#
# On cgroup v2 every process has exactly one line in /proc/self/cgroup, "0::<path>",
# where <path> is the cgroup of the process, and the cgroup of a container started by
# containerd's runc shim is named after the container. The path differs with the
# orchestrator: ".../<id>" (cgroupfs driver, ctr), ".../cri-containerd-<id>.scope"
# (systemd driver), so take the last 64-hex-digit group of the line instead of the last path
# component.
WORK="/tmp/bench75533491"
cat > "$WORK/get_container_id.sh" <<'SCRIPT_EOF'
#!/bin/sh
grep -o '[0-9a-f]\{64\}' /proc/self/cgroup | tail -n 1
SCRIPT_EOF
chmod +x "$WORK/get_container_id.sh"
echo "[solution] wrote $WORK/get_container_id.sh:"
cat "$WORK/get_container_id.sh"
