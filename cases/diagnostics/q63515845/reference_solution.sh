#!/bin/bash
set -e

W="/tmp/bench63515845"
N="$W/bin/node-crictl"
IMG="localhost/bench63515845/reporter:1"
SOCK="/run/bench63515845/crio.sock"
CRICTL_BIN=$(command -v crictl)
FIX="$W/fix"
mkdir -p "$FIX"

echo "[solution] the asker's program, fixed: the command's output and error go to the pod's log (stdout and stderr), and its exit status is the program's..."
cat > "$FIX/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	cmdStr := "docker ps"
	if len(os.Args) > 1 {
		cmdStr = os.Args[1]
	}
	cmd := exec.Command("/bin/sh", "-c", cmdStr)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		os.Exit(1)
	}
}
EOF
# the image has no libc: a static program
(cd "$FIX" && CGO_ENABLED=0 GO111MODULE=off GOCACHE="$FIX/.gocache" go build -o "$FIX/cmdrun" main.go)

echo "[solution] the report: one line per running container, '<container id> <host pid>', both asked from the node's CRI-O through its socket..."
cat > "$FIX/report.sh" <<EOF
#!/bin/sh
set -e
CR="crictl --runtime-endpoint unix://$SOCK"
ids=\$(\$CR ps -q --no-trunc --state running)
for id in \$ids; do
    pid=\$(\$CR inspect -o go-template --template '{{.info.pid}}' "\$id")
    echo "\$id \$pid"
done
EOF
chmod 755 "$FIX/report.sh" "$FIX/cmdrun"

echo "[solution] a new container in the reporter pod: the node's crictl, the CRI-O socket, the report script and the fixed program mounted, the user kept non-root but in the group that may use the socket (not privileged)..."
POD=$($N pods --name '^reporter$' -q | head -1)
cat > "$FIX/container.json" <<EOF
{
  "metadata": {"name": "reporter", "attempt": 1},
  "image": {"image": "$IMG"},
  "args": ["/app/report.sh"],
  "mounts": [
    {"container_path": "/usr/bin/crictl", "host_path": "$CRICTL_BIN", "readonly": true},
    {"container_path": "$SOCK", "host_path": "$SOCK"},
    {"container_path": "/app/report.sh", "host_path": "$FIX/report.sh", "readonly": true},
    {"container_path": "/app/cmdrun", "host_path": "$FIX/cmdrun", "readonly": true}
  ],
  "log_path": "reporter-fixed.log",
  "linux": {"security_context": {"run_as_user": {"value": 1000540000}, "run_as_group": {"value": 1000540000}, "supplemental_groups": [0]}}
}
EOF
CTR=$($N create "$POD" "$FIX/container.json" "$W/reporter/pod.json" | tail -1)
$N start "$CTR" >/dev/null
sleep 3
echo "[solution] the log of the new container:"
$N logs "$CTR"
