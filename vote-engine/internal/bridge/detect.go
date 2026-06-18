package bridge

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// Steam install discovery for Subnautica 2. Logic adapted from sub2_random's
// Go installer (stdlib-only). The per-OS root lists live in build-tagged files;
// the shared scanning/parsing lives here.

// gameDirNames are the directory names Steam may use for the SN2 install under
// steamapps/common.
var gameDirNames = []string{"Subnautica2", "Subnautica 2"}

// autoDetectGameDir returns the single detected SN2 install root, or an error if
// none or several are found (the caller should then pass --game-dir).
func autoDetectGameDir() (string, error) {
	dirs := detectGameDirs()
	switch len(dirs) {
	case 0:
		return "", errors.New("no Subnautica 2 install found")
	case 1:
		return dirs[0], nil
	default:
		return "", fmt.Errorf("multiple Subnautica 2 installs found %v — pass --game-dir", dirs)
	}
}

func scanSteamLibrary(steamRoot string) []string {
	out := []string{}
	if steamRoot == "" {
		return out
	}
	common := filepath.Join(steamRoot, "steamapps", "common")
	for _, name := range gameDirNames {
		candidate := filepath.Join(common, name)
		if validateGameDir(candidate) {
			out = append(out, absPath(candidate))
		}
	}
	return out
}

// validateGameDir checks that candidate looks like an SN2 install root, i.e. it
// contains the nested Subnautica2/Binaries/Win64 directory.
func validateGameDir(candidate string) bool {
	return isDir(candidate) && isDir(filepath.Join(candidate, filepath.FromSlash(RelWin64)))
}

var vdfPathRE = regexp.MustCompile(`(?m)^\s*"path"\s+"((?:[^"\\]|\\.)*)"\s*$`)

func parseLibraryFolders(body string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, m := range vdfPathRE.FindAllStringSubmatch(body, -1) {
		path := unescapeVDF(m[1])
		if seen[path] {
			continue
		}
		seen[path] = true
		out = append(out, path)
	}
	return out
}

func unescapeVDF(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			out = append(out, s[i+1])
			i++
			continue
		}
		out = append(out, s[i])
	}
	return string(out)
}

func readLibraryFolders(steamRoot string) []string {
	body, err := os.ReadFile(filepath.Join(steamRoot, "steamapps", "libraryfolders.vdf"))
	if err != nil {
		return nil
	}
	return parseLibraryFolders(string(body))
}

func dedup(in []string) []string {
	out := make([]string, 0, len(in))
	seen := map[string]bool{}
	for _, s := range in {
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

func isDir(p string) bool {
	if p == "" {
		return false
	}
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func absPath(p string) string {
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}

// scanRootsAndLibraries scans each root directly, then any extra libraries
// listed in its libraryfolders.vdf. Shared by the per-OS detectGameDirs.
func scanRootsAndLibraries(roots []string) []string {
	roots = dedup(roots)
	candidates := []string{}
	for _, r := range roots {
		candidates = append(candidates, scanSteamLibrary(r)...)
	}
	for _, r := range roots {
		for _, lib := range readLibraryFolders(r) {
			candidates = append(candidates, scanSteamLibrary(lib)...)
		}
	}
	return dedup(candidates)
}
