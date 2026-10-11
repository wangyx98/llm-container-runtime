"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the real CRI workloads of the case, and what the node must report about them.

up:    imports three images into the 'k8s.io' namespace of the node's containerd (the sandbox image, rabbitmq:3.9 and the unused exporter:1) and
       runs, through the CRI, three pods: prod/rabbitmq-0 (container rabbitmq, user 1001, THE TARGET), staging/rabbitmq-0 (container rabbitmq too,
       user 1002) and prod/job-0 (container job, a one-shot job that has exited). The two rabbitmq containers each keep a random token in
       /data/token.txt (mode 0600, owned by their user). What the node holds is recorded in WORK/.bench/truth.json, from what this program created, not
       from what the node answers: every container with its pod, name, user, state and token, the pods and the images.
more:  the node changes: imports rabbitmq:3.10, runs qa/rabbitmq-0 (container rabbitmq, user 0) and then dev/rabbitmq-0 (container rabbitmq, user
       1001), removes the finished job (container and pod) and the image exporter:1. The record is updated.
check: fails (one short line) unless the node still holds exactly what the record says: the same pods ready, the same containers in the same
       state (none missing, none added), the same images, and the tokens still readable in the running containers under their users."""
import json
import os
import subprocess
import sys
import time
import uuid

CASE = "bench71705752"
PAUSE_REF = CASE + ".local/pause:1"
RABBIT_REF = CASE + ".local/rabbitmq:3.9"
EXPORTER_REF = CASE + ".local/exporter:1"
NEW_REF = CASE + ".local/rabbitmq:3.10"
NS = {"namespace_options": {"network": 2, "pid": 1}}   # network: NODE (no CNI needed); pid: CONTAINER


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, truth):
    json.dump(truth, open(path(work, "truth.json"), "w"), indent=1)


def remember_id(work, i):
    open(path(work, "ids.txt"), "a").write(i + "\n")


def import_image(sock, work, ref, binary):
    tar = path(work, "image.tar")
    subprocess.run([sys.executable, path(work, "mkimg.py"), ref, path(work, binary), tar], check=True, capture_output=True)
    os.chmod(tar, 0o644)
    r = subprocess.run(["sudo", "ctr", "-a", sock, "-n", "k8s.io", "images", "import", tar], capture_output=True, text=True)
    os.unlink(tar)
    if r.returncode != 0:
        sys.stderr.write("ctr could not import %s: %s\n" % (ref, r.stderr.strip()[-300:]))
        sys.exit(1)
    for _ in range(40):
        if subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "inspecti", ref],
                          capture_output=True).returncode == 0:
            return
        time.sleep(0.5)
    sys.stderr.write("the CRI does not know the image %s\n" % ref)
    sys.exit(1)


def read_in(sock, cid, *cmd):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "30s", "exec", cid, *cmd],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def start(sock, work, truth, ns, pod, name, ref, uid, mode):
    pod_file = path(work, "pod-%s-%s.json" % (ns, pod))
    puid = str(uuid.uuid4())
    labels = {"io.kubernetes.pod.name": pod, "io.kubernetes.pod.namespace": ns, "io.kubernetes.pod.uid": puid}   # what the kubelet puts on them
    json.dump({"metadata": {"name": pod, "namespace": ns, "uid": puid, "attempt": 0}, "labels": labels, "linux": {"security_context": NS}},
              open(pod_file, "w"))
    sid = cri(sock, "runp", pod_file).strip()
    remember_id(work, sid)
    cfg = {"metadata": {"name": name, "attempt": 0}, "image": {"image": ref}, "args": [mode],
           "labels": {**labels, "io.kubernetes.container.name": name},
           "linux": {"security_context": {"run_as_user": {"value": uid}, **NS}}}
    cfile = path(work, "ctr-%s-%s-%s.json" % (ns, pod, name))
    json.dump(cfg, open(cfile, "w"))
    cid = cri(sock, "create", sid, cfile, pod_file).strip()
    remember_id(work, cid)
    cri(sock, "start", cid)
    rec = {"sandbox": sid, "ns": ns, "pod": pod, "name": name, "uid": uid, "image": ref, "token": "",
           "state": "CONTAINER_RUNNING" if mode == "serve" else "CONTAINER_EXITED"}
    for _ in range(60):
        if mode == "serve":
            tok = read_in(sock, cid, "/bin/cat", "/data/token.txt")
            if tok and len(tok.strip()) == 32:
                rec["token"] = tok
                break
        else:
            st = json.loads(cri(sock, "inspect", "-o", "json", cid))["status"]["state"]
            if st == "CONTAINER_EXITED":
                break
        time.sleep(0.5)
    else:
        sys.stderr.write("the container %s/%s/%s did not reach its state\n" % (ns, pod, name))
        sys.exit(1)
    truth["pods"][sid] = {"ns": ns, "pod": pod}
    truth["containers"][cid] = rec
    save(work, truth)
    print("%s/%s/%s: container %s, user %d, %s" % (ns, pod, name, cid[:12], uid, rec["state"].replace("CONTAINER_", "").lower()))
    return cid


def up(sock, work):
    truth = {"pods": {}, "containers": {}, "images": []}
    for ref, binary in ((PAUSE_REF, "pause-bin"), (RABBIT_REF, "app-bin"), (EXPORTER_REF, "app-bin")):
        import_image(sock, work, ref, binary)
        truth["images"].append(ref)
    save(work, truth)
    start(sock, work, truth, "prod", "rabbitmq-0", "rabbitmq", RABBIT_REF, 1001, "serve")
    start(sock, work, truth, "staging", "rabbitmq-0", "rabbitmq", RABBIT_REF, 1002, "serve")
    start(sock, work, truth, "prod", "job-0", "job", RABBIT_REF, 1001, "done")


def more(sock, work):
    truth = load(work)
    import_image(sock, work, NEW_REF, "app-bin")
    truth["images"].append(NEW_REF)
    save(work, truth)
    start(sock, work, truth, "qa", "rabbitmq-0", "rabbitmq", NEW_REF, 0, "serve")
    start(sock, work, truth, "dev", "rabbitmq-0", "rabbitmq", NEW_REF, 1001, "serve")
    for cid, c in list(truth["containers"].items()):
        if c["name"] == "job":
            cri(sock, "rm", cid)
            cri(sock, "stopp", c["sandbox"])
            cri(sock, "rmp", c["sandbox"])
            del truth["containers"][cid]
            del truth["pods"][c["sandbox"]]
    cri(sock, "rmi", EXPORTER_REF)
    truth["images"].remove(EXPORTER_REF)
    save(work, truth)
    print("added the pods qa and dev and the image rabbitmq:3.10; removed the pod job-0 and the image exporter:1")


def check(sock, work):
    truth = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    live = {c["id"]: c["state"] for c in json.loads(cri(sock, "ps", "-a", "-o", "json"))["containers"]}
    for cid, c in truth["containers"].items():
        name = "%s/%s/%s" % (c["ns"], c["pod"], c["name"])
        if cid not in live:
            bad("the container %s (%s) is gone" % (cid[:12], name))
        if live[cid] != c["state"]:
            bad("the container %s (%s) is now %s, it was %s" % (cid[:12], name, live[cid].replace("CONTAINER_", "").lower(),
                                                                 c["state"].replace("CONTAINER_", "").lower()))
    extra = [i for i in live if i not in truth["containers"]]
    if extra:
        bad("%d container(s) were added (%s)" % (len(extra), ", ".join(i[:12] for i in extra[:3])))
    pods = {p["id"]: p["state"] for p in json.loads(cri(sock, "pods", "-o", "json"))["items"]}
    for sid in truth["pods"]:
        if pods.get(sid) != "SANDBOX_READY":
            bad("the pod %s/%s is gone or not ready" % (truth["pods"][sid]["ns"], truth["pods"][sid]["pod"]))
    if [s for s in pods if s not in truth["pods"]]:
        bad("pod(s) were added")
    images = sorted(t for i in json.loads(cri(sock, "images", "-o", "json"))["images"] for t in i.get("repoTags", []))
    if images != sorted(truth["images"]):
        bad("the images are %s, not %s" % (images, sorted(truth["images"])))
    for cid, c in truth["containers"].items():
        if c["state"] == "CONTAINER_RUNNING":
            tok = read_in(sock, cid, "/bin/cat", "/data/token.txt")
            uid = read_in(sock, cid, "/bin/id", "-u")
            if tok != c["token"] or (uid or "").strip() != str(c["uid"]):
                bad("the container %s/%s/%s does not give its token or its user any more" % (c["ns"], c["pod"], c["name"]))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
