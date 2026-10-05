#!/bin/bash
set -e

# Same non-interactive apt settings as the other cases (needrestart pops up dialogs otherwise).
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

GRPCURL_VERSION="1.9.1"

CASE_ID="bench72753140"
RUN_BASE="/run/$CASE_ID"              # socket + runtime state of the private containerd
LIB_BASE="/var/lib/$CASE_ID"          # its root (metadata, content) and the containers' root file systems
SOCK="$RUN_BASE/containerd.sock"
NS="$CASE_ID"                         # the namespace the task is about
NS_OTHER="$CASE_ID-other"             # a second namespace with a container the answer must NOT contain

WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PROTO_DIR="$WORK_DIR/proto"           # API definitions that match this containerd
PROTO_OLD_DIR="$WORK_DIR/proto-old"   # the outdated definitions the engineer used

echo "[setup] checking containerd, runc and the ctr client are installed (the runtime"
echo "[setup] under test; same assumption as the other containerd cases)..."
command -v containerd >/dev/null || { echo "[setup] ERROR: containerd not found"; exit 1; }
command -v ctr >/dev/null || { echo "[setup] ERROR: ctr not found"; exit 1; }
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
containerd --version

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure curl, gcc and python3 are available (curl: grpcurl download and"
echo "[setup] this case's own checks; gcc: one tiny static program, so the same script works"
echo "[setup] on x86_64 and arm64 and nothing has to be downloaded for the containers)..."
if ! command -v curl >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" curl ca-certificates
fi
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }

case "$(uname -m)" in
    x86_64|amd64)   GRPCURL_ARCH="x86_64" ;;
    aarch64|arm64)  GRPCURL_ARCH="arm64" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac

sudo mkdir -p "$LIB_BASE"
echo "[setup] ensuring grpcurl $GRPCURL_VERSION is installed (the gRPC client of the story)..."
if command -v grpcurl >/dev/null 2>&1; then
    echo "  -> already installed: $(command -v grpcurl)"
else
    rm -rf "$WORK_DIR"; mkdir -p "$STATE_DIR"
    curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPCURL_ARCH}.tar.gz" \
        -o "$STATE_DIR/grpcurl.tar.gz"
    tar -xzf "$STATE_DIR/grpcurl.tar.gz" -C "$STATE_DIR" grpcurl
    sudo install -m 0755 "$STATE_DIR/grpcurl" /usr/local/bin/grpcurl
    # cleanup.sh removes it again: other cases require that grpcurl is NOT on the machine
    echo /usr/local/bin/grpcurl | sudo tee "$LIB_BASE/grpcurl_installed_by_case" >/dev/null
fi
grpcurl -version 2>&1 | head -1

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$PROTO_DIR/containerd/services/tasks/v1" "$PROTO_DIR/containerd/services/containers/v1" \
         "$PROTO_OLD_DIR/api/services/tasks/v1"
cd "$WORK_DIR"

echo "[setup] writing the API definitions (.proto) that match this containerd: the Tasks and"
echo "[setup] Containers services, reduced to the messages needed here (field numbers and"
echo "[setup] names are those of containerd's own definitions)..."
cat > "$PROTO_DIR/containerd/services/tasks/v1/tasks.proto" <<'PEOF'
syntax = "proto3";

package containerd.services.tasks.v1;

// containerd's native task service, reduced. Requests are scoped to a namespace with the gRPC
// header "containerd-namespace".
service Tasks {
    rpc Get(GetRequest) returns (GetResponse);
    rpc List(ListTasksRequest) returns (ListTasksResponse);
}

enum Status {
    UNKNOWN = 0;
    CREATED = 1;
    RUNNING = 2;
    STOPPED = 3;
    PAUSED = 4;
    PAUSING = 5;
}

message Process {
    string container_id = 1;
    string id = 2;
    uint32 pid = 3;
    Status status = 4;
    string stdin = 5;
    string stdout = 6;
    string stderr = 7;
}

message GetRequest {
    string container_id = 1;
    string exec_id = 2;
}

message GetResponse {
    Process process = 1;
}

message ListTasksRequest {
    string filter = 1;
}

message ListTasksResponse {
    repeated Process tasks = 1;
}
PEOF
cat > "$PROTO_DIR/containerd/services/containers/v1/containers.proto" <<'PEOF'
syntax = "proto3";

package containerd.services.containers.v1;

// containerd's native container (metadata) service, reduced. Requests are scoped to a namespace
// with the gRPC header "containerd-namespace".
service Containers {
    rpc List(ListContainersRequest) returns (ListContainersResponse);
}

message Container {
    string id = 1;
    map<string, string> labels = 2;
    string image = 3;
}

message ListContainersRequest {
    repeated string filters = 1;
}

message ListContainersResponse {
    repeated Container containers = 1;
}
PEOF
cat > "$PROTO_OLD_DIR/api/services/tasks/v1/tasks.proto" <<'PEOF'
syntax = "proto3";

package containerd.api.services.tasks.v1;

// Outdated definition: the package and service names below are not the ones the containerd of
// this machine serves.
service Tasks {
    rpc Get(GetRequest) returns (GetResponse);
    rpc List(ListTasksRequest) returns (ListTasksResponse);
}

enum Status {
    UNKNOWN = 0;
    CREATED = 1;
    RUNNING = 2;
    STOPPED = 3;
    PAUSED = 4;
    PAUSING = 5;
}

message Process {
    string container_id = 1;
    string id = 2;
    uint32 pid = 3;
    Status status = 4;
}

message GetRequest {
    string container_id = 1;
    string exec_id = 2;
}

message GetResponse {
    Process process = 1;
}

message ListTasksRequest {
    string filter = 1;
}

message ListTasksResponse {
    repeated Process tasks = 1;
}
PEOF

echo "[setup] compiling the workload: a static program that does nothing but wait. The"
echo "[setup] containers are image-less (the program is their whole root file system)..."
cat > "$STATE_DIR/sleeper.c" <<'CEOF'
#include <unistd.h>

int main(void) {
    for (;;) pause();
}
CEOF
gcc -static -Os -s -o "$STATE_DIR/sleeper" "$STATE_DIR/sleeper.c"

echo "[setup] starting a PRIVATE containerd (own socket, root and state; containerd's own"
echo "[setup] default config for the installed version, moved into that root/state, NRI off,"
echo "[setup] restrict_oom_score_adj on)..."
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
sudo mkdir -p "$RUN_BASE"
containerd config default \
    | python3 "$STATE_DIR/patch_config.py" "$LIB_BASE" "$RUN_BASE" "$SOCK" \
    | sudo tee "$RUN_BASE/config.toml" >/dev/null
# setsid + all three fds redirected: the daemon must outlive this script and must not keep the
# harness's stdout/stderr pipes open
sudo setsid -f bash -c 'echo $$ > "$1/containerd.pid"; exec containerd --config "$1/config.toml" >"$1/containerd.log" 2>&1 </dev/null' _ "$RUN_BASE" </dev/null >/dev/null 2>&1
for _ in $(seq 1 60); do
    [ -S "$SOCK" ] && sudo ctr -a "$SOCK" version >/dev/null 2>&1 && break
    sleep 0.5
done
if ! sudo ctr -a "$SOCK" version >/dev/null 2>&1; then
    echo "[setup] ERROR: the private containerd did not come up; last log lines:"
    sudo tail -20 "$RUN_BASE/containerd.log" 2>/dev/null || true
    exit 1
fi
echo "  -> containerd up on $SOCK"

echo "[setup] starting the containers: two in namespace $NS, one in $NS_OTHER, each with a"
echo "[setup] running task. The IDs are random for every run, the task PIDs are assigned by"
echo "[setup] the kernel..."
SUFFIX=$(python3 -c 'import secrets; print(secrets.token_hex(3))')
ID_A="$CASE_ID-a$SUFFIX"
ID_B="$CASE_ID-b$SUFFIX"
ID_C="$CASE_ID-c$SUFFIX"
start_container() {   # $1 = namespace, $2 = container id
    sudo mkdir -p "$LIB_BASE/rootfs/$2"
    sudo cp "$STATE_DIR/sleeper" "$LIB_BASE/rootfs/$2/sleeper"
    sudo ctr -a "$SOCK" -n "$1" run -d --rootfs "$LIB_BASE/rootfs/$2" "$2" /sleeper >/dev/null 2>&1 \
        || { echo "[setup] ERROR: could not start container $2 in namespace $1"; exit 1; }
}
start_container "$NS" "$ID_A"
start_container "$NS" "$ID_B"
start_container "$NS_OTHER" "$ID_C"
for _ in $(seq 1 40); do
    N=$(sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
    M=$(sudo ctr -a "$SOCK" -n "$NS_OTHER" tasks ls 2>/dev/null | awk '$3=="RUNNING"' | wc -l)
    [ "$N" -eq 2 ] && [ "$M" -eq 1 ] && break
    sleep 0.25
done
[ "$N" -eq 2 ] && [ "$M" -eq 1 ] || { echo "[setup] ERROR: the tasks did not all reach RUNNING"; exit 1; }
printf '%s\n' "$NS $ID_A" "$NS $ID_B" "$NS_OTHER $ID_C" | LC_ALL=C sort > "$STATE_DIR/containers.truth"
sudo ctr -a "$SOCK" -n "$NS" tasks ls 2>/dev/null | sed 's/^/  -> /'

echo "[setup] removing the build inputs..."
rm -f "$STATE_DIR/sleeper" "$STATE_DIR/sleeper.c" "$STATE_DIR/patch_config.py" \
      "$STATE_DIR/grpcurl" "$STATE_DIR/grpcurl.tar.gz"

echo "[setup] done. containerd runs two tasks in namespace $NS and one in $NS_OTHER;"
echo "[setup] the engineer's definitions (proto-old) are outdated, the matching ones are in proto."
