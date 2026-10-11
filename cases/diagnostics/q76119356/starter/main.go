// rtinfo: print the default runtime and the runtimes of the Docker daemon behind a Docker endpoint.
//
//	rtinfo --host unix:///path/to/docker.sock
//
// It prints one JSON object: {"host":..., "default_runtime":..., "runtimes":[...]}.
package main

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	host := flag.String("host", "", "Docker daemon endpoint, e.g. unix:///var/run/docker.sock")
	flag.Parse()

	// the runtime configuration: what the dockerd process of this machine was started with
	def, runtimes := "runc", map[string]bool{"runc": true}
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		raw, err := os.ReadFile("/proc/" + e.Name() + "/cmdline")
		if err != nil || len(raw) == 0 {
			continue
		}
		args := strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
		if filepath.Base(args[0]) != "dockerd" {
			continue
		}
		for i, a := range args {
			switch {
			case a == "--default-runtime" && i+1 < len(args):
				def = args[i+1]
			case strings.HasPrefix(a, "--default-runtime="):
				def = strings.TrimPrefix(a, "--default-runtime=")
			case a == "--add-runtime" && i+1 < len(args):
				runtimes[strings.SplitN(args[i+1], "=", 2)[0]] = true
			case strings.HasPrefix(a, "--add-runtime="):
				runtimes[strings.SplitN(strings.TrimPrefix(a, "--add-runtime="), "=", 2)[0]] = true
			}
		}
		break
	}
	names := []string{}
	for n := range runtimes {
		names = append(names, n)
	}
	sort.Strings(names)
	json.NewEncoder(os.Stdout).Encode(map[string]any{"host": *host, "default_runtime": def, "runtimes": names})
}
