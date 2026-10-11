// pull: pull an image with the containerd Go client (the program of the question: it works, and it is silent).
//
//	pull --address SOCKET --namespace NS --ref REF
//
// The registry of this case speaks plain HTTP, hence the resolver below.
package main

import (
	"context"
	"flag"
	"log"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/pkg/namespaces"
)

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

	// pull image
	image, err := client.Pull(ctx, *ref, containerd.WithPullUnpack, containerd.WithResolver(resolver))
	if err != nil {
		log.Fatal(err)
	}

	log.Printf(" Pulled image: %s", image.Name())
}
