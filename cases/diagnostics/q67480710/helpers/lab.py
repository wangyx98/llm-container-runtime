"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the real CRI workloads of the case, what they log, and the check that the runtime's log
files and the symlinks to them are as the lab left them.

up:    one pod sandbox web-0 of the namespace default, with its log directory in the kubelet layout, WORK/var/log/pods/default_web-0_UID, and two
       containers of the image bench67480710.local/app:1 that run for ever: "app" (log file app/0.log) and "sidecar" (sidecar/0.log). Each is told,
       through a file of its own (WORK/data/NAME/script.txt, mounted at /data), to log lines, one write per line, on stdout or on stderr (app: about
       two lines in five on stderr; sidecar: about one in five). The lines have a marker (NAME-SEQ-HEX) first and then a random text of a kind that
       has to survive collection byte for byte: indented, with a tab, with unicode, a JSON text, quotes and backslashes, trailing spaces. Like the
       kubelet, the lab makes a symlink for each container, WORK/var/log/containers/web-0_default_NAME-CID.log, to its log file. The lines of
       each container are recorded (WORK/.bench/NAME.lines.json: [stream, text]). Returns when the log files hold them all.
more:  a second batch of lines for both containers (the applications log on while the collector runs); returns when the log files hold them.
check: fails (one short line) unless every symlink still points to the log file of its container, the file is the regular file the runtime writes,
       and holds, in CRI format (TIMESTAMP STREAM F|P TEXT per line), exactly the recorded lines in the recorded order."""
import json
import os
import random
import re
import subprocess
import sys
import time
import uuid

APP_REF = "bench67480710.local/app:1"
NAMES = ("app", "sidecar")
STDERR_SHARE = {"app": 0.4, "sidecar": 0.2}
POD, NAMESPACE = "web-0", "default"
NS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER
R = random.SystemRandom()
CRI_LINE = re.compile(rb"^\d{4}-\d\d-\d\dT[\d:.]+(?:Z|[+-]\d\d:\d\d) (stdout|stderr) ([FP]) (.*)$", re.S)


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout.strip()


def hexs(n):
    return "".join(R.choices("0123456789abcdef", k=n))


def bench(work, *parts):
    return os.path.join(work, ".bench", *parts)


def body():
    kind = R.randrange(9)
    n = R.randint(100, 9999)
    if kind == 0:
        return "GET /orders/%d HTTP/1.1 200 %dms" % (n, R.randint(1, 900))
    if kind == 1:
        return "    at com.pkg.shop.OrderService.accept(OrderService.java:%d)" % R.randint(10, 900)
    if kind == 2:
        return "\tstep\t%d\tfinished\t%s" % (n, hexs(4))
    if kind == 3:
        return "ünïcödé ✓ café 日本語 %s" % hexs(6)
    if kind == 4:
        return '{"level":"info","msg":"order %d accepted","trace":"%s"}' % (n, hexs(10))
    if kind == 5:
        return 'path C:\\temp\\x "quoted" and \'single\' %s' % hexs(5)
    if kind == 6:
        return "done %d  " % n                      # two spaces at the end
    if kind == 7:
        return " ".join("k%d=%s" % (i, hexs(6)) for i in range(R.randint(20, 40)))
    return "cache refreshed in %d ms (%s)" % (R.randint(1, 500), hexs(4))


def make_lines(name, first, count):
    """the next lines of a container: [stream, text] with stream stdout or stderr; the very first batch has both streams for sure"""
    out = []
    for i in range(first, first + count):
        stream = "stderr" if R.random() < STDERR_SHARE[name] else "stdout"
        if i == 0:
            stream = "stdout"
        if i == 1:
            stream = "stderr"
        out.append([stream, "%s-%04d-%s %s" % (name, i, hexs(8), body())])
    return out


def lines_of(work, name):
    p = bench(work, name + ".lines.json")
    return json.load(open(p)) if os.path.exists(p) else []


def add(work, name, new):
    json.dump(lines_of(work, name) + new, open(bench(work, name + ".lines.json"), "w"))
    d = os.path.join(work, "data", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "script.txt"), "ab") as f:
        for stream, text in new:
            f.write(("o " if stream == "stdout" else "e ").encode() + text.encode() + b"\ns %d\n" % R.randint(1, 20))


def parse_cri(raw):
    """[(stream, text)] of a CRI log file; None for the first line that is not a CRI record (second item: that line)"""
    out = []
    for line in raw.split(b"\n"):
        if not line:
            continue
        m = CRI_LINE.match(line)
        if not m:
            return None, line
        out.append((m.group(1).decode(), m.group(3).decode()))
    return out, None


def log_file(work, name):
    t = json.load(open(bench(work, "truth.json")))
    return t["containers"][name]["target"]


def wait_logs(work):
    for name in NAMES:
        want = [tuple(x) for x in lines_of(work, name)]
        got = []
        for _ in range(400):
            raw = subprocess.run(["sudo", "cat", log_file(work, name)], capture_output=True).stdout
            got, _bad = parse_cri(raw)
            if got == want:
                break
            time.sleep(0.3)
        else:
            sys.stderr.write("the log of %s did not get all the lines in 120 s (%d of %d)\n" % (name, len(got or []), len(want)))
            sys.exit(1)


def up(sock, work):
    uid = str(uuid.uuid4())
    podlog = os.path.join(work, "var", "log", "pods", "%s_%s_%s" % (NAMESPACE, POD, uid))
    containers = os.path.join(work, "var", "log", "containers")
    os.makedirs(podlog, exist_ok=True)
    os.makedirs(containers, exist_ok=True)
    pod_file = bench(work, "pod.json")
    json.dump({"metadata": {"name": POD, "namespace": NAMESPACE, "uid": uid, "attempt": 0}, "log_directory": podlog, **NS}, open(pod_file, "w"))
    ids = bench(work, "ids.txt")
    sandbox = cri(sock, "runp", pod_file)
    open(ids, "a").write(sandbox + "\n")
    truth = {"pod": POD, "namespace": NAMESPACE, "uid": uid, "containers": {}}
    for name in NAMES:
        os.makedirs(os.path.join(podlog, name), exist_ok=True)
        add(work, name, make_lines(name, 0, R.randint(12, 16)))
        cfg = {"metadata": {"name": name, "attempt": 0}, "image": {"image": APP_REF}, "args": ["serve", "/data/script.txt"],
               "mounts": [{"container_path": "/data", "host_path": os.path.join(work, "data", name), "readonly": True}],
               "log_path": "%s/0.log" % name, **NS}
        cfile = bench(work, name + ".json")
        json.dump(cfg, open(cfile, "w"))
        cid = cri(sock, "create", sandbox, cfile, pod_file)
        open(ids, "a").write(cid + "\n")
        target = os.path.join(podlog, name, "0.log")
        link = os.path.join(containers, "%s_%s_%s-%s.log" % (POD, NAMESPACE, name, cid))
        os.symlink(target, link)                       # the kubelet makes this link
        truth["containers"][name] = {"cid": cid, "link": link, "target": target}
        json.dump(truth, open(bench(work, "truth.json"), "w"), indent=1)
        cri(sock, "start", cid)
    wait_logs(work)
    for name in NAMES:
        ls = lines_of(work, name)
        print("%s: %d lines (%d on stderr)" % (name, len(ls), sum(1 for s, _ in ls if s == "stderr")))


def more(sock, work):
    for name in NAMES:
        add(work, name, make_lines(name, len(lines_of(work, name)), R.randint(8, 12)))
    wait_logs(work)


def check(sock, work):
    t = json.load(open(bench(work, "truth.json")))

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    for name, c in t["containers"].items():
        link, target = c["link"], c["target"]
        if not os.path.islink(link):
            bad("%s is not a symlink any more" % os.path.basename(link)[:90])
        if os.readlink(link) != target:
            bad("the symlink of %s points to %s, not to its CRI log file" % (name, os.readlink(link)))
        if os.path.islink(target) or not os.path.isfile(target):
            bad("the CRI log file of %s is not a regular file any more" % name)
        raw = subprocess.run(["sudo", "cat", target], capture_output=True).stdout
        got, line = parse_cri(raw)
        if got is None:
            bad("the log file of %s is no longer in the CRI format the runtime writes: %s" % (name, line.decode(errors="replace")[:100]))
        if got != [tuple(x) for x in lines_of(work, name)]:
            bad("the log file of %s does not hold what the application logged (%d records, %d lines were logged)" % (name, len(got), len(lines_of(work, name))))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
