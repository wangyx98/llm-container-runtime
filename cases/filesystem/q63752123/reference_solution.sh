#!/bin/bash
# nsfork CONTAINER VALUE: join ONLY the PID namespace of the container. The mount namespace is not joined: runc made /proc/sys read-only THERE; with the host's /proc the write goes to
# the PID namespace of the process that writes, and a process started by nsenter -p lives in the container's namespace. The child is found on the host by its pid in the container.
set -e
L=/var/lib/bench63752123
sudo tee "$L/nsfork" >/dev/null <<'SHEOF'
#!/bin/bash
L=/var/lib/bench63752123
id=$1; v=$2
pid=$($L/runc --root /run/bench63752123/runc state "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])') || exit 1
nspid=$(nsenter -t "$pid" -p -- sh -c "echo $v > /proc/sys/kernel/ns_last_pid || exit 1; sleep 3 </dev/null >/dev/null 2>&1 & echo \$!") || exit 1
ns=$(readlink "/proc/$pid/ns/pid")
for s in $(grep -l -E "^NSpid:[[:space:]]+[0-9]+[[:space:]]+$nspid\$" /proc/[0-9]*/status 2>/dev/null); do
    p=${s#/proc/}; p=${p%/status}
    [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$ns" ] && host=$p
done
printf '{"container": "%s", "value": %s, "child_ns_pid": %s, "child_host_pid": %s}\n' "$id" "$v" "$nspid" "${host:-0}"
SHEOF
sudo chmod 755 "$L/nsfork"
