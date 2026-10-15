// probe NAME [DNSADDR] : what a registry client of Docker sees from inside a container, with the resolver of the Go runtime (the one dockerd uses): resolve NAME, connect to NAME:443, check
// the certificate with the CA in /etc/docker/certs.d/NAME/ca.crt and ask GET /v2/ . One line per stage, "dns ok ADDR", "dns FAIL error", "tcp ok" / "tcp FAIL error", "tls ok" / "tls FAIL
// error", "http ok 200". It stops at the first failed stage. With DNSADDR the name is not looked up in /etc/resolv.conf but at that server.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

func main() {
	name := os.Args[1]
	r := &net.Resolver{}
	if len(os.Args) > 2 {
		server := os.Args[2]
		r = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, network, server+":53")
		}}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	addrs, err := r.LookupHost(ctx, name)
	if err != nil || len(addrs) == 0 {
		fmt.Printf("dns FAIL %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("dns ok %s\n", addrs[0])
	conn, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "tcp", net.JoinHostPort(addrs[0], "443"))
	if err != nil {
		fmt.Printf("tcp FAIL %v\n", err)
		os.Exit(1)
	}
	fmt.Println("tcp ok")
	pool := x509.NewCertPool()
	pem, _ := os.ReadFile("/etc/docker/certs.d/" + name + "/ca.crt")
	pool.AppendCertsFromPEM(pem)
	tc := tls.Client(conn, &tls.Config{ServerName: name, RootCAs: pool})
	if err := tc.HandshakeContext(ctx); err != nil {
		fmt.Printf("tls FAIL %v\n", err)
		os.Exit(1)
	}
	fmt.Println("tls ok")
	req, _ := http.NewRequest("GET", "https://"+name+"/v2/", nil)
	req.Write(tc)
	resp, err := http.ReadResponse(bufio.NewReader(tc), req)
	if err != nil {
		fmt.Printf("http FAIL %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("http ok %d\n", resp.StatusCode)
}
