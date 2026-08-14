// Command module-proxy-zip creates a canonical Go module proxy zip.
//
// The Go module zip format has rules that are stricter than a general-purpose
// zip archive: paths carry a module@version prefix, nested modules and vendor
// trees are omitted, and irregular files such as symlinks are ignored.  Keep
// those rules in the build by delegating to the same implementation used by
// the Go module tooling.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/mod/module"
	modzip "golang.org/x/mod/zip"
)

func main() {
	modulePath := flag.String("module", "", "module path")
	version := flag.String("version", "", "canonical module version")
	directory := flag.String("dir", "", "module source directory")
	output := flag.String("output", "", "output zip path")
	flag.Parse()

	if *modulePath == "" || *version == "" || *directory == "" || *output == "" {
		flag.Usage()
		os.Exit(2)
	}

	archive, err := os.OpenFile(*output, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		fatal(err)
	}

	moduleVersion := module.Version{Path: *modulePath, Version: *version}
	err = modzip.CreateFromDir(archive, moduleVersion, filepath.Clean(*directory))
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "module-proxy-zip: %v\n", err)
	os.Exit(1)
}
