#!/bin/bash
set -e
# Reference solution. containerd has no Dockerfile build: the build is done by BuildKit (the buildkitd of this machine, whose containerd worker keeps
# what it builds in its own containerd namespace "buildkit"), and BuildKit has a Go client (github.com/moby/buildkit/client). The program asks buildkitd
# to build the Dockerfile of the context (frontend dockerfile.v0, the context directory as the local mounts) and to export the result as an OCI archive
# into a pipe; the containerd client reads the pipe into the namespace of the program (client.Import), unpacks the image, and runs a container from it
# exactly as the pull-based example did. The result is the output of the container: the sha256 that the RUN step of the Dockerfile wrote.
cd /var/lib/bench66733729/app
cat > main.go <<'GOEOF'
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	bkclient "github.com/moby/buildkit/client"
	"github.com/tonistiigi/fsutil"
	"golang.org/x/sync/errgroup"
)

const (
	containerdSock = "/run/bench66733729/containerd.sock"
	buildkitSock   = "unix:///run/bench66733729/buildkitd.sock"
	namespace      = "bench66733729"
)

func main() {
	contextDir := flag.String("context", "", "build context directory (with a Dockerfile)")
	tag := flag.String("tag", "", "image reference")
	flag.Parse()
	if err := run(*contextDir, *tag); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(contextDir, ref string) error {
	ctx := namespaces.WithNamespace(context.Background(), namespace)
	client, err := containerd.New(containerdSock)
	if err != nil {
		return err
	}
	defer client.Close()

	bk, err := bkclient.New(ctx, buildkitSock)
	if err != nil {
		return err
	}
	defer bk.Close()
	fs, err := fsutil.NewFS(contextDir)
	if err != nil {
		return err
	}
	pr, pw := io.Pipe()
	eg, egctx := errgroup.WithContext(ctx)
	eg.Go(func() error {
		_, err := bk.Solve(egctx, nil, bkclient.SolveOpt{
			Frontend:      "dockerfile.v0",
			FrontendAttrs: map[string]string{"filename": "Dockerfile"},
			LocalMounts:   map[string]fsutil.FS{"context": fs, "dockerfile": fs},
			Exports: []bkclient.ExportEntry{{
				Type:   bkclient.ExporterOCI,
				Attrs:  map[string]string{"name": ref},
				Output: func(map[string]string) (io.WriteCloser, error) { return pw, nil },
			}},
		}, nil)
		pw.CloseWithError(err)
		return err
	})
	eg.Go(func() error {
		imgs, err := client.Import(egctx, pr)
		io.Copy(io.Discard, pr)
		if err != nil {
			return err
		}
		for _, i := range imgs {
			if err := containerd.NewImage(client, i).Unpack(egctx, ""); err != nil {
				return err
			}
		}
		return nil
	})
	if err := eg.Wait(); err != nil {
		return err
	}

	image, err := client.GetImage(ctx, ref)
	if err != nil {
		return err
	}
	id := fmt.Sprintf("bench66733729-run-%d", time.Now().UnixNano())
	container, err := client.NewContainer(ctx, id,
		containerd.WithImage(image),
		containerd.WithNewSnapshot(id+"-snapshot", image),
		containerd.WithNewSpec(oci.WithImageConfig(image)))
	if err != nil {
		return err
	}
	defer container.Delete(ctx, containerd.WithSnapshotCleanup)
	task, err := container.NewTask(ctx, cio.NewCreator(cio.WithStdio))
	if err != nil {
		return err
	}
	defer task.Delete(ctx)
	exit, err := task.Wait(ctx)
	if err != nil {
		return err
	}
	if err := task.Start(ctx); err != nil {
		return err
	}
	st := <-exit
	if code, _, _ := st.Result(); code != 0 {
		return fmt.Errorf("the container exited with %d", code)
	}
	return nil
}
GOEOF
GOFLAGS=-mod=mod /var/lib/bench66733729/bin/go build -o app .
sudo ./app -context /var/lib/bench66733729/demo -tag docker.io/library/bench66733729-app:1
