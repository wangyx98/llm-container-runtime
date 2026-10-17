"""mkproject.py PROJECT ZIP TRUTH NAME PORT : the project and the Gradle "distribution" of the lab.

ZIP      gradle-7.0.2-bin.zip, a fixed archive made once per setup (random token and filler, fixed timestamps): bin/gradle, lib/dist-token, lib/gradle-core-7.0.2.jar
PROJECT  a minimal project: Dockerfile, gradlew (a stand-in of the Gradle wrapper script), gradle/wrapper/gradle-wrapper.properties (distributionUrl and distributionSha256Sum of ZIP),
         settings.gradle, build.gradle, src/main/java/... and src/test/java/...
TRUTH    json: the token, the sha256 of ZIP, and the exact text and sha256 of the artifact build/libs/my-app-1.0.jar that 'gradlew clean build -x test' writes (the oracle recomputes nothing
         from the machine: it knows what a correct build writes)."""
import hashlib
import io
import json
import os
import secrets
import stat
import sys
import zipfile

project, zip_path, truth_path, name, port = sys.argv[1:6]
token = secrets.token_hex(12)

BIN_GRADLE = r'''#!/bin/bash
# stand-in for bin/gradle of Gradle 7.0.2: knows "clean" and "build" (and ignores -x test and the options); writes build/libs/my-app-1.0.jar as the Gradle build of this project would
HOME_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Welcome to Gradle 7.0.2 (stand-in distribution)!"
for a in "$@"; do
    case "$a" in
        clean) rm -rf build; echo "> Task :clean" ;;
        build)
            mkdir -p build/libs
            srcsum=$(find src -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
            {
                echo "Manifest-Version: 1.0"
                echo "Created-By: Gradle 7.0.2 (distribution token $(cat "$HOME_DIR/lib/dist-token"))"
                echo "Distribution-Sha256: ${GRADLE_DISTRIBUTION_SHA256:-unknown}"
                echo "Sources-Sha256: $srcsum"
            } > build/libs/my-app-1.0.jar
            echo "> Task :compileJava"; echo "> Task :jar"; echo "> Task :assemble"; echo "> Task :build" ;;
    esac
done
echo
echo "BUILD SUCCESSFUL in 1s"
'''

GRADLEW = r'''#!/bin/bash
# stand-in for the Gradle wrapper script (the real one starts a JVM): the same contract. It reads gradle/wrapper/gradle-wrapper.properties, downloads distributionUrl into
# $GRADLE_USER_HOME/wrapper/dists (unless it is already there), checks distributionSha256Sum, unpacks it and runs bin/gradle with the arguments of the command line.
APP_HOME="$(cd "$(dirname "$0")" && pwd)"
PROPS="$APP_HOME/gradle/wrapper/gradle-wrapper.properties"
prop() { sed -n "s/^$1=//p" "$PROPS" | sed 's/\\:/:/g' | head -1; }
URL=$(prop distributionUrl)
SUM=$(prop distributionSha256Sum)
USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
DIST_DIR="$USER_HOME/wrapper/dists/$(basename "$URL" .zip)/$(printf '%s' "$URL" | sha256sum | cut -c1-25)"
if [ ! -x "$DIST_DIR/gradle-7.0.2/bin/gradle" ]; then
    mkdir -p "$DIST_DIR"
    ZIP="$DIST_DIR/$(basename "$URL")"
    echo "Downloading $URL"
    if ! curl -fsS --connect-timeout 20 --max-time 120 -o "$ZIP" "$URL"; then
        echo
        echo "Exception in thread \"main\": could not download the Gradle distribution (the curl error is the line above)"
        rm -f "$ZIP"
        exit 1
    fi
    ACTUAL=$(sha256sum "$ZIP" | cut -d' ' -f1)
    if [ "$ACTUAL" != "$SUM" ]; then
        echo
        echo "Verification of Gradle distribution failed!"
        echo "  Expected: $SUM"
        echo "  Actual:   $ACTUAL"
        rm -f "$ZIP"
        exit 1
    fi
    unzip -q -o "$ZIP" -d "$DIST_DIR" || exit 1
    chmod +x "$DIST_DIR/gradle-7.0.2/bin/gradle"
fi
export GRADLE_DISTRIBUTION_SHA256="$SUM"
exec "$DIST_DIR/gradle-7.0.2/bin/gradle" "$@"
'''

APP = '''package com.example;

public class App {
    public static void main(String[] args) {
        System.out.println("my-app " + new Greeter().greeting());
    }
}
'''
GREETER = '''package com.example;

public class Greeter {
    String greeting() { return "built by a container build"; }
}
'''
TEST = '''package com.example;

public class GreeterTest {
    // run by "gradle test"; the build of the Dockerfile skips it with -x test
}
'''


def zinfo(n, mode):
    zi = zipfile.ZipInfo(n, (2021, 4, 1, 0, 0, 0))
    zi.external_attr = (stat.S_IFREG | mode) << 16
    zi.compress_type = zipfile.ZIP_DEFLATED
    return zi


buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr(zinfo("gradle-7.0.2/bin/gradle", 0o755), BIN_GRADLE)
    z.writestr(zinfo("gradle-7.0.2/lib/dist-token", 0o644), token + "\n")
    z.writestr(zinfo("gradle-7.0.2/lib/gradle-core-7.0.2.jar", 0o644), secrets.token_bytes(1 << 20))      # filler: a download of about one megabyte
data = buf.getvalue()
zsum = hashlib.sha256(data).hexdigest()
open(zip_path, "wb").write(data)

files = {
    "Dockerfile": '''FROM localhost/bench70704948-base:1 as builder

ENV NODE_ENV=development

WORKDIR /workspace/my-app

COPY . /workspace/my-app
RUN --mount=type=cache,target=/root/.gradle ./gradlew --no-watch-fs --no-daemon clean build -x test
''',
    "gradlew": GRADLEW,
    "gradle/wrapper/gradle-wrapper.properties": '''distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\\://%s\\:%s/distributions/gradle-7.0.2-bin.zip
distributionSha256Sum=%s
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
''' % (name, port, zsum),
    "settings.gradle": "rootProject.name = 'my-app'\n",
    "build.gradle": "plugins {\n    id 'java'\n}\n\ngroup = 'com.example'\nversion = '1.0'\n",
    "src/main/java/com/example/App.java": APP,
    "src/main/java/com/example/Greeter.java": GREETER,
    "src/test/java/com/example/GreeterTest.java": TEST,
}
srcs = sorted(p for p in files if p.startswith("src/"))
srcsum = hashlib.sha256("".join("%s  %s\n" % (hashlib.sha256(files[p].encode()).hexdigest(), p) for p in srcs).encode()).hexdigest()
for rel, text in files.items():
    p = os.path.join(project, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, 0o755 if rel == "gradlew" else 0o644)
artifact = ("Manifest-Version: 1.0\nCreated-By: Gradle 7.0.2 (distribution token %s)\nDistribution-Sha256: %s\nSources-Sha256: %s\n" % (token, zsum, srcsum))
json.dump({"token": token, "zip_sha256": zsum, "zip_size": len(data), "artifact": artifact, "artifact_sha256": hashlib.sha256(artifact.encode()).hexdigest(),
           "project_files": {rel: hashlib.sha256(text.encode()).hexdigest() for rel, text in files.items()}}, open(truth_path, "w"))
