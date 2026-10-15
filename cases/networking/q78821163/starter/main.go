// dind: start the Docker-in-Docker container of the application with the containerd Go client (the program of the question: it creates and starts the container, and the Docker inside
// it cannot pull from the private registry).
//
//	dind --address SOCKET --namespace NS --name NAME --image REF --data DIR --ca FILE
//
// The image REF is in the namespace NS already. DIR (the host directory of the inner Docker's /var/lib/docker) and FILE (the CA certificate of the private registry) are mounted in the
// container, which runs privileged (and, on cgroup v2, in a cgroup namespace of its own: the inner Docker needs both).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	specs "github.com/opencontainers/runtime-spec/specs-go"
)

func main() {
	address := flag.String("address", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "default", "containerd namespace")
	name := flag.String("name", "dind", "name of the container")
	imageRef := flag.String("image", "", "image of the container (in the namespace already)")
	data := flag.String("data", "", "host directory for /var/lib/docker of the inner Docker")
	ca := flag.String("ca", "", "CA certificate of the private registry")
	flag.Parse()
	if *imageRef == "" || *data == "" || *ca == "" {
		log.Fatal("--image, --data and --ca are required")
	}

	cli, err := containerd.New(*address)
	if err != nil {
		log.Fatal(err)
	}
	defer cli.Close()
	ctx := namespaces.WithNamespace(context.Background(), *namespace)

	image, err := cli.GetImage(ctx, *imageRef)
	if err != nil {
		log.Fatal(err)
	}

	mnts := []specs.Mount{
		{Destination: "/var/lib/docker", Type: "bind", Source: *data, Options: []string{"rbind", "rw"}},
		{Destination: "/sys/fs/cgroup", Type: "cgroup", Source: "cgroup", Options: []string{"nosuid", "noexec", "nodev", "rw"}}, // the default spec of the SDK has no cgroup mount
		{Destination: "/etc/docker/certs.d/private-repo.local/ca.crt", Type: "bind", Source: *ca, Options: []string{"rbind", "ro"}},
	}
	containerEnv := []string{"DOCKER_TLS_CERTDIR="}

	specOpts := []oci.SpecOpts{
		oci.WithImageConfig(image),
		oci.WithPrivileged,
		oci.WithAllDevicesAllowed, // what "ctr run --privileged" adds: the devices of the host, all allowed (the inner runc writes device rules)
		oci.WithHostDevices,
		oci.WithEnv(containerEnv),
		oci.WithMounts(mnts),
	}
	if _, err := os.Stat("/sys/fs/cgroup/cgroup.controllers"); err == nil { // cgroup v2: the inner Docker needs a cgroup namespace of its own
		specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.CgroupNamespace}))
	}

	container, err := cli.NewContainer(ctx, *name,
		containerd.WithImage(image),
		containerd.WithNewSnapshot(*name+"-snapshot", image),
		containerd.WithNewSpec(specOpts...),
	)
	if err != nil {
		log.Fatal(err)
	}

	logPath := *data + "/../" + *name + ".log"
	task, err := container.NewTask(ctx, cio.LogURI(&url.URL{Scheme: "file", Path: logPath}))
	if err != nil {
		log.Fatal(err)
	}
	if err := task.Start(ctx); err != nil {
		log.Fatal(err)
	}
	out, _ := json.Marshal(map[string]interface{}{"container": *name, "pid": task.Pid()})
	fmt.Fprintln(os.Stdout, string(out))
}
