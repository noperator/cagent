package cagent

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type mount struct {
	hostPath      string
	containerPath string
	empty         bool // true = shadow with empty file/dir
}

type mounts struct {
	items []mount
}

// scan walks workspaceDir and applies ignore/readonly patterns from cfg.
// Returns the full set of overlay mounts to pass to docker run.
func scan(workspaceDir string, cfg *config) (*mounts, error) {
	// Create temp empty file and dir for shadowing ignored paths.
	// Not cleaned up: syscall.Exec replaces this process so defers won't
	// run, and the OS handles /tmp cleanup.
	tmpDir, err := os.MkdirTemp("", "cagent-")
	if err != nil {
		return nil, err
	}

	emptyFile := filepath.Join(tmpDir, "empty-file")
	if err := os.WriteFile(emptyFile, nil, 0444); err != nil {
		return nil, err
	}

	emptyDir := filepath.Join(tmpDir, "empty-dir")
	if err := os.Mkdir(emptyDir, 0555); err != nil {
		return nil, err
	}

	var m mounts
	var excludedDirs []string

	err = filepath.WalkDir(workspaceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip entries we can't read
		}

		relPath, err := filepath.Rel(workspaceDir, path)
		if err != nil {
			return nil
		}

		// Skip the workspace root itself.
		if relPath == "." {
			return nil
		}

		// Skip if inside an already-excluded directory.
		if isInsideExcludedDir(relPath, excludedDirs) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		name := d.Name()

		// Check ignore patterns first (takes precedence).
		if matchesAny(relPath, name, cfg.Ignore) {
			if d.IsDir() {
				excludedDirs = append(excludedDirs, relPath+"/")
				m.items = append(m.items, mount{
					hostPath:      emptyDir,
					containerPath: "/workspace/" + relPath,
					empty:         true,
				})
				return fs.SkipDir
			}
			m.items = append(m.items, mount{
				hostPath:      emptyFile,
				containerPath: "/workspace/" + relPath,
				empty:         true,
			})
			return nil
		}

		// Check readonly patterns.
		if matchesAny(relPath, name, cfg.Readonly) {
			m.items = append(m.items, mount{
				hostPath:      filepath.Join(workspaceDir, relPath),
				containerPath: "/workspace/" + relPath,
				empty:         false,
			})
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		return nil
	})
	if err != nil {
		return nil, err
	}

	return &m, nil
}

func isInsideExcludedDir(relPath string, excludedDirs []string) bool {
	for _, dir := range excludedDirs {
		if strings.HasPrefix(relPath, dir) {
			return true
		}
	}
	return false
}

// matchesAny checks if a path matches any of the given patterns.
// Path-based patterns (containing /) match against the full relative path.
// Name-based patterns match against just the filename.
func matchesAny(relPath, name string, patterns []string) bool {
	for _, pattern := range patterns {
		if strings.Contains(pattern, "/") {
			if matched, _ := filepath.Match(pattern, relPath); matched {
				return true
			}
		} else {
			if matched, _ := filepath.Match(pattern, name); matched {
				return true
			}
		}
	}
	return false
}
