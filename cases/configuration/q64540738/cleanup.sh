#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench64540738"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/ctd/containerd.sock"
REG_ADDR="10.66.54.40"
FAASD_BIN="/usr/local/bin/faasd"
FAASD_DIR="/var/lib/faasd"
CREATED="$LIB_BASE/created"
# the sha256 of the four release binaries of this case (faasd 0.10.0 and 0.13.0, amd64 and arm64): such a file at $FAASD_BIN is this case's, whoever put it there
KNOWN_SHAS="0cc48c642e077b9244ff0ae6147f196fcbc99bd4c22fa68b7260e23c8082af06 b830b084dffb00805c7645c99b53b2913dd6cfb5d4c45ff91857edcc2b4b33ab afafdfb84fea1128260d90e243d1616d3377be80a80828ce40e30c9e11d9a7e4 8d642ba3c2395d7d6e3c0dac52be8731213ca30433548fbd775fc6e37760eaa2"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's
# run dir). Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also
# kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "${3:-$RUN_BASE}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "${2:-$RUN_BASE}" && return 0
    done
    return 1
}

# the functions' containers of the private containerd: the ids are collected first (to find their processes and cgroups afterwards), then each task is killed
# and removed through containerd so that the runtime lets go of its mounts and network
IDS=""
if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container of the private containerd..."
    CT="sudo timeout -k 3 20 ctr -a $CTD_SOCK -n openfaas-fn"
    IDS="$($CT containers ls -q 2>/dev/null)"
    for id in $IDS; do $CT tasks kill -s KILL "$id" >/dev/null 2>&1 || true; done
    sleep 1
    for id in $IDS; do $CT tasks rm -f "$id" >/dev/null 2>&1 || true; $CT containers rm "$id" >/dev/null 2>&1 || true; done
fi

echo "[cleanup] stopping this case's faasd provider, containerd and registry and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours ctr KILL
kill_ours curl KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours python3 KILL "$LIB_BASE/registry"          # the registry
kill_ours python3 KILL "$WORK_DIR"                   # and any forwarder a solution started from the work dir
# faasd: the provider, and the log binary the shims run (the same program); a replaced binary shows as "(deleted)"
for d in /proc/[0-9]*; do
    case "$(sudo readlink "$d/exe" 2>/dev/null)" in
        "$FAASD_BIN"|"$FAASD_BIN (deleted)") sudo kill -TERM "${d#/proc/}" 2>/dev/null || true ;;
    esac
done
kill_ours containerd TERM "$LIB_BASE/etc/containerd.toml"
for _ in $(seq 1 30); do any_ours containerd "$LIB_BASE/etc/containerd.toml" || break; sleep 0.5; done
kill_ours containerd KILL "$LIB_BASE/etc/containerd.toml"
for d in /proc/[0-9]*; do
    case "$(sudo readlink "$d/exe" 2>/dev/null)" in
        "$FAASD_BIN"|"$FAASD_BIN (deleted)") sudo kill -KILL "${d#/proc/}" 2>/dev/null || true ;;
    esac
done
for comm in containerd-shim-runc-v2 containerd-shim; do kill_ours "$comm" KILL "-namespace openfaas-fn"; done
# the programs of the containers: they sit in the cgroups named by the containers' ids
for id in $IDS; do
    [ ${#id} -ge 8 ] || continue
    for d in /proc/[0-9]*; do
        if sudo grep -qF "$id" "$d/cgroup" 2>/dev/null; then sudo kill -KILL "${d#/proc/}" 2>/dev/null || true; fi
    done
done
# the process that holds the private mount namespace of the daemons (its pid is in the pid file)
if [ -s "$RUN_BASE/holder.pid" ]; then
    hp=$(cat "$RUN_BASE/holder.pid")
    [ "$(cat "/proc/$hp/comm" 2>/dev/null)" = "sleep" ] && sudo kill -KILL "$hp" 2>/dev/null
fi
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount. (The daemons' own bind and overlay mounts live in their private
# namespace and are gone with it.)
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR" $(ls -d "$WORK_DIR"-* 2>/dev/null); do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups containerd made for the containers (they are named by the ids); empty now that the processes are gone
for id in $IDS; do
    [ ${#id} -ge 8 ] || continue
    sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "*$id*" -exec rmdir {} \; 2>/dev/null || true
done

# the network of faasd's functions: the bridge openfaas0 with the ports of the functions, and the iptables rules and chains the CNI plugins (bridge: masquerade, firewall)
# made for 10.62.0.0/16 and the function addresses; the chains CNI-FORWARD and CNI-ADMIN and the packet-forwarding switch go back to what they were before the setup
if ip link show openfaas0 >/dev/null 2>&1; then
    for l in $(ip -o link show master openfaas0 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do sudo ip link del "$l" 2>/dev/null || true; done
    sudo ip link del openfaas0 2>/dev/null || true
fi
CHAINS="$(sudo iptables-save -t nat 2>/dev/null | grep -E '^-A POSTROUTING .*(openfaas-cni-bridge|10\.62\.)' | grep -o -- '-j CNI-[0-9a-f]*' | awk '{print $2}' | sort -u)"
sudo iptables-save -t nat 2>/dev/null | grep -E '^-A POSTROUTING .*(openfaas-cni-bridge|10\.62\.)' | sed 's/^-A /-D /' | while read -r rule; do eval "sudo iptables -w -t nat $rule" 2>/dev/null || true; done
for c in $CHAINS; do sudo iptables -w -t nat -F "$c" 2>/dev/null; sudo iptables -w -t nat -X "$c" 2>/dev/null; done
sudo iptables-save 2>/dev/null | grep -E '^-A (CNI-FORWARD|CNI-ADMIN) .*10\.62\.' | sed 's/^-A /-D /' | while read -r rule; do eval "sudo iptables -w $rule" 2>/dev/null || true; done
if grep -qx 'chain CNI-FORWARD absent' "$CREATED" 2>/dev/null; then
    sudo iptables-save 2>/dev/null | grep -E '^-A FORWARD .*-j CNI-FORWARD' | sed 's/^-A /-D /' | while read -r rule; do eval "sudo iptables -w $rule" 2>/dev/null || true; done
    sudo iptables -w -F CNI-FORWARD 2>/dev/null; sudo iptables -w -X CNI-FORWARD 2>/dev/null
fi
if grep -qx 'chain CNI-ADMIN absent' "$CREATED" 2>/dev/null; then sudo iptables -w -F CNI-ADMIN 2>/dev/null; sudo iptables -w -X CNI-ADMIN 2>/dev/null; fi
fw=$(sed -n 's/^ip_forward //p' "$CREATED" 2>/dev/null | head -1)
if [ -n "$fw" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "$fw" ]; then echo "$fw" | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null; fi

# the address of the registry
if ip -4 addr show dev lo 2>/dev/null | grep -qF "$REG_ADDR/"; then sudo ip addr del "$REG_ADDR/32" dev lo 2>/dev/null || true; fi

# the files of faasd: the provider binary (this case's own release binary, or whatever stands there when the case's marker does) and /var/lib/faasd with the marker
if [ -f "$FAASD_BIN" ]; then
    h=$(sha256sum "$FAASD_BIN" 2>/dev/null | cut -d' ' -f1)
    case " $KNOWN_SHAS " in *" $h "*) sudo rm -f "$FAASD_BIN" ;; *) [ -e "$FAASD_DIR/.$CASE_ID" ] && sudo rm -f "$FAASD_BIN" ;; esac
fi
[ -e "$FAASD_DIR/.$CASE_ID" ] && sudo rm -rf --one-file-system "$FAASD_DIR"

echo "[cleanup] removing the containerd, registry and faasd state..."
# the directories this case created for its private mounts, deepest first (only when empty)
if [ -f "$CREATED" ]; then
    for d in $(grep '^dir ' "$CREATED" | cut -c5- | tac); do sudo rmdir "$d" 2>/dev/null || true; done
fi
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
