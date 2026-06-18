package bridge

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Writer serializes State to a file atomically. It skips writes whose bytes are
// identical to the last one (avoids disk churn during static phases).
type Writer struct {
	path string
	last []byte
}

// NewWriter creates a Writer for the given chaos_state.json path, ensuring the
// containing directory exists.
func NewWriter(path string) (*Writer, error) {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	return &Writer{path: path}, nil
}

// Path returns the destination file path.
func (w *Writer) Path() string { return w.path }

// Write marshals v and atomically replaces the file. Returns (false, nil) when
// the content is unchanged since the last write.
func (w *Writer) Write(v any) (bool, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return false, err
	}
	if w.last != nil && bytesEqual(w.last, data) {
		return false, nil
	}
	if err := writeAtomic(w.path, data); err != nil {
		return false, err
	}
	w.last = data
	return true, nil
}

// writeAtomic writes data to a temp file in the SAME directory then renames it
// over the target. The temp file MUST be on the same filesystem as the target,
// so we never use os.TempDir(): under Proton/Wine that lands on a different FS
// and the cross-device rename fails (the exact hazard sub2_random documents in
// debug_bridge.lua). On Windows, rename-over-existing can fail, so we remove the
// target and retry.
func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(path)
		if err2 := os.Rename(tmp, path); err2 != nil {
			_ = os.Remove(tmp)
			return err2
		}
	}
	return nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
