#!/bin/bash
# Reference solution of q37420728: the container keeps the stdout and stderr runc gives it. With CombinedOutput those are the write ends of a pipe of the program: the call returns only when
# every holder of the pipe has closed it, and the container (which runc leaves running, detached) is one, so it never returns; and when the program exits the pipe breaks and the service
# dies at its next write. A file (an *os.File: no pipe, no copying goroutine) is not shared that way: Run returns when runc exits, and the container writes into service.log on its own.
# runc's own messages go to the same file, so the program reads them from there when runc fails.
set -e
L=/var/lib/bench37420728
sudo tee "$L/src/main.go" >/dev/null <<'GOEOF'
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

// runner RUNC ROOT BUNDLE ID [HOLD_SECONDS]: starts the container ID of BUNDLE detached with RUNC (state directory ROOT) and says how long that took;
// with HOLD_SECONDS it then stays alive that long (a test driver that goes on to do other work).
func main() {
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: runner RUNC ROOT BUNDLE ID [HOLD_SECONDS]")
		os.Exit(2)
	}
	runc, root, bundle, id := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	// the container keeps the stdout and stderr runc gives it: a pipe of this program would stay open (CombinedOutput waits for it to close) and would break when this
	// program exits, a file does neither; runc's own messages land in the same file
	logf, err := os.OpenFile(filepath.Join(bundle, "service.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	offset, _ := logf.Seek(0, io.SeekEnd)
	command := exec.Command(runc, "--root", root, "run", "-d", id)
	command.Dir = bundle
	command.Stdout, command.Stderr = logf, logf
	start := time.Now()
	err = command.Run()
	duration := int64(time.Since(start) / time.Millisecond)
	fmt.Println(duration)
	fmt.Println(err)
	if err != nil {
		if f, e := os.Open(filepath.Join(bundle, "service.log")); e == nil {
			f.Seek(offset, io.SeekStart)
			msg, _ := io.ReadAll(f)
			fmt.Println(string(msg))
		}
		os.Exit(1)
	}
	if len(os.Args) > 5 {
		if hold, e := strconv.Atoi(os.Args[5]); e == nil {
			time.Sleep(time.Duration(hold) * time.Second)
		}
	}
}
GOEOF
sudo "$L/bin/build"
