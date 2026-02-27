package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/noperator/cagent/pkg/cagent"
)

func main() {
	noUpdate := flag.Bool("no-update", false, "skip checking for updates")
	reset := flag.String("reset", "", "remove cagent state and exit (c=containers, i=image, v=volume, d=directory; omit value for all)")
	flag.Parse()

	if isFlagPassed("reset") {
		if err := cagent.Reset(*reset); err != nil {
			fmt.Fprintf(os.Stderr, "cagent: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := cagent.Run(*noUpdate, flag.Args()); err != nil {
		fmt.Fprintf(os.Stderr, "cagent: %v\n", err)
		os.Exit(1)
	}
}

func isFlagPassed(name string) bool {
	found := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == name {
			found = true
		}
	})
	return found
}
