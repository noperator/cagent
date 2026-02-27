package cagent

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	repoURL   = "https://github.com/noperator/cagent.git"
	apiURL    = "https://api.github.com/repos/noperator/cagent/commits/main"
	imageName = "cagent"
)

// Reset removes selected cagent state. components is a string of
// single-character codes: c=containers, i=image, v=volume, d=directory.
// Empty string means all components.
func Reset(components string) error {
	for _, r := range components {
		if !strings.ContainsRune("civd", r) {
			return fmt.Errorf("unknown reset component %q (valid: c=containers, i=image, v=volume, d=directory)", string(r))
		}
	}

	all := components == ""
	doC := all || strings.ContainsRune(components, 'c')
	doI := all || strings.ContainsRune(components, 'i')
	doV := all || strings.ContainsRune(components, 'v')
	doD := all || strings.ContainsRune(components, 'd')

	fmt.Fprintf(os.Stderr, "This will remove:\n")
	if doC {
		fmt.Fprintf(os.Stderr, "  c - all running cagent containers\n")
	}
	if doI {
		fmt.Fprintf(os.Stderr, "  i - the cagent Docker image\n")
	}
	if doV {
		fmt.Fprintf(os.Stderr, "  v - the cagent-home volume\n")
	}
	if doD {
		fmt.Fprintf(os.Stderr, "  d - ~/.cagent\n")
	}
	fmt.Fprintf(os.Stderr, "\nWorkspace .cagent.yaml files are not affected.\n\nContinue? [y/N] ")

	var response string
	fmt.Fscan(os.Stdin, &response)
	if response != "y" && response != "Y" {
		fmt.Fprintf(os.Stderr, "Aborted.\n")
		return nil
	}

	if doC {
		out, err := exec.Command("docker", "ps", "-q", "--filter", "ancestor="+imageName).Output()
		if err != nil {
			return fmt.Errorf("list containers: %w", err)
		}
		for _, id := range strings.Fields(string(out)) {
			if err := exec.Command("docker", "rm", "-f", id).Run(); err != nil {
				return fmt.Errorf("remove container %s: %w", id, err)
			}
		}
	}

	if doI {
		exec.Command("docker", "rmi", imageName).Run() // ignore error — may not exist
	}

	if doV {
		exec.Command("docker", "volume", "rm", "cagent-home").Run() // ignore error — may not exist
	}

	if doD {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("get home dir: %w", err)
		}
		if err := os.RemoveAll(filepath.Join(home, ".cagent")); err != nil {
			return fmt.Errorf("remove ~/.cagent: %w", err)
		}
	}

	fmt.Fprintf(os.Stderr, "Reset complete. Run cagent again to start fresh.\n")
	return nil
}

// cagentHome returns the path to ~/.cagent, creating it if necessary.
func cagentHome() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("get home dir: %w", err)
	}
	dir := filepath.Join(home, ".cagent")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", fmt.Errorf("create %s: %w", dir, err)
	}
	return dir, nil
}

// ensureRepo clones the repo to ~/.cagent/src if not present.
// Writes the current commit SHA to ~/.cagent/src/.commit after cloning.
func ensureRepo() (string, error) {
	home, err := cagentHome()
	if err != nil {
		return "", err
	}

	srcDir := filepath.Join(home, "src")
	gitDir := filepath.Join(srcDir, ".git")
	if _, err := os.Stat(gitDir); err == nil {
		return srcDir, nil // already cloned
	}

	fmt.Fprintf(os.Stderr, "Cloning cagent repo to %s...\n", srcDir)

	cmd := exec.Command("git", "clone", repoURL, srcDir)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git clone: %w", err)
	}

	if err := writeCommit(srcDir); err != nil {
		return "", err
	}

	fmt.Fprintf(os.Stderr, "Repo cloned to %s — edit %s to customize.\n",
		srcDir, filepath.Join(home, "config.yaml"))
	return srcDir, nil
}

// localCommit reads the SHA from <repoDir>/.commit.
func localCommit(repoDir string) (string, error) {
	data, err := os.ReadFile(filepath.Join(repoDir, ".commit"))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// remoteCommit fetches the latest commit SHA on main from the GitHub API.
func remoteCommit() (string, error) {
	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetch remote commit: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("github api returned %d", resp.StatusCode)
	}

	var result struct {
		SHA string `json:"sha"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}
	return result.SHA, nil
}

// update does a git pull in repoDir and updates .commit.
func update(repoDir string) error {
	cmd := exec.Command("git", "-C", repoDir, "pull", "--ff-only")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("git pull: %w", err)
	}
	return writeCommit(repoDir)
}

// ensureImage checks if the cagent Docker image exists locally.
// If not, builds it from repoDir.
func ensureImage(repoDir string) error {
	out, err := exec.Command("docker", "images", "-q", imageName).Output()
	if err != nil {
		return fmt.Errorf("check docker image: %w", err)
	}
	if strings.TrimSpace(string(out)) != "" {
		return nil // image exists
	}
	return buildImage(repoDir)
}

// buildImage runs docker build -t cagent <repoDir>.
func buildImage(repoDir string) error {
	fmt.Fprintf(os.Stderr, "Building cagent Docker image (this may take a few minutes)...\n")
	cmd := exec.Command("docker", "build", "-t", imageName, repoDir)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker build: %w", err)
	}
	fmt.Fprintf(os.Stderr, "Image built successfully.\n")
	return nil
}

// writeDefaultConfig writes ~/.cagent/config.yaml if it doesn't already exist,
// reading the template from ~/.cagent/src/config-default.yaml.
func writeDefaultConfig(cagentHomeDir string) error {
	dest := filepath.Join(cagentHomeDir, "config.yaml")
	if _, err := os.Stat(dest); err == nil {
		return nil // already exists, never overwrite
	}
	src := filepath.Join(cagentHomeDir, "src", "config-default.yaml")
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read default config: %w", err)
	}
	return os.WriteFile(dest, data, 0644)
}

func writeCommit(repoDir string) error {
	out, err := exec.Command("git", "-C", repoDir, "rev-parse", "HEAD").Output()
	if err != nil {
		return fmt.Errorf("get commit sha: %w", err)
	}
	sha := strings.TrimSpace(string(out))
	return os.WriteFile(filepath.Join(repoDir, ".commit"), []byte(sha+"\n"), 0644)
}

// isDirty returns true if the git repo at dir has uncommitted changes.
func isDirty(dir string) (bool, error) {
	out, err := exec.Command("git", "-C", dir, "status", "--porcelain").Output()
	if err != nil {
		return false, fmt.Errorf("git status: %w", err)
	}
	return len(strings.TrimSpace(string(out))) > 0, nil
}

// backupSrc copies srcDir to srcDir.<timestamp>.bak.
func backupSrc(srcDir string) error {
	timestamp := time.Now().Format("20060102-150405")
	dest := srcDir + "." + timestamp + ".bak"
	fsys := os.DirFS(srcDir)
	if err := os.MkdirAll(dest, 0755); err != nil {
		return fmt.Errorf("create backup dir: %w", err)
	}
	if err := copyFS(dest, fsys); err != nil {
		return fmt.Errorf("backup src: %w", err)
	}
	fmt.Fprintf(os.Stderr, "Backed up %s to %s\n", srcDir, dest)
	return nil
}

// copyFS copies all files from src into destDir, preserving structure.
func copyFS(destDir string, src fs.FS) error {
	return fs.WalkDir(src, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		dest := filepath.Join(destDir, path)
		if d.IsDir() {
			return os.MkdirAll(dest, 0755)
		}
		data, err := fs.ReadFile(src, path)
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		return os.WriteFile(dest, data, info.Mode())
	})
}
