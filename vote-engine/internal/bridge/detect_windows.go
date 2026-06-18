//go:build windows

package bridge

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func detectGameDirs() []string {
	roots := []string{
		os.Getenv("STEAM_ROOT"),
		filepath.Join(os.Getenv("ProgramFiles(x86)"), "Steam"),
		filepath.Join(os.Getenv("ProgramFiles"), "Steam"),
	}
	if reg := readSteamInstallPathFromRegistry(); reg != "" {
		roots = append(roots, reg)
	}
	return scanRootsAndLibraries(roots)
}

// readSteamInstallPathFromRegistry shells out to `reg query` (stdlib-only, no
// golang.org/x/sys dependency).
func readSteamInstallPathFromRegistry() string {
	out, err := exec.Command("reg", "query",
		`HKLM\SOFTWARE\WOW6432Node\Valve\Steam`, "/v", "InstallPath").Output()
	if err != nil {
		out, err = exec.Command("reg", "query",
			`HKLM\SOFTWARE\Valve\Steam`, "/v", "InstallPath").Output()
		if err != nil {
			return ""
		}
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "InstallPath") {
			continue
		}
		if parts := strings.SplitN(line, "REG_SZ", 2); len(parts) == 2 {
			return strings.TrimSpace(parts[1])
		}
	}
	return ""
}
