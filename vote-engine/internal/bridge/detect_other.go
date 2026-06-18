//go:build !linux && !windows

package bridge

// detectGameDirs has no auto-detection on platforms other than Linux/Windows;
// users pass --game-dir / --mod-dir / --bridge-file explicitly.
func detectGameDirs() []string { return nil }
