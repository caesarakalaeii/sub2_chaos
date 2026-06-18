package bridge

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Game-relative locations under a Subnautica 2 install root.
const (
	RelWin64 = "Subnautica2/Binaries/Win64"
	RelMods  = RelWin64 + "/ue4ss/Mods"
)

const (
	stateFileName  = "chaos_state.json"
	statusFileName = "chaos_status.json"
)

// PathOpts is the bridge-path resolution input (from config/flags).
type PathOpts struct {
	BridgeFile       string // absolute path to chaos_state.json (highest precedence)
	StatusFile       string // absolute path to chaos_status.json
	ModDir           string // absolute path to the mod folder
	GameDir          string // absolute SN2 install root
	ModName          string // folder under ue4ss/Mods (e.g. "Sub2Chaos")
	UseDiscoveryFile bool   // try the mod-written discovery file
}

// Resolve determines the chaos_state.json and chaos_status.json paths, in order:
// explicit bridge file -> mod dir -> game dir -> discovery file -> auto-detect.
// It returns the resolved paths and a short description of which source won.
func Resolve(o PathOpts) (statePath, statusPath, source string, err error) {
	modName := o.ModName
	if modName == "" {
		modName = "Sub2Chaos"
	}

	switch {
	case o.BridgeFile != "":
		statePath = o.BridgeFile
		source = "bridgeFile flag/config"
	case o.ModDir != "":
		statePath = filepath.Join(o.ModDir, stateFileName)
		source = "modDir flag/config"
	case o.GameDir != "":
		statePath = filepath.Join(o.GameDir, filepath.FromSlash(RelMods), modName, stateFileName)
		source = "gameDir flag/config"
	default:
		if env := os.Getenv("GAME_DIR"); env != "" {
			statePath = filepath.Join(env, filepath.FromSlash(RelMods), modName, stateFileName)
			source = "$GAME_DIR"
			break
		}
		if o.UseDiscoveryFile {
			if md, derr := ReadDiscovery(); derr == nil && md != "" {
				statePath = filepath.Join(md, stateFileName)
				source = "discovery file"
				break
			}
		}
		gd, derr := autoDetectGameDir()
		if derr != nil {
			return "", "", "", fmt.Errorf("bridge: could not resolve game path: %w "+
				"(pass --game-dir, --mod-dir or --bridge-file)", derr)
		}
		statePath = filepath.Join(gd, filepath.FromSlash(RelMods), modName, stateFileName)
		source = "auto-detected Steam install"
	}

	if o.StatusFile != "" {
		statusPath = o.StatusFile
	} else {
		statusPath = filepath.Join(filepath.Dir(statePath), statusFileName)
	}
	return statePath, statusPath, source, nil
}

// DiscoveryPath is the well-known file the mod writes its absolute mod-folder
// path to, letting the engine find the bridge with zero config.
func DiscoveryPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "sub2_chaos", "bridge_path.txt"), nil
}

// ReadDiscovery reads the mod-written discovery file and returns the mod folder.
func ReadDiscovery() (string, error) {
	p, err := DiscoveryPath()
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
