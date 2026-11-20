# q63735308 — How to add harbor registry in containerd (configuration) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19). Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
Asked 2020-09 (RHEL 8, Kubernetes + containerd CRI): the asker "added Harbor as an insecure registry" and Kubernetes still cannot pull Harbor images; the error is only in a screenshot (not in the cached page). One answer (community wiki, no votes) asks how Harbor was installed (Helm? bitnami chart?) and links Harbor issue #1238 and the Kubernetes page on configuring nodes to authenticate to a private registry. No containerd version, no config text, no registry address or scheme, no error text.

## Why it was not collected
- The cause is not established: an HTTP registry spoken to over HTTPS, a self-signed certificate, a private Harbor project without credentials, and an `insecure` entry written in a syntax the containerd version does not read are all consistent with the thread. A case would have to choose one branch itself; the screening note asks not to invent a TLS error.
- Coverage: a Harbor stand-in with Bearer token routes, CA trust, skip_verify as a failing sample and a rogue-certificate refusal check: q75622952; an old-style `mirrors` entry with `insecure_skip_verify` that has no effect, fixed through the right place and hosts.toml: q66642654; plain-HTTP registry through `config_path` + hosts.toml: q69088569; credentials held by the node or given by the kubelet: q73910486, q72183367, q76379942, q64540738; the same wording on a managed platform (GKE + Nexus): q69999835, not collected.

## If it is taken up later
Only after the screenshot's text and the Harbor/containerd configuration are known. The one branch that would add something is a Harbor with a self-signed certificate and an `insecure` setting in a form the containerd version ignores (reference: hosts.toml `skip_verify = true` or the CA in `ca`), with a behavioural control that an untrusted certificate is still refused where verification is kept; it would be an adaptation stated in task.txt, built on the q75622952 front and the q76379942 node.
