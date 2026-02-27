package cagent

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
)

func hasSysbox() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	out, err := exec.Command("docker", "info").Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "sysbox-runc")
}

// buildArgs constructs the full argument list for docker run.
// passthrough args are appended after the image name as the container command.
func buildArgs(workspaceDir string, m *mounts, cfg *config, passthrough []string) ([]string, error) {
	sysbox := hasSysbox()

	args := []string{"run", "-it", "--rm"}

	if sysbox {
		args = append(args, "--runtime=sysbox-runc", "-e", "CAGENT_DIND=1")
	}

	args = append(args,
		"--cap-drop=SETPCAP",
		"--cap-drop=SETFCAP",
		"--cap-add=NET_ADMIN",
		"--cap-add=NET_RAW",
		"-v", workspaceDir+":/workspace",
	)

	// Add overlay mounts. Readonly first, then shadows (shadows must come
	// after to override).
	for _, mt := range m.items {
		if !mt.empty {
			args = append(args, "-v", mt.hostPath+":"+mt.containerPath+":ro")
		}
	}
	for _, mt := range m.items {
		if mt.empty {
			args = append(args, "-v", mt.hostPath+":"+mt.containerPath+":ro")
		}
	}

	args = append(args, "-v", "cagent-home:/home/cagent")

	// Write merged domains list to a temp file and mount it where
	// firewall.sh expects it.
	domainsFile, err := writeDomains(cfg.Domains)
	if err != nil {
		return nil, err
	}
	args = append(args, "-v", domainsFile+":/usr/local/etc/domains.txt:ro")

	// Extra args from config.
	args = append(args, cfg.ExtraArgs...)

	// Image name.
	args = append(args, imageName)

	// Passthrough args (non-flag arguments to cagent binary).
	args = append(args, passthrough...)

	return args, nil
}

// writeDomains writes the domains list to a temp file and returns its path.
// The file is not cleaned up — syscall.Exec replaces this process and the
// OS handles /tmp cleanup.
func writeDomains(domains []string) (string, error) {
	if len(domains) == 0 {
		return "", fmt.Errorf("domains list is empty — add domains to ~/.cagent/config.yaml")
	}
	f, err := os.CreateTemp("", "cagent-domains-")
	if err != nil {
		return "", fmt.Errorf("create domains temp file: %w", err)
	}
	defer f.Close()
	for _, d := range domains {
		fmt.Fprintln(f, d)
	}
	return f.Name(), nil
}

// execDocker replaces the current process with docker run.
func execDocker(args []string) error {
	dockerPath, err := exec.LookPath("docker")
	if err != nil {
		return fmt.Errorf("docker not found in PATH: %w", err)
	}

	argv := append([]string{"docker"}, args...)
	return syscall.Exec(dockerPath, argv, os.Environ())
}
