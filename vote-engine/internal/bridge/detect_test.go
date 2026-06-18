package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseLibraryFolders(t *testing.T) {
	body := `"libraryfolders"
{
	"0"
	{
		"path"		"/home/u/.local/share/Steam"
	}
	"1"
	{
		"path"		"/mnt/games\\SteamLibrary"
	}
}
`
	got := parseLibraryFolders(body)
	if len(got) != 2 {
		t.Fatalf("got %d paths: %v", len(got), got)
	}
	if got[0] != "/home/u/.local/share/Steam" {
		t.Fatalf("path0 = %q", got[0])
	}
	if got[1] != `/mnt/games\SteamLibrary` { // VDF \\ unescaped to \
		t.Fatalf("path1 = %q", got[1])
	}
}

func TestValidateAndScanSteamLibrary(t *testing.T) {
	root := t.TempDir()
	inst := filepath.Join(root, "steamapps", "common", "Subnautica2")
	if err := os.MkdirAll(filepath.Join(inst, filepath.FromSlash(RelWin64)), 0o755); err != nil {
		t.Fatal(err)
	}
	if !validateGameDir(inst) {
		t.Fatal("a dir with Subnautica2/Binaries/Win64 should validate")
	}
	if validateGameDir(filepath.Join(root, "nope")) {
		t.Fatal("a missing dir should not validate")
	}
	got := scanSteamLibrary(root)
	if len(got) != 1 || filepath.Base(got[0]) != "Subnautica2" {
		t.Fatalf("scanSteamLibrary = %v", got)
	}
}

func TestDedup(t *testing.T) {
	got := dedup([]string{"a", "", "a", "b", "b", "c"})
	if len(got) != 3 || got[0] != "a" || got[1] != "b" || got[2] != "c" {
		t.Fatalf("dedup = %v", got)
	}
}
