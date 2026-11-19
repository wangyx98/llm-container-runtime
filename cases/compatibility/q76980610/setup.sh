#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

CASE_ID="bench76980610"
LIB_BASE="/var/lib/$CASE_ID"             # the node: its boot script, pid, containerd and docker data, the test classes
CACHE="/var/cache/$CASE_ID"              # the pinned Testcontainers jars (kept by cleanup, checked by sha256 at every setup)
WORK_DIR="/tmp/$CASE_ID"                 # what the agent's job has: the two wrappers, the HOME of the job, the image tar
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
IMAGE="$CASE_ID-app:latest"
SB="3.1.2"; SF="6.0.11"; MM="1.11.2"   # Spring Boot / Spring Framework / Micrometer of the Boot 3.1 line (the question is from 2023)
TC="1.21.4"; DJ="3.4.2"                  # Testcontainers and docker-java (Docker 29 needs a client that speaks API >= 1.44; Docker 27 works as well)
R="https://repo1.maven.org/maven2"
# jar | path below the repository | sha256
JARS=(
"testcontainers-$TC.jar|org/testcontainers/testcontainers/$TC|ea81a9ca337bbae7ee83f372b92d55140c7ab976bce73ff1b79f2dd151ca9610"
"junit-jupiter-$TC.jar|org/testcontainers/junit-jupiter/$TC|92df2a6fd67c30acb5b3521118558033f711c7973fab5f4597211ff3fd13f416"
"docker-java-api-$DJ.jar|com/github/docker-java/docker-java-api/$DJ|6789d68f95904cf274a6410fdfcc5530976bc94197c856909459bb8c64db557b"
"docker-java-transport-$DJ.jar|com/github/docker-java/docker-java-transport/$DJ|bc9981224fdc2d4726566fc723470601ceb14378265c865b4c203146a4e39765"
"docker-java-transport-zerodep-$DJ.jar|com/github/docker-java/docker-java-transport-zerodep/$DJ|582b772e0c52fa9d24710617ef610655465edd9a2930b0db75fc8667d6a8d02b"
"jna-5.13.0.jar|net/java/dev/jna/jna/5.13.0|66d4f819a062a51a1d5627bffc23fac55d1677f0e0a1feba144aabdd670a64bb"
"slf4j-api-1.7.36.jar|org/slf4j/slf4j-api/1.7.36|d3ef575e3e4979678dc01bf1dcce51021493b4d11fb7f1be8ad982877c16a1c0"
"slf4j-simple-1.7.36.jar|org/slf4j/slf4j-simple/1.7.36|2f39bed943d624dfa8f4102d0571283a10870b6aa36f197a8a506f147010c10f"
"commons-compress-1.24.0.jar|org/apache/commons/commons-compress/1.24.0|fbf2c5d275e513c08f4e4fb539726dbf3ac2142af956ba93efb983244f0c36bd"
"duct-tape-1.0.8.jar|org/rnorth/duct-tape/duct-tape/1.0.8|31cef12ddec979d1f86d7cf708c41a17da523d05c685fd6642e9d0b2addb7240"
"junit-4.13.2.jar|junit/junit/4.13.2|8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3"
"hamcrest-core-1.3.jar|org/hamcrest/hamcrest-core/1.3|66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9"
"jackson-annotations-2.10.3.jar|com/fasterxml/jackson/core/jackson-annotations/2.10.3|49dfdc4cfa46d165ecfed630ba164b6641d59d5fe1aa698a19c13f966d3f13cf"
"spring-boot-$SB.jar|org/springframework/boot/spring-boot/$SB|2ed02943690b67c5f2e8cc2c1d04c6179a1ad2678412790bb38192db88c46dd7"
"spring-boot-autoconfigure-$SB.jar|org/springframework/boot/spring-boot-autoconfigure/$SB|acf08aa3d1e56034a2feb1e27ddf639356bd97787ef2a79709ccebdef85589b0"
"spring-boot-test-$SB.jar|org/springframework/boot/spring-boot-test/$SB|6e30c107564e51f4741ab83cea6090f994c7c7f3e7289a4afc5d545d581151e4"
"spring-boot-test-autoconfigure-$SB.jar|org/springframework/boot/spring-boot-test-autoconfigure/$SB|791c82c4e1aaefbbed7301093fad1d7ae5cd89acf945b9268c0e6961573d5d1f"
"spring-core-$SF.jar|org/springframework/spring-core/$SF|e94db32567f3dad3274bdb26e1e187f321f5358c50d1a1c59482999e18110361"
"spring-jcl-$SF.jar|org/springframework/spring-jcl/$SF|3e987e148631a0f0be0cd2d032bf6c7411f2440f20a684fdd93b2151477e7c95"
"spring-beans-$SF.jar|org/springframework/spring-beans/$SF|5b93de3bf3ff04e5753ff0bd872f0722a575b4b8d191be14685376ef8cb44ae5"
"spring-context-$SF.jar|org/springframework/spring-context/$SF|d4d95c6869859a4bd1d53e78707287d66e8e66c9e71a8f65ecd258a68000d34d"
"spring-aop-$SF.jar|org/springframework/spring-aop/$SF|a4199b50d28124ce528f8b61e43f9830d02959ead711f9859954db16ddce629a"
"spring-expression-$SF.jar|org/springframework/spring-expression/$SF|23126f4e3fe0115163b4ac97de7dab298cdd7ba698cb18cac9a198b5a309b29f"
"spring-test-$SF.jar|org/springframework/spring-test/$SF|810925d7d3af3ed550c9267ea506f14382ddb0b53fec4ec6ba4a9f17f167fdd1"
"micrometer-observation-$MM.jar|io/micrometer/micrometer-observation/$MM|f62d3e30f3eacef9c2ec5259d9501b7cf6afd04648e28d4253aa53f24d418baa"
"micrometer-commons-$MM.jar|io/micrometer/micrometer-commons/$MM|66fff94b03b3cfa1706689aeddf51c285f76b3113cfbf82487a7a59d123938c8"
"junit-platform-console-standalone-1.9.3.jar|org/junit/platform/junit-platform-console-standalone/1.9.3|45e90d893561d813a64559554647eea5e74acaa9c8cb1fed1340d192f34689e2"
)

case "$(uname -m)" in
    x86_64|amd64)  IMG_ARCH="amd64" ;;
    aarch64|arm64) IMG_ARCH="arm64" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m)"; exit 1 ;;
esac

echo "[setup] checking what the case needs is installed (dockerd, containerd, ctr and runc of this host are the stack under test)..."
for c in dockerd containerd ctr runc python3 curl sudo unshare nsenter sha256sum; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
DOCKERD_BIN=$(command -v dockerd); CONTAINERD_BIN=$(command -v containerd); CTR_BIN=$(command -v ctr)
echo "  dockerd: $("$DOCKERD_BIN" --version | head -1)"; "$CONTAINERD_BIN" --version | head -1; runc --version | head -1

echo "[setup] ensuring a JDK 17 or newer (Spring Framework 6 needs it) and gcc (one static program for the image) exist..."
find_jdk() {   # prints "JAVA JAVAC" of the first JDK >= 17
    local j
    for j in "$(command -v javac 2>/dev/null)" /usr/lib/jvm/*/bin/javac; do
        [ -x "$j" ] || continue
        [ "$(env -u JAVA_TOOL_OPTIONS "$j" -version 2>&1 | awk '{split($2, v, "."); print v[1]; exit}')" -ge 17 ] 2>/dev/null && [ -x "$(dirname "$(readlink -f "$j")")/java" ] && { echo "$(dirname "$(readlink -f "$j")")/java $(readlink -f "$j")"; return 0; }
    done
    return 1
}
if ! find_jdk >/dev/null; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" openjdk-17-jdk-headless
fi
read -r JAVA_BIN JAVAC_BIN < <(find_jdk) || { echo "[setup] ERROR: no JDK 17+"; exit 1; }
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi
env -u JAVA_TOOL_OPTIONS "$JAVA_BIN" -version 2>&1 | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] the Testcontainers $TC jars: from $CACHE, else downloaded from Maven Central; the sha256 is checked either way..."
sudo install -d -m 0755 "$CACHE"
for j in "${JARS[@]}"; do
    IFS='|' read -r name path sha <<< "$j"
    if sudo test -f "$CACHE/$name" && echo "$sha  $CACHE/$name" | sudo sha256sum -c --quiet - 2>/dev/null; then continue; fi
    ok=""
    for _ in 1 2 3 4; do
        tmp=$(mktemp)
        if curl -fsSL --max-time 180 -o "$tmp" "$R/$path/$name" && echo "$sha  $tmp" | sha256sum -c --quiet - 2>/dev/null; then sudo install -m 0644 "$tmp" "$CACHE/$name"; ok=1; rm -f "$tmp"; break; fi
        rm -f "$tmp"; sleep 3
    done
    [ -n "$ok" ] || { echo "[setup] ERROR: could not download $name from Maven Central with the pinned sha256"; exit 1; }
done
CP_JARS=$(for j in "${JARS[@]}"; do case "${j%%|*}" in junit-platform-console-standalone*) ;; *) echo -n "$LIB_BASE/jars/${j%%|*}:" ;; esac; done)
CONSOLE="$LIB_BASE/jars/junit-platform-console-standalone-1.9.3.jar"

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/jars" "$LIB_BASE/probe" "$LIB_BASE/node" "$LIB_BASE/lib/containerd" "$LIB_BASE/lib/docker"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/home"
sudo install -d -m 0700 "$STATE_DIR"
for j in "${JARS[@]}"; do sudo install -m 0644 "$CACHE/${j%%|*}" "$LIB_BASE/jars/"; done
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "[setup] the test of the agent's job (a fixed Spring Boot test standing for the suite of the question: @SpringBootTest + @Testcontainers; it asks Testcontainers for the Docker client, loads the image, starts a container with a fresh nonce through the Docker API, waits for the nonce in its log, optionally waits for a file, reads the log, removes the container)..."
mkdir -p "$BUILD/src/bench" "$BUILD/classes"
cat > "$BUILD/src/bench/App.java" <<'JEOF'
package bench;
import org.springframework.boot.autoconfigure.SpringBootApplication;
@SpringBootApplication
public class App { }
JEOF
cat > "$BUILD/src/bench/AppContainerTest.java" <<'JEOF'
package bench;

import com.github.dockerjava.api.DockerClient;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Testcontainers;

@SpringBootTest(classes = App.class, properties = "bench.nonce=${random.uuid}")
@Testcontainers
class AppContainerTest {
    static GenericContainer<?> app;
    static String nonce = UUID.randomUUID().toString().replace("-", "");
    @Value("${bench.nonce}") String contextNonce;

    @BeforeAll
    static void startApplicationContainer() throws Exception {
        DockerClient client = DockerClientFactory.instance().client();
        System.out.println("DOCKER server=" + client.infoCmd().exec().getServerVersion());
        try (FileInputStream in = new FileInputStream(System.getProperty("bench.tar"))) { client.loadImageCmd(in).exec(); }
        app = new GenericContainer<>(System.getProperty("bench.image")).withEnv("NONCE", nonce).withNetworkMode("none")
                .waitingFor(Wait.forLogMessage(".*bench76980610-ready nonce=" + nonce + ".*\\n", 1));
        app.start();
        System.out.println("STARTED nonce=" + nonce + " id=" + app.getContainerId());
        System.out.flush();
        String hold = System.getProperty("bench.hold");
        if (hold != null) { for (int i = 0; i < 240 && !Files.exists(Paths.get(hold)); i++) Thread.sleep(500); }
    }

    @AfterAll
    static void stopApplicationContainer() { if (app != null) app.stop(); }

    @Test
    void containerLogCarriesTheNonce() {
        org.junit.jupiter.api.Assertions.assertNotNull(contextNonce);
        System.out.println("SPRING ctx=" + contextNonce);
        org.junit.jupiter.api.Assertions.assertTrue(app.getLogs().contains("nonce=" + nonce), "the log of the container lacks the nonce");
        System.out.println("LOG " + app.getLogs().trim());
    }
}
JEOF
env -u JAVA_TOOL_OPTIONS "$JAVAC_BIN" --release 17 -parameters -cp "${CP_JARS//$LIB_BASE\/jars/$CACHE}$CACHE/junit-platform-console-standalone-1.9.3.jar" -d "$BUILD/classes" "$BUILD"/src/bench/*.java 2>&1 | grep -v "^Picked up" || true
[ -f "$BUILD/classes/bench/AppContainerTest.class" ] || { echo "[setup] ERROR: the test did not compile"; exit 1; }
sudo cp -r "$BUILD/classes/." "$LIB_BASE/probe/" && sudo chmod -R a+rX "$LIB_BASE/probe"

echo "[setup] the Docker engine proxy of the node (a stand-in for the docker.sock of a desktop Docker: it forwards /run/docker.sock to /run/docker.raw.sock; while nothing accepts connections there it answers HTTP 502 'Bad response from Docker engine')..."
cat > "$BUILD/engine-proxy.py" <<'XPYEOF'
#!/usr/bin/env python3
# engine-proxy.py LISTEN UPSTREAM: forwards every connection byte for byte to UPSTREAM; answers HTTP 502 while UPSTREAM does not accept connections
import os, socket, sys, threading

LISTEN, UPSTREAM = sys.argv[1], sys.argv[2]
BODY = b"Bad response from Docker engine"
REPLY = (b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(BODY)) + BODY


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(c):
    up = None
    try:
        try:
            up = socket.socket(socket.AF_UNIX)
            up.connect(UPSTREAM)
        except OSError:
            if up:
                up.close()
            up = None
        if up is None:
            c.recv(65536)
            c.sendall(REPLY)
            return
        t = threading.Thread(target=pipe, args=(up, c), daemon=True)
        t.start()
        pipe(c, up)
        t.join()
    finally:
        for x in (c, up):
            try:
                if x:
                    x.close()
            except OSError:
                pass


if os.path.exists(LISTEN):
    os.unlink(LISTEN)
srv = socket.socket(socket.AF_UNIX)
srv.bind(LISTEN)
os.chmod(LISTEN, 0o660)
srv.listen(64)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
XPYEOF
sudo install -m 0755 "$BUILD/engine-proxy.py" "$LIB_BASE/node/engine-proxy.py"

echo "[setup] the application image: one static program that prints 'bench76980610-ready nonce=\$NONCE' and waits; a docker archive, nothing is pulled..."
cat > "$BUILD/app.c" <<'CEOF'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void bye(int sig) { (void)sig; _exit(0); }
int main(void) {
    signal(SIGTERM, bye); signal(SIGINT, bye);
    const char *n = getenv("NONCE");
    printf("bench76980610-ready nonce=%s\n", n ? n : "none");
    fflush(stdout);
    for (;;) pause();
}
CEOF
gcc -static -Os -s -o "$BUILD/app" "$BUILD/app.c"
cat > "$BUILD/mkimage.py" <<'PYEOF'
import hashlib, io, json, sys, tarfile

out, tag, arch, entry, binary = sys.argv[1:6]
layer_buf = io.BytesIO()
with tarfile.open(fileobj=layer_buf, mode="w", format=tarfile.USTAR_FORMAT) as lt:
    data = open(binary, "rb").read()
    ti = tarfile.TarInfo(entry.strip("/"))
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 0
    lt.addfile(ti, io.BytesIO(data))
layer = layer_buf.getvalue()
diff_id = hashlib.sha256(layer).hexdigest()
config = json.dumps({"architecture": arch, "os": "linux", "created": "1970-01-01T00:00:00Z",
                     "config": {"Entrypoint": [entry], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + diff_id]}},
                    sort_keys=True, separators=(",", ":")).encode()
image_id = hashlib.sha256(config).hexdigest()
manifest = json.dumps([{"Config": image_id + ".json", "RepoTags": [tag], "Layers": [diff_id + "/layer.tar"]}]).encode()


def add(t, name, payload):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime = len(payload), 0o644, 0
    t.addfile(ti, io.BytesIO(payload))


with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    d = tarfile.TarInfo(diff_id)
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, 0
    t.addfile(d)
    add(t, diff_id + "/layer.tar", layer)
    add(t, image_id + ".json", config)
    add(t, "manifest.json", manifest)
PYEOF
python3 "$BUILD/mkimage.py" "$WORK_DIR/app.tar" "$IMAGE" "$IMG_ARCH" /app "$BUILD/app"
chmod 0644 "$WORK_DIR/app.tar"

echo "[setup] the node (the agent's machine after the move to containerd): a new mount namespace whose /run, /etc/docker and /etc/containerd are private tmpfs, so the Docker socket of this host is not there; only containerd runs in it..."
sudo sh -c ': > "$1"' _ "$LIB_BASE/created_dirs"
for d in /etc/docker /etc/containerd; do [ -d "$d" ] || { sudo mkdir -p "$d"; echo "$d" | sudo tee -a "$LIB_BASE/created_dirs" >/dev/null; }; done
find /sys/fs/cgroup -maxdepth 2 -name docker -type d 2>/dev/null | sort | sudo tee "$LIB_BASE/cgroup_docker.base" >/dev/null
# the shims of a daemon that runs on the host side (not in the node) keep runc state and shim sockets in the HOST's /run/containerd: record what is there now
if [ -d /run/containerd ]; then
    sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
else
    echo "NOEXIST" | sudo tee "$LIB_BASE/hostrun.base" >/dev/null
fi
cat > "$BUILD/boot.sh" <<'BEOF'
#!/bin/bash
# runs as root as the first process of a new mount namespace (unshare -m): this is the node
V=$1; CONTAINERD=$2
for d in /run /etc/docker /etc/containerd; do mount -t tmpfs tmpfs "$d" || exit 1; done
mkdir -p /run/containerd
python3 "$V/node/engine-proxy.py" /run/docker.sock /run/docker.raw.sock >"$V/node/proxy.log" 2>&1 </dev/null &
echo $! > "$V/node/proxy.pid"
cat > /etc/containerd/config.toml <<EOF
version = 2
root = "$V/lib/containerd"
state = "/run/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
[grpc]
  address = "/run/containerd/containerd.sock"
EOF
# the node's dockerd settings (nothing here says where containerd is): cgroupfs (there is no systemd in the node), the classic image store, no bridge and no iptables
cat > /etc/docker/daemon.json <<EOF
{"data-root": "$V/lib/docker", "exec-opts": ["native.cgroupdriver=cgroupfs"], "features": {"containerd-snapshotter": false},
 "bridge": "none", "iptables": false, "ip6tables": false, "ip-forward": false, "userland-proxy": false}
EOF
readlink /proc/self/ns/mnt > "$V/node/node.ns"
echo $$ > "$V/node/node.pid"
exec "$CONTAINERD" --config /etc/containerd/config.toml >"$V/node/containerd.log" 2>&1 </dev/null
BEOF
sudo install -m 0755 "$BUILD/boot.sh" "$LIB_BASE/node/boot.sh"
sudo setsid -f unshare -m --propagation private bash "$LIB_BASE/node/boot.sh" "$LIB_BASE" "$CONTAINERD_BIN" </dev/null >/dev/null 2>&1

echo "[setup] the tools of the job: 'node-run CMD' runs CMD in the node (like kubectl exec into the agent); 'run-test [HOLDFILE]' is the job's test step (HOME=$WORK_DIR/home, Ryuk and the disk check off because their image cannot be pulled here)..."
cat > "$WORK_DIR/bin/node-run" <<REOF
#!/bin/sh
# node-run COMMAND [ARGS...]: run COMMAND inside the node
[ \$# -ge 1 ] || { echo "usage: node-run COMMAND [ARGS...]" >&2; exit 2; }
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/node/node.pid)/ns/mnt -- "\$@"
REOF
cat > "$WORK_DIR/bin/run-test" <<REOF
#!/bin/sh
# run-test [HOLDFILE]: the test step of the job (the JUnit console launcher runs bench.AppContainerTest), inside the node, with a clean environment (no DOCKER_HOST)
exec sudo nsenter --mount=/proc/\$(cat $LIB_BASE/node/node.pid)/ns/mnt -- env -i HOME=$WORK_DIR/home PATH=/usr/sbin:/usr/bin:/sbin:/bin TESTCONTAINERS_RYUK_DISABLED=true TESTCONTAINERS_CHECKS_DISABLE=true \\
    $JAVA_BIN -Duser.home=$WORK_DIR/home -Dbench.tar=$WORK_DIR/app.tar -Dbench.image=$IMAGE \${1:+-Dbench.hold=\$1} \\
    -cp "$CP_JARS$LIB_BASE/probe:$CONSOLE" org.junit.platform.console.ConsoleLauncher --select-class bench.AppContainerTest --disable-banner --disable-ansi-colors --details=tree --details-theme=ascii
REOF
chmod 0755 "$WORK_DIR/bin/node-run" "$WORK_DIR/bin/run-test"
NR="$WORK_DIR/bin/node-run"
for _ in $(seq 1 40); do
    [ -s "$LIB_BASE/node/node.pid" ] && "$NR" "$CTR_BIN" --address /run/containerd/containerd.sock version >/dev/null 2>&1 && break
    sleep 0.5
done
"$NR" "$CTR_BIN" --address /run/containerd/containerd.sock version >/dev/null 2>&1 || { echo "[setup] ERROR: the node's containerd did not come up; last log lines:"; tail -20 "$LIB_BASE/node/containerd.log" 2>/dev/null; exit 1; }
for _ in $(seq 1 40); do "$NR" test -S /run/docker.sock && break; sleep 0.5; done
"$NR" test -S /run/docker.sock || { echo "[setup] ERROR: the engine proxy did not come up"; cat "$LIB_BASE/node/proxy.log"; exit 1; }
echo "  -> the node's containerd is up (pid $(cat "$LIB_BASE/node/node.pid")), the engine proxy listens on /run/docker.sock (pid $(cat "$LIB_BASE/node/proxy.pid"))"

echo "[setup] recording the state (root-only): the node's containerd (process, mount namespace, configs), the hashes of the wrappers, jars, test classes and image tar, which containerd/dockerd processes exist in the node..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" LIB_BASE="$LIB_BASE" CTR_BIN="$CTR_BIN" DOCKERD_BIN="$DOCKERD_BIN" python3 - <<'PYEOF'
import glob, hashlib, json, os, subprocess

E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
pid = int(open(E["LIB_BASE"] + "/node/node.pid").read())
s = open("/proc/%d/stat" % pid).read()
node_sha = lambda path: subprocess.run(["nsenter", "--mount=/proc/%d/ns/mnt" % pid, "--", "sha256sum", path], capture_output=True, text=True).stdout.split()[0]
files = sorted(glob.glob(E["LIB_BASE"] + "/jars/*.jar")) + [E["LIB_BASE"] + "/node/engine-proxy.py", E["LIB_BASE"] + "/probe/bench/App.class", E["LIB_BASE"] + "/probe/bench/AppContainerTest.class", E["WORK_DIR"] + "/app.tar", E["WORK_DIR"] + "/bin/node-run", E["WORK_DIR"] + "/bin/run-test"]
ppid = int(open(E["LIB_BASE"] + "/node/proxy.pid").read())
ps = open("/proc/%d/stat" % ppid).read()
d = {"proxy_pid": ppid, "proxy_start": int(ps[ps.rindex(")") + 2:].split()[19]), "pid": pid, "start": int(s[s.rindex(")") + 2:].split()[19]), "node_ns": open(E["LIB_BASE"] + "/node/node.ns").read().strip(),
     "host_ns": os.readlink("/proc/self/ns/mnt"), "ctr": E["CTR_BIN"], "dockerd": E["DOCKERD_BIN"],
     "containerd_conf_sha": node_sha("/etc/containerd/config.toml"), "daemon_json_sha": node_sha("/etc/docker/daemon.json"),
     "files": {f: sha(f) for f in files}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The node has containerd only (no Docker API); the job's test, its HOME and the image tar are in $WORK_DIR."
