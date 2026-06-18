//go:build linux

package bridge

import (
	"os"
	"path/filepath"
)

func detectGameDirs() []string {
	home, _ := os.UserHomeDir()
	return scanRootsAndLibraries([]string{
		os.Getenv("STEAM_ROOT"),
		filepath.Join(home, ".local", "share", "Steam"),
		filepath.Join(home, ".steam", "steam"),
		filepath.Join(home, ".steam", "root"),
	})
}
