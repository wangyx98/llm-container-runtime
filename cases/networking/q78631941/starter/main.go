// lazyrun: pull an image through the SOCI snapshotter and run a container from it with the containerd Go client (the program of the question: the layer is meant to be lazy-loaded, mounted
// through FUSE by the snapshotter and read from the registry on demand).
//
//	lazyrun --address SOCKET --namespace NS --name NAME --ref IMAGE_REF --snapshotter SNAPSHOTTER
//
// The registry speaks plain HTTP only, so the pull uses a resolver with plain HTTP. The program runs as root: oci.WithImageConfig mounts the snapshot of the container.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/containerd/v2/pkg/snapshotters"
)

func main() {
	address := flag.String("address", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "default", "containerd namespace")
	name := flag.String("name", "lazy", "name of the container")
	ref := flag.String("ref", "", "image reference, host:port/repository:tag")
	snapshotter := flag.String("snapshotter", "soci", "snapshotter of the image and of the container")
	logDir := flag.String("log-dir", "/var/lib/bench78631941", "directory of the container's log file")
	flag.Parse()
	if *ref == "" {
		log.Fatal("--ref is required")
	}

	cli, err := containerd.New(*address)
	if err != nil {
		log.Fatal(err)
	}
	defer cli.Close()
	ctx := namespaces.WithNamespace(context.Background(), *namespace)

	// the registry of the machine speaks HTTP only: a resolver with plain HTTP for every host
	resolver := docker.NewResolver(docker.ResolverOptions{
		Hosts: docker.ConfigureDefaultRegistries(docker.WithPlainHTTP(func(string) (bool, error) { return true, nil })),
	})

	image, err := cli.Pull(ctx, *ref,
		containerd.WithResolver(resolver),
		containerd.WithPullSnapshotter(*snapshotter),
		containerd.WithPullUnpack,
		// the labels (image reference, layer digests, ...) the remote snapshotter needs in Prepare
		containerd.WithImageHandlerWrapper(snapshotters.AppendInfoHandlerWrapper(*ref)),
	)
	if err != nil {
		log.Fatalf("pull %s: %v", *ref, err)
	}

	container, err := cli.NewContainer(ctx, *name,
		containerd.WithImage(image),
		containerd.WithSnapshotter(*snapshotter),
		containerd.WithNewSnapshot(*name+"-snapshot", image),
		containerd.WithNewSpec(oci.WithImageConfig(image)),
	)
	if err != nil {
		log.Fatalf("create container %s: %v", *name, err)
	}

	task, err := container.NewTask(ctx, cio.LogURI(&url.URL{Scheme: "file", Path: filepath.Join(*logDir, *name+".log")}))
	if err != nil {
		log.Fatalf("create task: %v", err)
	}
	if err := task.Start(ctx); err != nil {
		log.Fatalf("start task: %v", err)
	}
	out, _ := json.Marshal(map[string]interface{}{"container": *name, "image": *ref, "snapshotter": *snapshotter, "pid": task.Pid()})
	fmt.Fprintln(os.Stdout, string(out))
}
