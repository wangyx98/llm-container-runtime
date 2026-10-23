#!/bin/bash
# Reference solution: containerd 1.6.8 ships its tracing plugin without an endpoint, so it logs `failed to initialize a tracing processor "otlp": no OpenTelemetry endpoint: skip plugin` and exports nothing; the
# message is harmless, tracing is just off. To turn it on, the otlp processor needs an endpoint that is a URL for the collector's OTLP/HTTP receiver (4318; 1.6.8 sends http/protobuf by default and has no working
# gRPC export: a bare host:port is rejected, and the gRPC port 4317 or protocol "grpc" are accepted silently and send nothing). The configuration is read when containerd starts, so containerd is restarted.
set -e
LIB="/var/lib/bench73550556"
sudo sed -i '/^\s*\[plugins."io.containerd.tracing.processor.v1.otlp"\]/,/^\s*$/ s|^\(\s*endpoint = \)""|\1"http://127.0.0.1:4318"|' "$LIB/etc/containerd.toml"
sudo grep -A3 'processor.v1.otlp' "$LIB/etc/containerd.toml"
sudo "$LIB/bin/nodectl" restart
sudo "$LIB/bin/crictl" version >/dev/null
sleep 8
sudo grep -c '"name":"runtime.v1.RuntimeService/Version"' /run/bench73550556/spans.jsonl || true
