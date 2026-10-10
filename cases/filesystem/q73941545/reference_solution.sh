#!/bin/bash
set -e

# `ctr images ls` shows nothing because it talks to the wrong daemon (here the node's own containerd), and it would also look
# into the wrong namespace: the kubelet of K3s uses its OWN containerd, a second daemon whose command line shows its socket
# ('containerd -c <config> -a <socket> --state <dir> --root <dir>'), and the CRI keeps everything in the namespace "k8s.io".
# So the query is ctr (or crictl) against that socket and that namespace.
SOCK=$(ps -eo comm,args | awk '$1=="containerd" { for (i = 3; i < NF; i++) if ($i == "-a") { print $(i + 1); exit } }')
[ -S "$SOCK" ] || { echo "no K3s containerd socket found"; exit 1; }
WORK=/tmp/bench73941545
mkdir -p "$WORK"

cat > "$WORK/lookup.sh" <<'EOF'
#!/bin/bash
# usage: lookup.sh image REF       -> the digest of the image, as containerd of K3s has it (exit 1: no such image)
#        lookup.sh container ID    -> running | stopped                                      (exit 1: no such container)
SOCK=@SOCK@
CTR="ctr -a $SOCK -n k8s.io"
case "$1" in
    image)
        d=$($CTR images ls 2>/dev/null | awk -v r="$2" '$1 == r { print $3; exit }')
        [ -n "$d" ] || { echo "no image $2 in the K3s containerd" >&2; exit 1; }
        echo "$d"
        ;;
    container)
        $CTR containers ls -q 2>/dev/null | grep -qxF -- "$2" || { echo "no container $2 in the K3s containerd" >&2; exit 1; }
        if [ "$($CTR tasks ls 2>/dev/null | awk -v c="$2" '$1 == c { print $3 }')" = RUNNING ]; then echo running; else echo stopped; fi
        ;;
    *)
        echo "usage: lookup.sh image REF | container ID" >&2; exit 2
        ;;
esac
EOF
sed -i "s|@SOCK@|$SOCK|" "$WORK/lookup.sh"

CRI="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK"
echo "image bench73941545.local/app:1:"; sudo bash "$WORK/lookup.sh" image bench73941545.local/app:1
CID=$($CRI ps -q --name '^bench73941545-app$')
echo "container of the pod ($CID):"; sudo bash "$WORK/lookup.sh" container "$CID"
