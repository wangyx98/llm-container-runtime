#!/bin/bash
set -e

CONTAINER="bench72392812"
IMAGE="docker.io/library/alpine:3.20"
WORK_DIR="/tmp/bench72392812"
LOG_DIR="$WORK_DIR/runsc-logs"
RUNSC_CONF="$WORK_DIR/runsc.toml"

# Ubuntu 22.04/24.04 ship `needrestart`, which pops up an interactive
# whiptail dialog ("Daemons using outdated libraries...") whenever apt
# upgrades a shared library as a dependency (curl/gnupg/ca-certificates
# or runsc itself can pull one in). That dialog needs a TTY and will hang
# forever when this script is run non-interactively by run_single_case.py
# / run_benchmark.py (subprocess with no stdin). Force both apt's own
# prompts and needrestart into fully automatic/non-interactive mode.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] noting containerd version (informational only)..."
CONTAINERD_VERSION=$(containerd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "  -> containerd ${CONTAINERD_VERSION:-<unknown, could not detect>}"

echo "[setup] ensuring gVisor (runsc + containerd-shim-runsc-v1) is installed..."
if ! command -v runsc >/dev/null 2>&1 || ! command -v containerd-shim-runsc-v1 >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" apt-transport-https ca-certificates curl gnupg

    curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
        | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" runsc
fi

echo "[setup] confirming runsc + shim binaries are on PATH..."
command -v runsc
command -v containerd-shim-runsc-v1

echo "[setup] removing any leftover container/task from a previous run (idempotency)..."
sudo ctr task kill -s SIGKILL "$CONTAINER" 2>/dev/null || true
sleep 1
sudo ctr task delete "$CONTAINER" 2>/dev/null || true
sudo ctr container delete "$CONTAINER" 2>/dev/null || true

echo "[setup] resetting work dir and creating an EMPTY log directory..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$LOG_DIR"

echo "[setup] writing runsc debug-logging config to $RUNSC_CONF ..."
# platform = "ptrace" pins gVisor to the older, more battle-tested syscall
# interception platform instead of the default "systrap". This is NOT part
# of the bug the task is about -- it's a workaround for a separate, known
# gVisor bug where systrap's internal "stub" subprocess supervision can get
# permanently stuck (sleepOnState() never returning), wedging the sandbox's
# control RPCs (including the shim's create/start handshake and `runsc
# kill`) forever with no automatic recovery on any containerd version. See
# google/gvisor#14201 (fix merged, "systrap: fail-stop sentry on stuck
# context"), google/gvisor#14405, google/gvisor#14408, and the containerd
# side of the same story in containerd/containerd#14081. Confirmed
# independently while building this case: even a plain `ctr run --runtime
# io.containerd.runsc.v1 ...` with NO debug config at all (default systrap
# platform) hung identically. ptrace doesn't use this stub-subprocess model
# and isn't affected. Performance is lower, which doesn't matter for a
# `sleep infinity` container.
cat > "$RUNSC_CONF" <<EOF
[runsc_config]
  platform = "ptrace"
  debug = "true"
  debug-log = "$LOG_DIR/"
  strace = "true"
EOF
cat "$RUNSC_CONF"

echo "[setup] pulling image..."
sudo ctr images pull "$IMAGE"

echo "[setup] done. gVisor is installed, config is in place, log dir is empty, container does not exist yet."
