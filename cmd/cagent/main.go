package main

import (
	"fmt"
	"os"

	flag "github.com/spf13/pflag"

	"github.com/noperator/cagent/pkg/cagent"
)

func main() {
	noUpdate := flag.Bool("no-update", false, "skip checking for updates")
	reset := flag.String("reset", "", "remove cagent state and exit (c=containers, i=image, v=volume, d=directory; omit for all)")
	flag.Lookup("reset").NoOptDefVal = "civd"
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "cagent: Agent in a cage.\n\n")
		fmt.Fprintf(os.Stderr, "Locks down the network and filesystem so an agent is free to explore\n")
		fmt.Fprintf(os.Stderr, "the mounted workspace while reducing the risk of it going off the rails.\n\n")
		fmt.Fprintf(os.Stderr, "Usage: cagent [options] [command...]\n\n")
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
	}
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
