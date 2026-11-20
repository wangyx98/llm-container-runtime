# q77878903 — container_fs_usage_bytes metrics miss pod/container label on containerd (diagnostics) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

Source: https://stackoverflow.com/questions/77878903/container-fs-usage-bytes-metrics-miss-pod-container-label-on-containerd

## What the thread is about
AWS EKS, `kubectl version v1.24.15-eks`, containerd 1.6.19. The asker says `container_fs_usage_bytes` has no `pod` and `container` labels and asks for a solution. Nothing else: no scrape output, no kubelet or Prometheus configuration, no statement of which series lack the labels. The only answer (0 votes) is a generic checklist: containerd >= 1.4.3, `plugins.cri.enable_metrics_provider` and `metrics_provider_socket_path`, `--container-runtime=remote`, restart containerd and kubelet, try Docker, open an issue on the EKS AMI repository.

## What was checked (2026-11-19, sandbox)
- The two containerd keys of the answer are not in the default configuration of containerd 2.4.2 and 2.2.1 (`containerd config default` has only `[metrics]` address and the grpc-prometheus plugin); not checked for 1.6.19. They are not a reliable reference.
- Not run: the `pod`, `container` and `namespace` labels of `/metrics/cadvisor` are made by the kubelet's cadvisor handler, not by the runtime, so a reproduction needs a real kubelet (k3s with an offline pause image and a writing pod, about half an hour). It was not done: the thread gives no symptom to compare with.

## Why it was not collected
- Third-party platform: the original is an EKS AMI (kubelet 1.24.15); the screening rule skips AWS-bound cases.
- The symptom is undefined: cAdvisor reports filesystem metrics per device and per cgroup level (pod, slice, container), and the label sets differ by level, so without the real series it is not known whether anything is wrong.
- No sample, no source and no fixed-version plan, which the stop condition asks for.
- Coverage: the resource-metric identity family is already touched by q63132692 (no CPU in gVisor pod stats, known cause) and the pre-study of q52678769 (CRI stats); this thread adds no verifiable cause.

## If it is taken up later
Only with the real `/metrics/cadvisor` text (the series that lack the labels, with `id`, `device`, `name`), the kubelet flags, and a reproducible version pair. A k3s node with a writing pod and two same-name pods in different namespaces could then compare the kubelet's cadvisor series, the CRI stats (`crictl stats`) and `stats/summary` by UID; zero values or the same label added by hand must not pass.
