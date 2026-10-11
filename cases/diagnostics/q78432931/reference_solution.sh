#!/bin/bash
set -e

APP_DIR="/tmp/bench78432931/app"
SOCK="/run/bench78432931/containerd/containerd.sock"

# Where the numbers are: while client.Pull downloads a blob, containerd's content store holds it as an ingest (an active write: ctr and nerdctl
# show the same thing), with the bytes written so far (Offset) and the size of the blob (Total); when the blob is committed the ingest is gone
# and the blob is in the store, with its Size. So progress is a poll of the content store next to the pull: ListStatuses for the active
# downloads, Info for the ones that completed. Every change is a JSON line on stdout; the pull itself is unchanged (and a failed pull still
# ends in log.Fatal, without a done record).
cat > "$APP_DIR/main.go" <<'EOF'
// pull: pull an image with the containerd Go client and report the progress of the download as JSON lines on stdout.
//
//	pull --address SOCKET --namespace NS --ref REF
//
// The registry of this case speaks plain HTTP, hence the resolver below.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"strings"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	digest "github.com/opencontainers/go-digest"
)

var stdout = json.NewEncoder(os.Stdout)

func progress(d string, offset, total int64) {
	stdout.Encode(map[string]any{"event": "progress", "digest": d, "offset": offset, "total": total})
}

// watch reports, until stop is closed, how far every blob of the pull is.
func watch(ctx context.Context, cs content.Store, stop <-chan struct{}) {
	last := map[string]int64{}
	total := map[string]int64{}
	complete := map[string]bool{}
	report := func() {
		active := map[string]bool{}
		// the downloads in progress: refs are "layer-sha256:...", "config-sha256:...", ...
		if statuses, err := cs.ListStatuses(ctx); err == nil {
			for _, s := range statuses {
				i := strings.Index(s.Ref, "sha256:")
				if i < 0 || s.Total <= 0 {
					continue
				}
				d := s.Ref[i:]
				active[d], total[d] = true, s.Total
				if s.Offset != last[d] {
					last[d] = s.Offset
					progress(d, s.Offset, s.Total)
				}
			}
		}
		// a blob whose download was seen and is not in progress any more has been committed: it is complete
		for d := range total {
			if active[d] || complete[d] {
				continue
			}
			if info, err := cs.Info(ctx, digest.Digest(d)); err == nil {
				complete[d] = true
				last[d] = info.Size
				progress(d, info.Size, info.Size)
			}
		}
	}
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
			report()
		case <-stop:
			report()
			return
		}
	}
}

func main() {
	address := flag.String("address", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "k8s.io", "containerd namespace")
	ref := flag.String("ref", "", "image reference to pull")
	flag.Parse()
	if *ref == "" {
		log.Fatal("--ref is required")
	}

	// create connection to containerd
	client, err := containerd.New(*address)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	ctx := namespaces.WithNamespace(context.Background(), *namespace)

	resolver := docker.NewResolver(docker.ResolverOptions{
		Hosts: docker.ConfigureDefaultRegistries(docker.WithPlainHTTP(docker.MatchAllHosts)),
	})

	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() {
		watch(ctx, client.ContentStore(), stop)
		close(stopped)
	}()

	// pull image
	image, err := client.Pull(ctx, *ref, containerd.WithPullUnpack, containerd.WithResolver(resolver))
	close(stop)
	<-stopped // the last progress records are out before anything else is printed
	if err != nil {
		log.Fatal(err)
	}

	target := image.Target()
	stdout.Encode(map[string]any{"event": "done", "name": image.Name(), "digest": target.Digest.String(), "size": target.Size})
	log.Printf(" Pulled image: %s", image.Name())
}
EOF

echo "[solution] building it (the modules the program needs beyond the starter's are downloaded here)..."
cd "$APP_DIR"
GOFLAGS=-mod=mod go build -o pull .

echo "[solution] pulling the image of the setup with it:"
./pull --address "$SOCK" --namespace k8s.io --ref 127.0.0.1:43293/bench/app:1
