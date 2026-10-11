// rtinfo: print the default runtime and the runtimes of the Docker daemon behind a Docker endpoint, read from its API (GET /info).
//
//	rtinfo --host unix:///path/to/docker.sock
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
	host := flag.String("host", "", "Docker daemon endpoint, e.g. unix:///var/run/docker.sock")
	flag.Parse()
	if !strings.HasPrefix(*host, "unix://") {
		fmt.Fprintln(os.Stderr, "--host must be a unix:// endpoint")
		os.Exit(2)
	}
	path := strings.TrimPrefix(*host, "unix://")

	hc := &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		}},
	}
	resp, err := hc.Get("http://docker/info")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot read the info of %s: %v\n", *host, err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	var info struct {
		DefaultRuntime string
		Runtimes       map[string]json.RawMessage
	}
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&info) != nil {
		fmt.Fprintf(os.Stderr, "%s did not answer as a Docker daemon (HTTP %d)\n", *host, resp.StatusCode)
		os.Exit(1)
	}

	names := []string{}
	for n := range info.Runtimes {
		names = append(names, n)
	}
	sort.Strings(names)
	json.NewEncoder(os.Stdout).Encode(map[string]any{"host": *host, "default_runtime": info.DefaultRuntime, "runtimes": names})
}
