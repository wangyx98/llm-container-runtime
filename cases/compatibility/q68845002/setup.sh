#!/bin/bash
set -e

CASE_ID="bench68845002"
LIB="/var/lib/$CASE_ID"                          # the node: its containerd configuration and log, the launcher scripts, the workload files
RUN="/run/$CASE_ID"                              # the node's CRI socket, pid file, state and runc root
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"                     # the oracle's own record (root only)
CACHE="/var/cache/$CASE_ID"                      # downloaded JDKs and jars (kept between runs; checked against pinned sha256)
SOCK="$RUN/containerd.sock"
PAUSE_REF="$CASE_ID.local/pause:1"               # the sandbox image of the pods, built offline
OLD_REF="$CASE_ID.local/cache-app:jdk11.0.9"     # the workload image: the cache program on JDK 11.0.9
NEW_REF="$CASE_ID.local/cache-app:jdk11.0.13"    # the same program, same libraries, on JDK 11.0.13

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
CRICTL_VERSION="v1.34.0"
case "$(uname -m)" in
    x86_64|amd64)
        CRICTL_ARCH="amd64"; JARCH="x64"
        JDK9_URL="https://github.com/AdoptOpenJDK/openjdk11-binaries/releases/download/jdk-11.0.9%2B11/OpenJDK11U-jdk_x64_linux_hotspot_11.0.9_11.tar.gz"
        JDK9_SHA="fc8af86bc0cff91e1f96860d22a9611fdaa74a53d68f88ffb887d998593370a1"
        JDK13_URL="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.13%2B8/OpenJDK11U-jdk_x64_linux_hotspot_11.0.13_8.tar.gz"
        JDK13_SHA="3b1c0c34be4c894e64135a454f2d5aaa4bd10aea04ec2fa0c0efe6bb26528e30" ;;
    aarch64|arm64)
        CRICTL_ARCH="arm64"; JARCH="aarch64"
        JDK9_URL="https://github.com/AdoptOpenJDK/openjdk11-binaries/releases/download/jdk-11.0.9%2B11/OpenJDK11U-jdk_aarch64_linux_hotspot_11.0.9_11.tar.gz"
        JDK9_SHA="95e36ec2365a9fa00dac98521778e551cb542deacc3da653f0ed008c711e3a17"
        JDK13_URL="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.13%2B8/OpenJDK11U-jdk_aarch64_linux_hotspot_11.0.13_8.tar.gz"
        JDK13_SHA="a77013bff10a5e9c59159231dd5c4bd071fc4c24beed42bd49b82803ba9506ef" ;;
    *) echo "[setup] ERROR: unsupported architecture $(uname -m)"; exit 1 ;;
esac
EHCACHE_URL="https://repo1.maven.org/maven2/org/ehcache/ehcache/3.9.3/ehcache-3.9.3.jar"
EHCACHE_SHA="30f709462667c7f3c754c45be54034922523ea6cb9564be6ceaf73e9d959a634"
SLF4J_URL="https://repo1.maven.org/maven2/org/slf4j/slf4j-api/1.7.32/slf4j-api-1.7.32.jar"
SLF4J_SHA="3624f8474c1af46d75f98bc097d7864a323c81b3808aa43689a6e1c601c027be"

echo "[setup] checking the tools: containerd, ctr, runc, docker, python3, curl, tar, sudo..."
for c in containerd ctr runc docker dockerd python3 curl tar sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }
done
if ! command -v crictl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" \
        -o /tmp/crictl.tar.gz || { echo "[setup] ERROR: could not download crictl"; exit 1; }
    sudo tar zxf /tmp/crictl.tar.gz -C /usr/local/bin
    rm -f /tmp/crictl.tar.gz
fi
echo "  host: $(containerd --version | head -1)"
echo "  host: $(crictl --version | head -1), $(runc --version | head -1), $(docker --version | head -1), $(uname -m)"

# ---- the cgroup mode is part of the problem: JDK 11.0.9 reads the cgroup VERSION 1 files (memory.limit_in_bytes); on a cgroup v2 host these JDKs do not read container limits at all
echo "[setup] checking the cgroup mode (this case needs cgroup v1 with the memory controller)..."
if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ] || [ ! -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    echo "[setup] NOT APPLICABLE: this host uses cgroup v2 ($(stat -fc %T /sys/fs/cgroup 2>/dev/null)); the failure of the question exists only with cgroup v1 (JDK 11.0.9 to 11.0.12 parse /proc/self/cgroup of cgroup v1)."
    exit 1
fi

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be pulled from a public registry)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

echo "[setup] resetting the work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"

# ---- the JDKs and the jars: pinned versions, downloaded once into the cache and checked against sha256
echo "[setup] fetching JDK 11.0.9 and 11.0.13 ($JARCH) and Ehcache 3.9.3 (cache $CACHE)..."
sudo install -d -m 755 "$CACHE"
fetch() {  # file url sha
    local f="$CACHE/$1"
    if [ -s "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ]; then return 0; fi
    for _ in 1 2 3 4; do
        sudo rm -f "$f"
        sudo -E curl -fsSL --max-time 900 -o "$f" "$2" 2>/dev/null && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$3" ] && return 0
        sleep 5
    done
    echo "[setup] ERROR: could not fetch $2 with the pinned sha256"; exit 1
}
fetch "jdk-11.0.9-$JARCH.tar.gz" "$JDK9_URL" "$JDK9_SHA"
fetch "jdk-11.0.13-$JARCH.tar.gz" "$JDK13_URL" "$JDK13_SHA"
fetch "ehcache-3.9.3.jar" "$EHCACHE_URL" "$EHCACHE_SHA"
fetch "slf4j-api-1.7.32.jar" "$SLF4J_URL" "$SLF4J_SHA"

# ---- the cache program: the smallest complete use of Ehcache 3.9.3 that fails in the question: an off-heap resource of 50 MB, then put and get. It prints what the JVM knows
# about its memory (OperatingSystemMXBean, the container's own cgroup files, the JVM options) before it starts.
echo "[setup] building the cache program and two runtime images offline (jlink, docker archives)..."
mkdir -p "$WORK_DIR/b/src" "$WORK_DIR/b/classes"
cat > "$WORK_DIR/b/src/CacheInit.java" <<'JEOF'
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

import org.ehcache.Cache;
import org.ehcache.CacheManager;
import org.ehcache.config.builders.CacheConfigurationBuilder;
import org.ehcache.config.builders.CacheManagerBuilder;
import org.ehcache.config.builders.ResourcePoolsBuilder;
import org.ehcache.config.units.MemoryUnit;

public class CacheInit {
    static String first(String file, String needle) {
        try {
            for (String l : Files.readAllLines(Paths.get(file))) {
                if (l.contains(needle)) {
                    return l;
                }
            }
        } catch (IOException e) {
            return "unreadable";
        }
        return "none";
    }

    public static void main(String[] args) throws Exception {
        String nonce = System.getenv("NONCE");
        com.sun.management.OperatingSystemMXBean os = (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
        List<String> jvmArgs = ManagementFactory.getRuntimeMXBean().getInputArguments();
        System.out.println("probe java=" + System.getProperty("java.version") + " total=" + os.getTotalPhysicalMemorySize());
        System.out.println("probe jvm-args=" + jvmArgs + " JAVA_TOOL_OPTIONS=" + System.getenv("JAVA_TOOL_OPTIONS") + " JDK_JAVA_OPTIONS=" + System.getenv("JDK_JAVA_OPTIONS")
                + " _JAVA_OPTIONS=" + System.getenv("_JAVA_OPTIONS"));
        System.out.println("probe cgroup-memory=" + first("/proc/self/cgroup", ":memory:"));
        System.out.println("probe limit=" + first("/sys/fs/cgroup/memory/memory.limit_in_bytes", ""));
        try (CacheManager manager = CacheManagerBuilder.newCacheManagerBuilder()
                .withCache("records", CacheConfigurationBuilder.newCacheConfigurationBuilder(String.class, String.class,
                        ResourcePoolsBuilder.newResourcePoolsBuilder().offheap(50, MemoryUnit.MB)))
                .build(true)) {
            Cache<String, String> cache = manager.getCache("records", String.class, String.class);
            cache.put("nonce", nonce);
            for (int i = 0; i < 1000; i++) {
                cache.put("k" + i, "v" + i + "-" + nonce);
            }
            boolean ok = nonce != null && nonce.equals(cache.get("nonce")) && ("v999-" + nonce).equals(cache.get("k999"));
            System.out.println((ok ? "cache-ok" : "cache-wrong") + " nonce=" + cache.get("nonce"));
            System.exit(ok ? 0 : 3);
        } catch (Throwable t) {
            Throwable r = t;
            while (r.getCause() != null) {
                r = r.getCause();
            }
            System.out.println("cache-failed " + r.getClass().getName() + ": " + r.getMessage());
            System.exit(1);
        }
    }
}
JEOF
mkdir -p "$WORK_DIR/b/jdk9" "$WORK_DIR/b/jdk13"
tar xzf "$CACHE/jdk-11.0.9-$JARCH.tar.gz" -C "$WORK_DIR/b/jdk9" --strip-components=1
tar xzf "$CACHE/jdk-11.0.13-$JARCH.tar.gz" -C "$WORK_DIR/b/jdk13" --strip-components=1
"$WORK_DIR/b/jdk13/bin/javac" --release 8 -nowarn -cp "$CACHE/ehcache-3.9.3.jar:$CACHE/slf4j-api-1.7.32.jar" -d "$WORK_DIR/b/classes" "$WORK_DIR/b/src/CacheInit.java" 2>/dev/null \
    || { echo "[setup] ERROR: javac failed"; exit 1; }
"$WORK_DIR/b/jdk13/bin/jar" cf "$WORK_DIR/b/cacheinit.jar" -C "$WORK_DIR/b/classes" .
for v in 9 13; do
    "$WORK_DIR/b/jdk$v/bin/jlink" --add-modules java.base,java.management,jdk.management,jdk.unsupported,java.logging,java.xml --strip-debug --no-header-files --no-man-pages \
        --compress=2 --output "$WORK_DIR/b/rt$v" >/dev/null || { echo "[setup] ERROR: jlink failed"; exit 1; }
done
"$WORK_DIR/b/rt9/bin/java" -version 2>&1 | grep -q '11\.0\.9' || { echo "[setup] ERROR: the runtime of the old image is not JDK 11.0.9"; exit 1; }
"$WORK_DIR/b/rt13/bin/java" -version 2>&1 | grep -q '11\.0\.13' || { echo "[setup] ERROR: the runtime of the new image is not JDK 11.0.13"; exit 1; }

cat > "$WORK_DIR/b/idle.c" <<'CEOF'
#include <signal.h>
#include <unistd.h>

static void bye(int sig) { _exit(0); }

int main(void) {
    signal(SIGTERM, bye);
    signal(SIGINT, bye);
    for (;;) pause();
}
CEOF
gcc -static -Os -s -w -o "$WORK_DIR/b/idle" "$WORK_DIR/b/idle.c"
cat > "$WORK_DIR/b/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF KIND ARG... : a one-layer docker archive (docker save format).
   KIND pause PROGRAM          : PROGRAM as /pause, entrypoint /pause
   KIND java RT APPDIR CLASSJAR : the jlink runtime as /rt, the jars of APPDIR and CLASSJAR in /app, the shared libraries the runtime needs, entrypoint the cache program"""
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile

out, ref, kind = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
T = 1700000000


def sha(b):
    return hashlib.sha256(b).hexdigest()


def norm(ti):
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = T
    return ti


buf = io.BytesIO()
seen = set()


def adddir(t, d):
    if d in seen or d in ("", "."):
        return
    adddir(t, os.path.dirname(d))
    ti = tarfile.TarInfo(d)
    ti.type, ti.mode = tarfile.DIRTYPE, 0o755
    t.addfile(norm(ti))
    seen.add(d)


def addfile(t, name, src, mode):
    adddir(t, os.path.dirname(name))
    with open(src, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode = len(data), mode
    t.addfile(norm(ti), io.BytesIO(data))


with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    if kind == "pause":
        addfile(t, "pause", sys.argv[4], 0o755)
        config = {"Entrypoint": ["/pause"]}
    else:
        rt, appdir, classjar = sys.argv[4:7]
        libs = set()
        files = []
        for d, _, fs in os.walk(rt):
            for f in sorted(fs):
                p = os.path.join(d, f)
                files.append(p)
                if f == "java" or f.endswith(".so") or ".so." in f:
                    r = subprocess.run(["ldd", p], capture_output=True, text=True)
                    for line in r.stdout.splitlines():
                        m = re.match(r"\s*(?:\S+\s+=>\s+)?(/\S+)\s+\(0x", line)
                        if m and not m.group(1).startswith(os.path.abspath(rt)) and "vdso" not in m.group(1):
                            libs.add(m.group(1))
        for p in sorted(files):
            rel = "rt/" + os.path.relpath(p, rt)
            if os.path.islink(p):
                adddir(t, os.path.dirname(rel))
                ti = tarfile.TarInfo(rel)
                ti.type, ti.linkname = tarfile.SYMTYPE, os.readlink(p)
                t.addfile(norm(ti))
            else:
                addfile(t, rel, p, 0o755 if os.access(p, os.X_OK) else 0o644)
        for l in sorted(libs):
            addfile(t, l.lstrip("/"), os.path.realpath(l), 0o755)
        for j in ("ehcache-3.9.3.jar", "slf4j-api-1.7.32.jar"):
            addfile(t, "app/" + j, os.path.join(appdir, j), 0o644)
        addfile(t, "app/cacheinit.jar", classjar, 0o644)
        adddir(t, "tmp")
        config = {"Entrypoint": ["/rt/bin/java", "-cp", "/app/cacheinit.jar:/app/ehcache-3.9.3.jar:/app/slf4j-api-1.7.32.jar", "CacheInit"],
                  "Env": ["PATH=/rt/bin:/usr/bin:/bin"]}
layer = buf.getvalue()
cfg = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": config,
                  "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(cfg) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(cfg) + ".json", cfg), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), T
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$WORK_DIR/b/mkarchive.py" "$STATE_DIR/pause.tar" "$PAUSE_REF" pause "$WORK_DIR/b/idle"
python3 "$WORK_DIR/b/mkarchive.py" "$STATE_DIR/old.tar" "$OLD_REF" java "$WORK_DIR/b/rt9" "$CACHE" "$WORK_DIR/b/cacheinit.jar"
python3 "$WORK_DIR/b/mkarchive.py" "$STATE_DIR/new.tar" "$NEW_REF" java "$WORK_DIR/b/rt13" "$CACHE" "$WORK_DIR/b/cacheinit.jar"
rm -rf "$WORK_DIR/b"

# ---- the node: containerd with the CRI plugin, configured like the one of a Kubernetes node whose kubelet uses the systemd cgroup driver but whose runc runs on cgroupfs
# (SystemdCgroup = false, the stock default); a launcher (nodectl) and the workload applied the way a kubelet would (run-workload)
echo "[setup] the node's containerd configuration (CRI plugin on, runc on cgroupfs, local sandbox image)..."
sudo install -d -m 755 "$LIB/bin" "$LIB/node" "$LIB/workload" "$RUN"
containerd config default | python3 -c '
import re
import sys

pause, lib, run = sys.argv[1:4]
section = ""
runc_options = False
sys.stdout.write("# containerd of the node: the stock default configuration of the installed version, the node directories, a local sandbox image\n")
for line in sys.stdin:
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("\x27\"")
        runc_options = section.endswith(".runtimes.runc.options")
    key = re.match(r"^\s*([A-Za-z_]+)\s*=", line)
    k = key.group(1) if key else None
    indent = re.match(r"^\s*", line).group(0)
    if section == "" and k == "root":
        line = indent + "root = \x27" + lib + "/node/containerd\x27\n"
    elif section == "" and k == "state":
        line = indent + "state = \x27" + run + "/containerd\x27\n"
    elif section == "" and k == "imports":
        line = indent + "imports = []\n"
    elif "nri" in section and k == "disable":
        line = indent + "disable = true\n"
    elif k == "restrict_oom_score_adj":
        line = indent + "restrict_oom_score_adj = true\n"
    elif section.endswith(".cni") and k == "bin_dirs":
        line = indent + "bin_dirs = [\x27" + lib + "/node/cni/bin\x27]\n"
    elif section.endswith(".cni") and k == "bin_dir" and not re.search(r"=\s*(\x27\x27|\"\")\s*$", line):
        line = indent + "bin_dir = \x27" + lib + "/node/cni/bin\x27\n"
    elif section.endswith(".cni") and k == "conf_dir":
        line = indent + "conf_dir = \x27" + lib + "/node/cni/net.d\x27\n"
    elif "pinned_images" in section and k == "sandbox":
        line = indent + "sandbox = \x27" + pause + "\x27\n"
    elif k == "sandbox_image":
        line = indent + "sandbox_image = \x27" + pause + "\x27\n"
    elif runc_options and k == "SystemdCgroup":
        line = indent + "SystemdCgroup = false\n"
    elif runc_options and k == "Root":
        line = indent + "Root = \x27" + run + "/runc\x27\n"
    sys.stdout.write(line)
' "$PAUSE_REF" "$LIB" "$RUN" > "$WORK_DIR/containerd.toml"
grep -q "$PAUSE_REF" "$WORK_DIR/containerd.toml" || { echo "[setup] ERROR: could not set the sandbox image in the configuration"; exit 1; }
grep -q "SystemdCgroup = false" "$WORK_DIR/containerd.toml" || { echo "[setup] ERROR: the default configuration of this containerd has no SystemdCgroup setting to fix"; exit 1; }
sudo install -m 644 "$WORK_DIR/containerd.toml" "$LIB/node/containerd.toml"
rm -f "$WORK_DIR/containerd.toml"
printf 'runtime-endpoint: unix://%s\nimage-endpoint: unix://%s\ntimeout: 30\n' "$SOCK" "$SOCK" | sudo tee "$LIB/node/crictl.yaml" >/dev/null

echo "[setup] the node's scripts (cachenodectl, run-workload) and the workload files..."
cat <<'CEOF' | sudo tee "$LIB/bin/cachenodectl" >/dev/null
#!/bin/bash
# cachenodectl start|stop|restart|status : starts and stops the node's containerd (the container runtime of a one-node Kubernetes-style setup), which reads
# /var/lib/bench68845002/node/containerd.toml at its start. `status` shows the node and the CRI version. Must run as root.
LIB=/var/lib/bench68845002
RUN=/run/bench68845002
PIDF="$RUN/containerd.pid"
SOCK="$RUN/containerd.sock"
LOG="$LIB/node/containerd.log"

[ "$(id -u)" = 0 ] || { echo "cachenodectl: must run as root (use sudo)" >&2; exit 1; }

pid() { [ -s "$PIDF" ] && cat "$PIDF"; }
running() { local p; p=$(pid) && [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = containerd ]; }
up() { [ -S "$SOCK" ] && timeout 3 ctr -a "$SOCK" version >/dev/null 2>&1; }

start() {
    if running; then echo "cachenodectl: containerd is already running (pid $(pid))"; return 0; fi
    mkdir -p "$RUN" "$LIB/node/containerd" "$LIB/node/logs" "$LIB/node/cni/bin" "$LIB/node/cni/net.d"
    setsid -f sh -c 'echo $$ > /run/bench68845002/containerd.pid; exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin containerd --config /var/lib/bench68845002/node/containerd.toml --address /run/bench68845002/containerd.sock' >> "$LOG" 2>&1 < /dev/null
    for _ in $(seq 60); do up && { echo "cachenodectl: containerd started (pid $(pid))"; return 0; }; sleep 0.5; done
    echo "cachenodectl: containerd did not answer on $SOCK within 30 s; see $LOG" >&2
    return 1
}

stop() {
    local p
    p=$(pid) || true
    if [ -n "$p" ] && running; then
        kill -TERM "$p" 2>/dev/null
        for _ in $(seq 60); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    fi
    rm -f "$PIDF" "$SOCK" "$SOCK.ttrpc"
    echo "cachenodectl: containerd stopped"
}

status() {
    local out
    if running; then echo "containerd: running (pid $(pid))"; else echo "containerd: not running"; return 1; fi
    if out=$(timeout 30 crictl --config "$LIB/node/crictl.yaml" version 2>&1); then
        echo "CRI: $(echo "$out" | grep -E '^(RuntimeName|RuntimeVersion)' | awk '{print $2}' | paste -sd' ')"
    else
        echo "CRI: not answering: $(echo "$out" | tail -1 | cut -c1-200)"; return 1
    fi
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    *) echo "usage: cachenodectl start|stop|restart|status" >&2; exit 2 ;;
esac
CEOF
cat <<'CEOF' | sudo tee "$LIB/bin/run-workload" >/dev/null
#!/bin/bash
# run-workload NONCE [DIR] : applies the workload the way a kubelet does through the CRI of the node: a pod sandbox from DIR/pod.json (default
# /var/lib/bench68845002/workload), a container from DIR/container.json with the text __NONCE__ replaced by NONCE, waits for the container to end, prints its log and the exit
# code, and removes the pod. The exit code of the script is the exit code of the container. Must run as root.
LIB=/var/lib/bench68845002
SOCK=/run/bench68845002/containerd.sock
NONCE="${1:?usage: run-workload NONCE [DIR]}"
DIR="${2:-$LIB/workload}"
CR="crictl --config $LIB/node/crictl.yaml --timeout 60s"

[ "$(id -u)" = 0 ] || { echo "run-workload: must run as root (use sudo)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$DIR/pod.json" "$tmp/pod.json"
sed "s/__NONCE__/$NONCE/g" "$DIR/container.json" > "$tmp/container.json"
mkdir -p "$LIB/node/logs"
pod=$($CR runp "$tmp/pod.json") || { echo "run-workload: the pod sandbox did not start" >&2; exit 125; }
ctr=$($CR create "$pod" "$tmp/container.json" "$tmp/pod.json") || { echo "run-workload: the container was not created" >&2; $CR stopp "$pod" >/dev/null 2>&1; $CR rmp "$pod" >/dev/null 2>&1; exit 125; }
logfile=$($CR inspect -o go-template --template '{{.status.logPath}}' "$ctr" 2>/dev/null)
[ -n "$logfile" ] && : > "$logfile"
$CR start "$ctr" >/dev/null || { echo "run-workload: the container did not start" >&2; $CR stopp "$pod" >/dev/null 2>&1; $CR rmp "$pod" >/dev/null 2>&1; exit 125; }
state=""
for _ in $(seq 240); do
    state=$($CR inspect -o go-template --template '{{.status.state}}' "$ctr" 2>/dev/null)
    [ "$state" = CONTAINER_EXITED ] && break
    sleep 0.5
done
code=$($CR inspect -o go-template --template '{{.status.exitCode}}' "$ctr" 2>/dev/null)
$CR logs "$ctr" 2>&1
echo "workload exit code: ${code:-unknown}"
$CR stopp "$pod" >/dev/null 2>&1
$CR rmp "$pod" >/dev/null 2>&1
[ "$state" = CONTAINER_EXITED ] && exit "${code:-1}"
exit 124
CEOF
sudo chmod 755 "$LIB/bin/cachenodectl" "$LIB/bin/run-workload"
cat <<CEOF | sudo tee "$LIB/workload/pod.json" >/dev/null
{
  "metadata": {"name": "cache-0", "namespace": "default", "uid": "6bd1d7f1-9a2c-4a0e-8b3f-c4a1e2d3b5a6", "attempt": 1},
  "log_directory": "$LIB/node/logs",
  "linux": {
    "cgroup_parent": "kubepods-burstable-pod6bd1d7f1_9a2c_4a0e_8b3f_c4a1e2d3b5a6.slice",
    "security_context": {"namespace_options": {"network": 2}}
  }
}
CEOF
cat <<CEOF | sudo tee "$LIB/workload/container.json" >/dev/null
{
  "metadata": {"name": "cache"},
  "image": {"image": "$OLD_REF"},
  "envs": [{"key": "NONCE", "value": "__NONCE__"}],
  "log_path": "cache.log",
  "linux": {"resources": {"memory_limit_in_bytes": 536870912}}
}
CEOF

echo "[setup] starting the node and importing the images (offline, namespace k8s.io)..."
sudo "$LIB/bin/cachenodectl" start || { echo "[setup] ERROR: the node did not start"; sudo tail -8 "$LIB/node/containerd.log" 2>/dev/null; exit 1; }
for t in pause old new; do
    sudo ctr -a "$SOCK" -n k8s.io images import "$STATE_DIR/$t.tar" >/dev/null 2>&1 || { echo "[setup] ERROR: could not import the $t image"; exit 1; }
done
echo "  -> $(sudo ctr -a "$SOCK" -n k8s.io images ls -q | grep -v '^sha256:' | tr '\n' ' ')"

echo "[setup] the workload as the engineer first runs it (what the engineer sees)..."
if sudo "$LIB/bin/run-workload" "first-$(python3 -c 'import secrets; print(secrets.token_hex(4))')" >"$STATE_DIR/first.out" 2>&1; then
    echo "[setup] ERROR: the workload works: the failure of the question did not appear"; cat "$STATE_DIR/first.out"; exit 1
fi
cat "$STATE_DIR/first.out"
grep -q "of physical memory" "$STATE_DIR/first.out" \
    || { echo "[setup] ERROR: the workload failed, but not with 'host only contains 0B of physical memory'"; exit 1; }

echo "[setup] recording what is true now (hashes of the node's scripts, the image ids, the original workload files)..."
( cd "$LIB" && sudo sha256sum bin/cachenodectl bin/run-workload ) | sudo tee "$STATE_DIR/files.sha" >/dev/null
sudo cp "$LIB/workload/pod.json" "$STATE_DIR/pod.orig"
sudo cp "$LIB/workload/container.json" "$STATE_DIR/container.orig"
sudo cp "$LIB/node/containerd.toml" "$STATE_DIR/containerd.orig"
for t in OLD NEW; do
    ref="$([ $t = OLD ] && echo "$OLD_REF" || echo "$NEW_REF")"
    id="$(sudo crictl --config "$LIB/node/crictl.yaml" inspecti -o go-template --template '{{.status.id}}' "$ref")"
    printf '%s %s\n' "$t" "$id" | sudo tee -a "$STATE_DIR/images.id" >/dev/null
done
sudo rm -f "$STATE_DIR/first.out" "$STATE_DIR/pause.tar"
sudo chown -R root:root "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

echo "[setup] done. The node (CRI socket $SOCK) is up, and the workload fails with 'host only contains 0B of physical memory'."
