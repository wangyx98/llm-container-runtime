#!/bin/bash
# Reference: two wrappers in the user's bin that run ctr and crictl INSIDE the mount namespace of the rootless runner (nsenter -U --preserve-credentials -m -t <rootlesskit's child>),
# where the socket exists. Nothing is looked up once and written into the script: the child PID (it changes at every restart of the service) is read from rootlesskit's state dir
# at every call, and the socket address from the --config file of the containerd process in that mount namespace (rootlesskit's child is NOT the containerd: it runs it as its own child). No rootful socket, no sudo for the user, no link on the host's file system; sudo only to act as the user.
set -e

U=bench72968351
H=/home/$U
RT=/run/user/$(id -u $U)

as_user() { sudo -u $U -H env XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus "$@"; }

as_user mkdir -p $H/bin

# the namespace the CRI uses is k8s.io: it is the default of the wrappers (CONTAINERD_NAMESPACE is ctr's own switch for it; crictl always talks to the CRI)
as_user tee $H/bin/ctr-k3s >/dev/null <<'SCRIPT'
#!/bin/sh
RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
CP=$(cat "$RT/bench72968351-rootlesskit/child_pid") || { echo "ctr-k3s: the rootless runner is not running" >&2; exit 1; }
NS=$(readlink "/proc/$CP/ns/mnt")
for p in $(pgrep -u "$(id -u)" -x containerd); do [ "$(readlink "/proc/$p/ns/mnt")" = "$NS" ] && CD=$p && break; done
CFG=$(tr '\0' '\n' < "/proc/${CD:?}/cmdline" | sed -n '/^--config$/{n;p}')
SOCK=$(sed -n 's/^ *address *= *"\(.*\)"/\1/p' "$CFG")
export CONTAINERD_NAMESPACE=${CONTAINERD_NAMESPACE:-k8s.io}
exec nsenter -U --preserve-credentials -m -t "$CP" ctr --address "$SOCK" "$@"
SCRIPT
as_user tee $H/bin/crictl-k3s >/dev/null <<'SCRIPT'
#!/bin/sh
RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
CP=$(cat "$RT/bench72968351-rootlesskit/child_pid") || { echo "crictl-k3s: the rootless runner is not running" >&2; exit 1; }
NS=$(readlink "/proc/$CP/ns/mnt")
for p in $(pgrep -u "$(id -u)" -x containerd); do [ "$(readlink "/proc/$p/ns/mnt")" = "$NS" ] && CD=$p && break; done
CFG=$(tr '\0' '\n' < "/proc/${CD:?}/cmdline" | sed -n '/^--config$/{n;p}')
SOCK=$(sed -n 's/^ *address *= *"\(.*\)"/\1/p' "$CFG")
exec nsenter -U --preserve-credentials -m -t "$CP" crictl --runtime-endpoint "unix://$SOCK" --image-endpoint "unix://$SOCK" "$@"
SCRIPT
as_user chmod +x $H/bin/ctr-k3s $H/bin/crictl-k3s

echo "check:"
as_user $H/bin/ctr-k3s images ls -q
as_user $H/bin/crictl-k3s images
echo "done: $H/bin/ctr-k3s and $H/bin/crictl-k3s talk to the rootless runner of $U"
