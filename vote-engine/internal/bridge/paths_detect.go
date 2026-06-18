package bridge

import "errors"

// autoDetectGameDir locates the Subnautica 2 install root with no config.
// The real Steam-library detection (registry on Windows, libraryfolders.vdf on
// Linux) lands in build-tagged files; this default keeps the build green and
// directs the user to pass an explicit path.
func autoDetectGameDir() (string, error) {
	return "", errors.New("Steam auto-detection not available on this platform")
}
