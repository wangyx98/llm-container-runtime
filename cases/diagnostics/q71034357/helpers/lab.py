"""lab.py up SOCK WORK | more SOCK WORK | keep SOCK WORK : the real CRI workloads of the case and what they were told to log.

up:   one pod (default/batch-0, log directory WORK/logs, like the kubelet's /var/log/pods/...) with three real CRI containers of the image
      bench71034357.local/app:1, which logs what a file tells it to (a script per container in WORK/data/NAME-ATTEMPT/script.txt, mounted at /data):
        job, attempt 0: logs random messages on stdout and on stderr (a few with awkward bytes: leading blanks and a tab, UTF-8, an empty line,
                backslashes and quotes, 3000 characters, 20000 characters, which the node writes as partial records), has its log rotated twice the
                way the kubelet does it (the file is renamed log.TIMESTAMP, the runtime is asked to reopen the log path, the older rotated file is
                gzipped), and exits with an exit code the lab chose. Its log is now spread over 0.log, 0.log.TIME2 and 0.log.TIME1.gz.
        job, attempt 1: the restart: a new container of the same name, logging other random messages, still running.
        web: a container that runs and logs.
      What each container logged is recorded, from what the lab told it, in WORK/.bench/truth.json: the bytes of its stdout and of its stderr, its
      state, its exit code and reason, and the log files it has (names, sizes, hashes).
more: job attempt 1 logs four more messages and exits with the code 0 (the second stopped container); the record is updated.
keep: fails (one short line) unless the node is as the record says: the pod ready, every container in the state recorded (and with the exit code
      recorded), no container added, and every log file of every container exactly as recorded (nothing moved, truncated, removed or added)."""
import base64
import gzip
import hashlib
import json
import os
import random
import re
import string
import subprocess
import sys
import time
import uuid

APP_REF = "bench71034357.local/app:1"
R = random.SystemRandom()
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, truth):
    json.dump(truth, open(path(work, "truth.json"), "w"), indent=1)


def sudo_cat(p):
    return subprocess.run(["sudo", "cat", p], capture_output=True).stdout


def hexs(n):
    return "".join(R.choices("0123456789abcdef", k=n))


def messages(name, attempt, seq, n, specials):
    """n random messages (stream, bytes); markers name-aN-SEQ tell the container and the attempt apart"""
    out = []
    for i in range(n):
        text = ("%s-a%d-%04d-%s %s" % (name, attempt, seq + i, hexs(R.randint(16, 64)), " ".join(hexs(R.randint(2, 9)) for _ in range(R.randint(0, 12))))).strip()
        out.append(("e" if R.random() < 0.35 else "o", text.encode()))
    if specials:
        tag = "%s-a%d-s" % (name, attempt)
        out += [("o", ("  %s indented\twith a tab and a trailing blank " % tag).encode()),
                ("e", ("%s: ünïcödé 日本語 ✓ %s" % (tag, hexs(8))).encode("utf-8")),
                ("o", b""),
                ("e", ("%s: back\\slash %%s %%d 'q' \"dq\" $HOME `x` %s" % (tag, hexs(8))).encode()),
                ("o", ("%s-long-%s" % (tag, "".join(R.choices(string.ascii_letters + string.digits, k=3000)))).encode()),
                ("e", ("%s-huge-%s" % (tag, "".join(R.choices(string.ascii_letters + string.digits, k=20000)))).encode())]
        R.shuffle(out)
    return out


def log_files(work, name, attempt):
    """the log files of an attempt, oldest first: the rotated ones by their timestamp, then the current one"""
    d = os.path.join(work, "logs", name)
    cur = "%d.log" % attempt
    names = os.listdir(d) if os.path.isdir(d) else []
    rot = sorted(n for n in names if re.fullmatch(re.escape(cur) + r"\.\d{8}-\d{6}(\.gz)?", n))
    return [os.path.join(d, n) for n in rot] + ([os.path.join(d, cur)] if cur in names else [])


def payload(files):
    res = {"stdout": b"", "stderr": b""}
    for f in files:
        raw = sudo_cat(f)
        if f.endswith(".gz"):
            raw = gzip.decompress(raw)
        for line in raw.split(b"\n"):
            if line:
                ts, st, tag, text = (line.split(b" ", 3) + [b""])[:4]
                res[st.decode()] += text + (b"\n" if tag == b"F" else b"")
    return res


def snapshot(work, name, attempt):
    return {os.path.basename(f): hashlib.sha256(sudo_cat(f)).hexdigest() for f in log_files(work, name, attempt)}


def add(work, rec, msgs, exit_code=None):
    """append the messages (and an exit order) to the script of a container, and to what it must have logged"""
    d = os.path.join(work, "data", "%s-%d" % (rec["name"], rec["attempt"]))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "script.txt"), "ab") as f:
        for s, t in msgs:
            f.write(s.encode() + b" " + t + b"\n")
        if exit_code is not None:
            f.write(b"x %d\n" % exit_code)
    for s, t in msgs:
        k = "stdout" if s == "o" else "stderr"
        rec[k] = base64.b64encode(base64.b64decode(rec[k]) + t + b"\n").decode()


def wait_logs(work, rec):
    want = {k: base64.b64decode(rec[k]) for k in ("stdout", "stderr")}
    got = {}
    for _ in range(120):
        got = payload(log_files(work, rec["name"], rec["attempt"]))
        if got == want:
            return
        time.sleep(0.3)
    sys.stderr.write("the log of %s (attempt %d) did not get all the messages in 36 s (stdout %d of %d bytes, stderr %d of %d)\n"
                     % (rec["name"], rec["attempt"], len(got.get("stdout", b"")), len(want["stdout"]), len(got.get("stderr", b"")), len(want["stderr"])))
    sys.exit(1)


def wait_state(sock, cid, state):
    for _ in range(120):
        st = json.loads(cri(sock, "inspect", "-o", "json", cid))["status"]
        if st["state"] == state:
            return st
        time.sleep(0.25)
    sys.stderr.write("the container %s did not reach %s\n" % (cid[:12], state))
    sys.exit(1)


def create(sock, work, truth, name, attempt, msgs, exit_code=None):
    pod = truth["pod"]
    rec = {"name": name, "attempt": attempt, "stdout": "", "stderr": "", "state": "running", "exit": None, "reason": None, "files": {}}
    add(work, rec, msgs, exit_code)
    os.makedirs(os.path.join(work, "logs", name), exist_ok=True)
    labels = {"io.kubernetes.pod.name": "batch-0", "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": pod["uid"],
              "io.kubernetes.container.name": name}
    cfg = {"metadata": {"name": name, "attempt": attempt}, "image": {"image": APP_REF}, "args": ["serve", "/data/script.txt"], "labels": labels,
           "mounts": [{"container_path": "/data", "host_path": os.path.join(work, "data", "%s-%d" % (name, attempt)), "readonly": True}],
           "log_path": "%s/%d.log" % (name, attempt), **NS}
    cfile = path(work, "ctr-%s-%d.json" % (name, attempt))
    json.dump(cfg, open(cfile, "w"))
    cid = cri(sock, "create", pod["id"], cfile, pod["file"])
    open(path(work, "ids.txt"), "a").write(cid + "\n")
    cri(sock, "start", cid)
    truth["containers"][cid] = rec
    save(work, truth)
    return cid, rec


def rotate(sock, work, cid, rec, compress_previous):
    """what the kubelet does to a log: rename it, have the runtime reopen the path, gzip the older rotated file"""
    cur = os.path.join(work, "logs", rec["name"], "%d.log" % rec["attempt"])
    rot = cur + "." + time.strftime("%Y%m%d-%H%M%S")
    subprocess.run(["sudo", "mv", cur, rot], check=True)
    r = subprocess.run(["sudo", sys.executable, path(work, "reopen.py"), sock, cid], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write("reopen failed: %s\n" % (r.stdout + r.stderr).strip()[-300:])
        sys.exit(1)
    for _ in range(40):
        if subprocess.run(["sudo", "test", "-e", cur]).returncode == 0:
            break
        time.sleep(0.25)
    else:
        sys.stderr.write("the runtime did not create the log file again after the reopen\n")
        sys.exit(1)
    if compress_previous:
        for f in log_files(work, rec["name"], rec["attempt"]):
            if f != rot and re.search(r"\.\d{8}-\d{6}$", f):
                subprocess.run(["sudo", "gzip", "-f", f], check=True)


def finish(sock, work, truth, cid, rec):
    st = wait_state(sock, cid, "CONTAINER_EXITED")
    rec["state"], rec["exit"], rec["reason"] = "exited", st["exitCode"], st["reason"]
    wait_logs(work, rec)
    rec["files"] = snapshot(work, rec["name"], rec["attempt"])
    save(work, truth)


def up(sock, work):
    uid = str(uuid.uuid4())
    os.makedirs(os.path.join(work, "logs"), exist_ok=True)
    pod_file = path(work, "pod.json")
    json.dump({"metadata": {"name": "batch-0", "namespace": "default", "uid": uid, "attempt": 0}, "log_directory": os.path.join(work, "logs"),
               "labels": {"io.kubernetes.pod.name": "batch-0", "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": uid}, **NS},
              open(pod_file, "w"))
    sandbox = cri(sock, "runp", pod_file)
    open(path(work, "ids.txt"), "a").write(sandbox + "\n")
    truth = {"pod": {"id": sandbox, "uid": uid, "file": pod_file}, "containers": {}}
    save(work, truth)

    cid, web = create(sock, work, truth, "web", 0, messages("web", 0, 0, 8, True))
    wait_logs(work, web)
    web["files"] = snapshot(work, "web", 0)

    code = R.randint(3, 90)
    cid0, job0 = create(sock, work, truth, "job", 0, messages("job", 0, 0, 6, True))
    wait_logs(work, job0)
    rotate(sock, work, cid0, job0, False)
    time.sleep(1.2)                                     # the rotated files are told apart by their timestamp (to the second)
    add(work, job0, messages("job", 0, 6, 5, False))
    wait_logs(work, job0)
    rotate(sock, work, cid0, job0, True)
    add(work, job0, messages("job", 0, 11, 6, True), exit_code=code)
    finish(sock, work, truth, cid0, job0)

    cid1, job1 = create(sock, work, truth, "job", 1, messages("job", 1, 0, 8, True))
    wait_logs(work, job1)
    job1["files"] = snapshot(work, "job", 1)
    save(work, truth)
    print("pod default/batch-0: web (running), job attempt 0 (exited with %d, log in %d files), job attempt 1 (running)" % (code, len(job0["files"])))


def more(sock, work):
    truth = load(work)
    cid, rec = [(c, r) for c, r in truth["containers"].items() if r["name"] == "job" and r["attempt"] == 1][0]
    add(work, rec, messages("job", 1, 8, 4, False), exit_code=0)
    finish(sock, work, truth, cid, rec)
    print("job attempt 1 logged four more messages and exited with 0")


def keep(sock, work):
    truth = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    if cri(sock, "inspectp", "-o", "go-template", "--template", "{{.status.state}}", truth["pod"]["id"], check=False) != "SANDBOX_READY":
        bad("the pod is not ready any more")
    live = json.loads(cri(sock, "ps", "-a", "-o", "json"))["containers"]
    ids = {c["id"] for c in live}
    for cid, rec in truth["containers"].items():
        who = "%s (attempt %d)" % (rec["name"], rec["attempt"])
        if cid not in ids:
            bad("the container %s %s is gone" % (cid[:12], who))
        st = json.loads(cri(sock, "inspect", "-o", "json", cid))["status"]
        want = "CONTAINER_RUNNING" if rec["state"] == "running" else "CONTAINER_EXITED"
        if st["state"] != want or (rec["exit"] is not None and st["exitCode"] != rec["exit"]):
            bad("the container %s %s is %s, it should be %s" % (cid[:12], who, st["state"].replace("CONTAINER_", "").lower(), rec["state"]))
        if snapshot(work, rec["name"], rec["attempt"]) != rec["files"]:
            bad("the log files of %s changed (moved, truncated, removed or added)" % who)
    extra = ids - set(truth["containers"])
    if extra:
        bad("%d container(s) were added (%s)" % (len(extra), ", ".join(sorted(e[:12] for e in extra)[:3])))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "keep": keep}[cmd](sock, work)
