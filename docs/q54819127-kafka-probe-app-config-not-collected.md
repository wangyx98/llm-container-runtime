# q54819127 — Kafka on Kubernetes under containerd, liveness probe fails (compatibility) — NOT COLLECTED

Status: analysed 2026-11-18, not built. Reason: no evidence that the runtime causes the failure; the only answer points at the image (application) side.

## What the thread says
- Upgrade from k8s 1.10 to v1.12.x with the same charts (runtime changed to containerd); zookeeper runs, Kafka fails its liveness probe.
- Probe: `exec [ sh -ec /usr/bin/jps | /bin/grep -q SupportedKafka ]`, exit 1. Image: confluentinc cp-kafka (4.1.0 etc.).
- The question is only "is some change required because of containerd?". No manifest, no logs, no resource/security settings, no exact versions.
- One answer (2024, not accepted, no votes, unverified, "possibly related"): in newer Confluent images (7.x, Kafka 3+) the JVM main class changed, so `jps | grep SupportedKafka` no longer matches; grep `Kafka` instead, or use `tcpSocket` on 9092.

## Why it is not collected
- The only measurable difference is that `jps` output no longer contains `SupportedKafka`. Explanations that do not involve the runtime: image version / main class name; `jps` reading `/tmp/hsperfdata_<user>` as another user or with another security context.
- A runtime case would need the same image and the same manifest, with only the runtime changed, and a probe that fails on one runtime and passes on the other. The thread has no such comparison.
- Building a stand-in (a program that prints a class name for `jps`) would test the application's probe configuration, not the runtime, and would inflate runtime coverage. The real cp-kafka/zookeeper images are large and Docker Hub is not reachable in the sandbox.
- The fixes of the answer (change the grep, switch to a TCP probe) are exactly what the success criteria exclude: a probe that is only loosened or disabled is not a repair.

## Reopen only if
- The original Kafka image, probe, resources and startup arguments are available, AND a same-image comparison shows the probe passing under one runtime and failing under another (an OCI/runtime injection difference such as the user, `/tmp`, hsperfdata, PID namespace or exec environment). Then the criterion would be: the original probe passes continuously and Kafka produces/consumes a test message, with resources and security settings unchanged.

## Related cases
- No overlap with the exec-probe/liveness direction in built cases; q71379578 / q72518766 use Kafka only as a Testcontainers workload.
