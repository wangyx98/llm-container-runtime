#!/bin/bash
# Docker and the CRI plugin can use the same containerd, but each keeps its objects in a containerd namespace of its own: Docker in "moby", the CRI plugin in "k8s.io"; `ctr`
# looks at "default" unless -n is given, which is empty here. `docker ps` talks to Docker's own API socket and lists Docker's containers (not the CRI's); `crictl` talks
# CRI to containerd's socket: `crictl ps` lists the CRI containers and `crictl pods` the pod sandboxes (a sandbox is a container of containerd, in k8s.io, but not a
# container of the CRI); `ctr -n NAME containers list` lists what is in one namespace. The Kubernetes namespace of a pod (a label of the pod: default) is not a containerd
# namespace. `ps` and `crictl ps` without -a list the running containers only. Docker removes a container from containerd when it stops, so containerd's "moby" has the running ones only.
set -e
cat > /tmp/bench48616250/list-containers.sh <<'SCRIPT'
#!/bin/bash
# list-containers.sh OUTPUT_FILE
python3 - "$1" <<'PY'
import json
import subprocess
import sys

out = sys.argv[1]
DSOCK = "/run/bench48616250/docker.sock"
CSOCK = "/run/bench48616250/containerd/containerd.sock"


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def docker(*args):
    return run("docker", "-H", "unix://" + DSOCK, *args)


def cri(*args):
    return run("sudo", "crictl", "--runtime-endpoint", "unix://" + CSOCK, "--image-endpoint", "unix://" + CSOCK, "--timeout", "60s", *args)


def ctr(*args):
    return run("sudo", "ctr", "-a", CSOCK, *args)


pods = json.loads(cri("pods", "-o", "json"))["items"]
namespaces = sorted(set(ctr("namespaces", "ls", "-q").split()) | {"default"})
json.dump({
    "docker": {"socket": DSOCK, "containerd_namespace": "moby",
               "containers": docker("ps", "-a", "-q", "--no-trunc").split()},
    "cri": {"socket": CSOCK, "containerd_namespace": "k8s.io",
            "kubernetes_namespace": pods[0]["metadata"]["namespace"],
            "containers": cri("ps", "-a", "-q", "--no-trunc").split(),
            "sandboxes": [p["id"] for p in pods]},
    "ctr": {"socket": CSOCK, "namespaces": {ns: ctr("-n", ns, "containers", "ls", "-q").split() for ns in namespaces}},
}, open(out, "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench48616250/list-containers.sh

bash /tmp/bench48616250/list-containers.sh /tmp/bench48616250/containers.json
python3 -c 'import json; d = json.load(open("/tmp/bench48616250/containers.json")); print({k: (v["socket"].split("/")[-1], v.get("containerd_namespace")) for k, v in d.items() if k != "ctr"}); print({n: len(v) for n, v in d["ctr"]["namespaces"].items()})'
