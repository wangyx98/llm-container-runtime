# q76459359 — Metrics for image pull time for GKE cluster? (diagnostics) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

Source: https://stackoverflow.com/questions/76459359/metrics-for-image-pull-time-for-gke-cluster

## What the thread is about
Asked 2023-06. "Is there a way to get metrics for image pull time on GKE?" The asker found containerd PR 7313 but nothing in the GKE documentation; the nodes use the `cos_containerd` image. No answer, no comment, no failing state: it is a question about whether a capability exists.

## What was checked (2026-11-19, sandbox, read-only)
- The containerd 2.4.2 and 2.2.1 binaries contain CRI metric names `image_pulls` (a count) and `image_pulling_throughput` (`..._mibps` in 2.4.2), and no name for a pull duration. Found by searching the binary's strings; the endpoint was not scraped and PR 7313 was not read. A pull time on a self-managed containerd would have to be derived from throughput and size.
- Not checked: what GKE exposes (its metrics agent and node configuration are not user-configurable and not reachable from the sandbox).

## Why it was not collected
- Platform: a managed GKE `cos_containerd` node; the screening note says the GKE native metric must be proven first and local timing is only an adaptation. The screening rule skips cases bound to a third-party platform.
- No verifiable cause or answer in the thread; any local task (containerd `[metrics]` address, a throttled local registry, reading the pull count and throughput) is our own design, with a derived "time" and a disputable oracle.
- Cost about 3 hours for a task that is an observability interface, not a repair.
- Coverage: no existing case reads containerd's metrics endpoint (new), but the value does not offset the above.

## If it is taken up later
Only as a stated adaptation on a self-managed containerd 2.x: `[metrics] address` on, a local registry that throttles a layer download to a known rate, a cold pull and a cache-hit pull through the CRI; oracle: `image_pulls` grows by one per cold pull, the throughput observation falls in the range that the throttle implies, the cache hit does not add a transfer, and the numbers are read from the endpoint of the running containerd (not from application timing). It must not be presented as GKE's native metric.
