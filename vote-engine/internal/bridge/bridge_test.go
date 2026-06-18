package bridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWriterAtomicAndSkipIdentical(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "chaos_state.json")
	w, err := NewWriter(p)
	if err != nil {
		t.Fatal(err)
	}

	st := State{SchemaVersion: 1, Round: 1, Phase: PhaseVoting, Tallies: []int{1, 2, 3, 4}}
	changed, err := w.Write(st)
	if err != nil || !changed {
		t.Fatalf("first write: changed=%v err=%v", changed, err)
	}

	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var got State
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("written file is not complete JSON: %v", err)
	}
	if got.Round != 1 || len(got.Tallies) != 4 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}

	if changed, _ := w.Write(st); changed {
		t.Fatal("identical write should be skipped")
	}
	st.Round = 2
	if changed, _ := w.Write(st); !changed {
		t.Fatal("changed write should not be skipped")
	}
	if _, err := os.Stat(p + ".tmp"); !os.IsNotExist(err) {
		t.Fatal("temp file should not be left behind")
	}
}

func TestActive(t *testing.T) {
	if !Active(nil) {
		t.Fatal("nil status should be active (headless)")
	}
	if Active(&Status{GameplayActive: false}) {
		t.Fatal("inactive gameplay should not be active")
	}
	if !Active(&Status{GameplayActive: true}) {
		t.Fatal("active gameplay should be active")
	}
	if Active(&Status{GameplayActive: true, Paused: true}) {
		t.Fatal("paused should not be active")
	}
}

func TestReadStatusMissing(t *testing.T) {
	s, err := ReadStatus(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil || s != nil {
		t.Fatalf("missing status should be (nil,nil); got (%v,%v)", s, err)
	}
}

func TestResolvePaths(t *testing.T) {
	st, status, src, err := Resolve(PathOpts{BridgeFile: "/abs/chaos_state.json"})
	if err != nil || st != "/abs/chaos_state.json" || src == "" {
		t.Fatalf("bridgeFile resolution: %q %q %q %v", st, status, src, err)
	}
	if filepath.Base(status) != "chaos_status.json" {
		t.Fatalf("status path = %q; want sibling chaos_status.json", status)
	}
	st, _, _, err = Resolve(PathOpts{ModDir: "/m", ModName: "Sub2Chaos"})
	if err != nil || st != filepath.Join("/m", "chaos_state.json") {
		t.Fatalf("modDir resolution: %q %v", st, err)
	}
}
