package cagent

import (
	"fmt"
	"os"
	"path/filepath"
)

// Run is the main entry point called from cmd/cagent/main.go.
// passthrough args are forwarded as the container command.
func Run(noUpdate bool, passthrough []string) error {
	repoDir, err := ensureRepo()
	if err != nil {
		return err
	}

	// Write default config if it doesn't exist yet. Safe to call every run.
	// Must run after ensureRepo — reads config-default.yaml from the cloned repo.
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("get home dir: %w", err)
	}
	cagentDir := filepath.Join(home, ".cagent")
	if err := writeDefaultConfig(cagentDir); err != nil {
		return err
	}

	if !noUpdate {
		if err := checkAndUpdate(repoDir); err != nil {
			// Non-fatal: warn and continue.
			fmt.Fprintf(os.Stderr, "Warning: update check failed: %v\n", err)
		}
	}

	if err := ensureImage(repoDir); err != nil {
		return err
	}

	workspaceDir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}

	cfg, err := loadConfig(workspaceDir)
	if err != nil {
		return err
	}

	m, err := scan(workspaceDir, cfg)
	if err != nil {
		return err
	}

	args, err := buildArgs(workspaceDir, m, cfg, passthrough)
	if err != nil {
		return err
	}
	return execDocker(args)
}

func checkAndUpdate(repoDir string) error {
	remote, err := remoteCommit()
	if err != nil {
		return err
	}

	local, err := localCommit(repoDir)
	if err != nil {
		return err
	}

	if remote == local {
		return nil
	}

	dirty, err := isDirty(repoDir)
	if err != nil {
		return err
	}
	if dirty {
		if err := backupSrc(repoDir); err != nil {
			return err
		}
	}

	fmt.Fprintf(os.Stderr, "Updating to %s...\n", remote[:7])
	if err := update(repoDir); err != nil {
		return err
	}

	return buildImage(repoDir)
}
