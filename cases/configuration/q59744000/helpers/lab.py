"""lab.py images SOCK WORK | manifests DIR | control cgroupfs|systemd SOCK WORK : the lab of the node.

images:    imports the sandbox image and the images of the two static pods (calico-node, kube-proxy) into the 'k8s.io' namespace of the node's containerd.
manifests: writes the static pod manifests calico-node.json (QoS burstable) and kube-proxy.json (besteffort) into DIR, each with a new random pod uid.
control:   one pod made by hand through the CRI, to show what the node can and cannot do; it is removed afterwards. Prints one line, exits 1 if it did not work.
             cgroupfs  the cgroupfs style cgroup parent (/kubepods/burstable/pod<uid>) on the runtime handler runc-cgroupfs, whose runc uses the cgroupfs driver
             systemd   the systemd style cgroup parent (kubepods-burstable-pod<uid>.slice) on the default runtime, whose runc uses the systemd driver"""
import glob
import json
import os
import subprocess
import sys
import time
import uuid

CASE = "bench59744000"
PAUSE_REF = CASE + ".local/pause:1"
CALICO_REF = CASE + ".local/calico-node:v3.11.1"
PROXY_REF = CASE + ".local/kube-proxy:v1.17.0"
NS = {"namespace_options": {"network": 2, "pid": 1}}


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if check and r.returncode != 0:
        raise RuntimeError((r.stderr.strip() or r.stdout.strip()).replace("\n", " ")[-500:])
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def import_image(sock, work, ref, binary):
    tar = path(work, "image.tar")
    subprocess.run([sys.executable, path(work, "mkimg.py"), ref, path(work, binary), tar], check=True, capture_output=True)
    os.chmod(tar, 0o644)
    r = subprocess.run(["sudo", "ctr", "-a", sock, "-n", "k8s.io", "images", "import", tar], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    os.unlink(tar)
    if r.returncode != 0:
        sys.exit("ctr could not import %s: %s" % (ref, r.stderr.strip()[-300:]))
    for _ in range(40):
        if subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "inspecti", ref],
                          capture_output=True, stdin=subprocess.DEVNULL).returncode == 0:
            return
        time.sleep(0.5)
    sys.exit("the CRI does not know the image %s" % ref)


def images(sock, work):
    for ref, binary in ((PAUSE_REF, "pause-bin"), (CALICO_REF, "app-bin"), (PROXY_REF, "app-bin")):
        import_image(sock, work, ref, binary)
    print("images: %s, %s, %s" % (PAUSE_REF, CALICO_REF, PROXY_REF))


def manifests(directory):
    os.makedirs(directory, exist_ok=True)
    for name, ref, qos in (("calico-node", CALICO_REF, "burstable"), ("kube-proxy", PROXY_REF, "besteffort")):
        json.dump({"name": name, "namespace": "kube-system", "uid": str(uuid.uuid4()), "qos": qos,
                   "containers": [{"name": name, "image": ref, "mode": "serve", "user": 0}]}, open(os.path.join(directory, name + ".json"), "w"), indent=1)
    os.chmod(directory, 0o755)
    for n in os.listdir(directory):
        os.chmod(os.path.join(directory, n), 0o644)


def hierarchies():
    """/sys/fs/cgroup (cgroup v2: the one hierarchy) and every directory below it that is a cgroup v1 hierarchy (cpu, memory, ...)"""
    return ["/sys/fs/cgroup"] + [h.rstrip("/") for h in sorted(glob.glob("/sys/fs/cgroup/*/"))]


def control(kind, sock, work):
    puid = str(uuid.uuid4())
    if kind == "cgroupfs":
        parent, handler = "/kubepods/burstable/pod" + puid, "runc-cgroupfs"
        cg = parent
    else:
        parent, handler = "kubepods-burstable-pod%s.slice" % puid.replace("-", "_"), ""
        cg = ""
    labels = {"io.kubernetes.pod.name": "control-" + kind, "io.kubernetes.pod.namespace": "bench-control", "io.kubernetes.pod.uid": puid}
    pod = path(work, "control-pod.json")
    json.dump({"metadata": {"name": "control-" + kind, "namespace": "bench-control", "uid": puid, "attempt": 0}, "labels": labels,
               "linux": {"cgroup_parent": parent, "security_context": NS}}, open(pod, "w"))
    if cg:
        open(path(work, "cgroups.txt"), "a").write(cg + "\n")
        if not any(os.path.isdir(h + "/kubepods") for h in hierarchies()):
            open(path(work, "kubepods-created"), "w").close()
    sid = cid = ""
    try:
        sid = cri(sock, "runp", *(["--runtime", handler] if handler else []), pod).strip()
        open(path(work, "ids.txt"), "a").write(sid + "\n")
        ctr = path(work, "control-ctr.json")
        json.dump({"metadata": {"name": "control", "attempt": 0}, "image": {"image": CALICO_REF}, "args": ["serve"], "labels": {**labels, "io.kubernetes.container.name": "control"},
                   "linux": {"security_context": {"run_as_user": {"value": 0}, **NS}}}, open(ctr, "w"))
        cid = cri(sock, "create", sid, ctr, pod).strip()
        open(path(work, "ids.txt"), "a").write(cid + "\n")
        cri(sock, "start", cid)
        for _ in range(40):
            tok = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "30s", "exec", cid, "/bin/cat", "/data/token.txt"],
                                 capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
            if len(tok) == 32:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("the container started but gives no token")
    except RuntimeError as e:
        print("control %s: the pod with the cgroup parent %s did not run: %s" % (kind, parent, e))
        sys.exit(1)
    finally:
        if cid:
            cri(sock, "rm", "-f", cid, check=False)
        if sid:
            cri(sock, "stopp", sid, check=False)
            cri(sock, "rmp", sid, check=False)
        if cg:   # the cgroup of the pod itself that runc made on the cgroupfs driver (an empty directory in every hierarchy of this host)
            subprocess.run(["sudo", "rmdir", *[h + cg for h in hierarchies()]], capture_output=True, stdin=subprocess.DEVNULL)
    print("control %s: a pod with the cgroup parent %s ran (handler %s)" % (kind, parent, handler or "default"))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "images":
        images(sys.argv[2], sys.argv[3])
    elif cmd == "manifests":
        manifests(sys.argv[2])
    elif cmd == "control":
        control(sys.argv[2], sys.argv[3], sys.argv[4])
