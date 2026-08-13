package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	url := flag.String("url", "", "endpoint to probe")
	flag.Parse()
	if *url == "" { fmt.Fprintln(os.Stderr, "-url is required"); os.Exit(2) }
	c := http.Client{Timeout: 2 * time.Second}
	r, err := c.Get(*url)
	if err != nil || r.StatusCode < 200 || r.StatusCode >= 400 { if r != nil { r.Body.Close() }; os.Exit(1) }
	r.Body.Close()
}
