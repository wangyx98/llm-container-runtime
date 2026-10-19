#!/bin/bash
set -e
# Reference solution. CRI-O has no export of its own (crictl has none, and the CRI has no call for it), but the images of CRI-O are plain containers/storage, and the Go libraries
# CRI-O is made of can read them: containers/image copies an image from the transport "containers-storage:" (the store of CRI-O) to a "docker-archive:" file, layer by layer and
# with its config, without a registry. The Go program is the export; it runs as root, because the store is root's.
cd /var/lib/bench71499683/app
cat > main.go <<'GOEOF'
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/containers/image/v5/copy"
	"github.com/containers/image/v5/signature"
	"github.com/containers/image/v5/transports/alltransports"
	"github.com/containers/image/v5/types"
)

func main() {
	image := flag.String("image", "", "name of the image in the storage of CRI-O, as 'crictl images' shows it")
	out := flag.String("out", "", "archive file to write (it must not exist yet)")
	flag.Parse()
	if *image == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: app -image NAME -out FILE")
		os.Exit(2)
	}
	if err := run(*image, *out); err != nil {
		fmt.Fprintln(os.Stderr, "export:", err)
		os.Exit(1)
	}
}

func run(image, out string) error {
	ctx := context.Background()
	src, err := alltransports.ParseImageName("containers-storage:" + image)
	if err != nil {
		return err
	}
	dst, err := alltransports.ParseImageName("docker-archive:" + out + ":" + image)
	if err != nil {
		return err
	}
	policy, err := signature.NewPolicyFromBytes([]byte(`{"default":[{"type":"insecureAcceptAnything"}]}`))
	if err != nil {
		return err
	}
	pc, err := signature.NewPolicyContext(policy)
	if err != nil {
		return err
	}
	defer pc.Destroy()
	_, err = copy.Image(ctx, pc, dst, src, &copy.Options{ReportWriter: os.Stderr, SourceCtx: &types.SystemContext{}})
	return err
}
GOEOF
/var/lib/bench71499683/bin/go build -o app .
sudo ./app -image registry.bench71499683.invalid/shop/app:1.0 -out /tmp/bench71499683/shop-app.tar
