#!/bin/bash
# `ctr images ls` lists the images of ONE containerd namespace, "default" unless -n is given; the images the kubelet uses are in "k8s.io", and a
# node can have more namespaces (`ctr namespaces ls`). The same name in two namespaces can be two different images. The node's containerd is
# not at the default socket, so the socket is given. The CRI plugin also adds an entry named by the bare image ID (sha256:...) for each image
# of k8s.io: it is not an image name, so it is left out.
set -e
cat > /tmp/bench71582111/list-images.sh <<'SCRIPT'
#!/bin/bash
# list-images.sh OUTPUT_FILE
SOCK=/run/bench71582111/containerd/containerd.sock
CTR=(sudo ctr -a "$SOCK")
: > "$1"
for ns in $("${CTR[@]}" namespaces ls -q 2>/dev/null); do
    "${CTR[@]}" -n "$ns" images ls 2>/dev/null | awk -v ns="$ns" 'NR > 1 && $1 !~ /^sha256:/ { print ns, $1, $3 }' >> "$1"
done
SCRIPT
chmod +x /tmp/bench71582111/list-images.sh

bash /tmp/bench71582111/list-images.sh /tmp/bench71582111/images.txt
cat /tmp/bench71582111/images.txt
