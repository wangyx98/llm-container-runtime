# q69999835 — GKE Containerd node pool with nexus insecure registry (configuration) — NOT COLLECTED

Status: analysed and not collected by the user (2026-11-19), after it had been marked deferred for the cloud environment. Nothing was built (no case files, test suite, fixtures or docs-index entries).

## What the thread is about
A GKE cluster: the asker's Nexus is an insecure (plain HTTP) Docker registry, with an imagePullSecret. Pods pull fine on a Docker node pool; a new containerd node pool (`cos_containerd`) fails with `Http: server gave HTTP response to HTTPS client`. No answer. Comments only say a pull secret should work like for any registry, ask for the full error and suggest Artifact Registry; part of the comments is collapsed in the cached page.

## Why it was not collected
- The part specific to the thread is the platform: GKE's managed node pool, where containerd's configuration lives on a COS node image, its persistence across node recreation and the supported ways to change it. The screening note asks for a real GKE node pool with a pinned node image, a supported node-configuration route, a rebuilt node and no change made only in a temporary SSH session. The sandbox reaches no Google endpoint (`gcr.io`, `*.pkg.dev`, the metadata server, `oauth2.googleapis.com` all fail) and has no GCP credentials, so none of it could be run.
- What remains on a plain Linux node is covered: plain-HTTP registry through `config_path` + `hosts.toml` (q69088569, q75622952), credentials handed to the runtime by the kubelet's pull secret (q72183367), node configuration regenerated from a template and lost at restart (q66642654), node-held registry credentials (q73910486, q67635227, q76136482). A local stand-in would add no new runtime behaviour.

## If it is taken up later
Needs a real GKE node pool (containerd node image pinned), a plain-HTTP Nexus reachable from it with an account, and a supported way to give containerd the registry's hosts configuration that survives node recreation (node pool upgrade or recreate, not an SSH edit). Oracle: a pod with a new digest pulls and runs, after the node is rebuilt it still does, the pull secret's account is kept; a control node pool without the configuration fails with the HTTP-to-HTTPS error.
