"""emit.py SOCK WORKDIR STREAM PAYLOAD_FILE : run a workload through the CRI of the containerd at SOCK, the way a kubelet would: a pod sandbox
(log directory), a container of the image bench73415919.local/app:1 that mounts PAYLOAD_FILE at /data/payload and writes its content plus a
newline, with ONE write call, to STREAM (stdout or stderr), then exits. When the container has exited, the CRI log file it wrote is parsed
(<timestamp> <stream> <P|F> <text>, one record per line; P: a partial line, F: the end of a line) and a summary is printed as one JSON object:
{"records": [{"stream", "tag", "n"}...], "sha": sha256 of the texts of the records joined, "total": their total length, "ok": the shape is a legal
sequence (P* then F, one stream)}. The pod is removed at the end."""
import hashlib
import json
import os
import subprocess
import sys
import time
import uuid

sock, work, stream, payload = sys.argv[1:5]
APP_REF = "bench73415919.local/app:1"
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER


def cri(*args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


uid = str(uuid.uuid4())
logdir = os.path.join(work, "logs", uid)
os.makedirs(logdir, exist_ok=True)
pod_cfg = {"metadata": {"name": "emit", "namespace": "bench73415919", "uid": uid, "attempt": 0}, "log_directory": logdir, **NS}
pod_file = os.path.join(work, uid + ".pod.json")
json.dump(pod_cfg, open(pod_file, "w"))
sandbox = cri("runp", pod_file)
ids = os.path.join(work, ".bench", "ids.txt")   # cleanup.sh removes the runc state of these (a container that was never deleted leaves some)
open(ids, "a").write(sandbox + "\n")
try:
    cfg = {"metadata": {"name": "emit", "attempt": 0}, "image": {"image": APP_REF}, "args": ["emit", stream],
           "mounts": [{"container_path": "/data/payload", "host_path": os.path.abspath(payload), "readonly": True}],
           "log_path": "emit_0.log", **NS}
    cfile = os.path.join(work, uid + ".emit.json")
    json.dump(cfg, open(cfile, "w"))
    cid = cri("create", sandbox, cfile, pod_file)
    open(ids, "a").write(cid + "\n")
    cri("start", cid)
    for _ in range(120):
        if cri("inspect", "-o", "go-template", "--template", "{{.status.state}}", cid, check=False) == "CONTAINER_EXITED":
            break
        time.sleep(0.5)
    else:
        sys.stderr.write("the container did not exit\n")
        sys.exit(1)
    exit_code = cri("inspect", "-o", "go-template", "--template", "{{.status.exitCode}}", cid)
    if exit_code != "0":
        sys.stderr.write("the container exited with %s\n" % exit_code)
        sys.exit(1)
    path = os.path.join(logdir, "emit_0.log")
    last = -1
    raw = b""
    for _ in range(40):                      # the log is complete when its last record is the end of a line and it stopped growing
        r = subprocess.run(["sudo", "cat", path], capture_output=True)
        raw = r.stdout
        lines = raw.split(b"\n")
        done = len(raw) == last and raw.endswith(b"\n") and lines[-2].split(b" ", 3)[2:3] == [b"F"]
        last = len(raw)
        if done:
            break
        time.sleep(0.5)
    records, texts = [], []
    for line in raw.split(b"\n"):
        if not line:
            continue
        ts, st, tag, text = (line.split(b" ", 3) + [b""])[:4]
        records.append({"stream": st.decode(), "tag": tag.decode(), "n": len(text)})
        texts.append(text)
    ok = bool(records) and all(r["tag"] == "P" for r in records[:-1]) and records[-1]["tag"] == "F" and len({r["stream"] for r in records}) == 1
    print(json.dumps({"records": records, "sha": hashlib.sha256(b"".join(texts)).hexdigest(), "total": sum(len(t) for t in texts), "ok": ok}))
finally:
    cri("stopp", sandbox, check=False)
    cri("rmp", sandbox, check=False)
