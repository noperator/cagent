package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/noperator/cagent/pkg/cagent"
)

func main() {
	noUpdate := flag.Bool("no-update", false, "skip checking for updates")
	flag.Parse()

	if err := cagent.Run(*noUpdate, flag.Args()); err != nil {
		fmt.Fprintf(os.Stderr, "cagent: %v\n", err)
		os.Exit(1)
	}
}
