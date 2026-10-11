#!/bin/bash
set -e

APP_DIR="/tmp/bench76119356/app"
SOCK_A="/run/bench76119356/a/docker.sock"
SOCK_B="/run/bench76119356/b/docker.sock"

# The default runtime and the runtimes of a Docker daemon are a property of the daemon, not of the machine or of the client: the daemon reports
# them in its own API, GET /info ("docker info": DefaultRuntime and Runtimes). So the program asks the daemon behind the endpoint it is given,
# over that endpoint, instead of looking for a dockerd process on the machine (there can be several, or none: this machine has two), and it
# takes nothing from DOCKER_HOST. The standard library is enough for that: the Docker Go SDK (github.com/docker/docker) makes the same call
# (client.Info), but at v27.5.1+incompatible it has no go.mod, so its dependencies are taken at their latest versions, and the latest
# github.com/docker/go-connections no longer has sockets.DialPipe, which that client calls: it does not compile without pinning them.
cat > "$APP_DIR/main.go" <<'GOEOF'
// rtinfo: print the default runtime and the runtimes of the Docker daemon behind a Docker endpoint, as the daemon reports them
// (the Engine API: GET /info).
//
//	rtinfo --host unix:///path/to/docker.sock
//
// It prints one JSON object: {"host":..., "default_runtime":..., "runtimes":[...]}; on failure it prints nothing on stdout and exits non-zero.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

func main() {
	host := flag.String("host", "", "Docker daemon endpoint: unix:///path/to/docker.sock or tcp://host:port")
	flag.Parse()
	network, addr := "", ""
	switch {
	case strings.HasPrefix(*host, "unix://"):
		network, addr = "unix", strings.TrimPrefix(*host, "unix://")
	case strings.HasPrefix(*host, "tcp://"):
		network, addr = "tcp", strings.TrimPrefix(*host, "tcp://")
	default:
		fmt.Fprintln(os.Stderr, "rtinfo: --host must be a unix:// or tcp:// endpoint")
		os.Exit(2)
	}

	hc := &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		}},
	}
	resp, err := hc.Get("http://docker/info")
	if err != nil {
		fmt.Fprintf(os.Stderr, "rtinfo: cannot read the info of %s: %v\n", *host, err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	var info struct {
		DefaultRuntime string
		Runtimes       map[string]json.RawMessage
	}
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&info) != nil {
		fmt.Fprintf(os.Stderr, "rtinfo: %s did not answer as a Docker daemon (HTTP %d)\n", *host, resp.StatusCode)
		os.Exit(1)
	}

	names := []string{}
	for n := range info.Runtimes {
		names = append(names, n)
	}
	sort.Strings(names)
	json.NewEncoder(os.Stdout).Encode(map[string]any{"host": *host, "default_runtime": info.DefaultRuntime, "runtimes": names})
}
GOEOF

echo "[solution] building it (the standard library only: nothing is downloaded)..."
cd "$APP_DIR"
go build -o rtinfo .

echo "[solution] the program on the two endpoints:"
./rtinfo --host "unix://$SOCK_A"
./rtinfo --host "unix://$SOCK_B"
