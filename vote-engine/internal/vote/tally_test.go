package vote

import (
	"math/rand"
	"testing"
)

func TestParseVote(t *testing.T) {
	cases := []struct {
		in   string
		n    int
		want int
		ok   bool
	}{
		{"1", 4, 0, true},
		{"4", 4, 3, true},
		{"1!", 4, 0, true},
		{"3 chaos", 4, 2, true},
		{"  2  ", 4, 1, true},
		{"vote 1", 4, 0, false},
		{"1a", 4, 0, false},
		{"0", 4, 0, false},
		{"5", 4, 0, false},
		{"", 4, 0, false},
		{"abc", 4, 0, false},
		{"12", 4, 0, false},
		{"2", 2, 1, true},
		{"3", 2, 0, false},
	}
	for _, c := range cases {
		got, ok := ParseVote(c.in, c.n)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("ParseVote(%q,%d) = (%d,%v); want (%d,%v)", c.in, c.n, got, ok, c.want, c.ok)
		}
	}
}

func TestRoundFirstVoteWins(t *testing.T) {
	r := NewRound(4)
	if !r.Cast("u1", 0) {
		t.Fatal("first cast should record")
	}
	if r.Cast("u1", 1) {
		t.Fatal("second cast for same key must be ignored")
	}
	if !r.Cast("u2", 0) {
		t.Fatal("distinct key should record")
	}
	if r.Cast("u3", 9) {
		t.Fatal("out-of-range index must be rejected")
	}
	counts := r.Counts()
	if counts[0] != 2 || counts[1] != 0 {
		t.Fatalf("counts = %v; want [2 0 0 0]", counts)
	}
	if r.Total() != 2 {
		t.Fatalf("total = %d; want 2", r.Total())
	}
}

func TestResolve(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	if w := Resolve([]int{1, 5, 2, 0}, rng); w != 1 {
		t.Fatalf("clear winner = %d; want 1", w)
	}
	for i := 0; i < 50; i++ {
		if w := Resolve([]int{0, 0, 0, 0}, rng); w < 0 || w > 3 {
			t.Fatalf("zero-vote winner %d out of range", w)
		}
		if w := Resolve([]int{3, 3, 0, 0}, rng); w != 0 && w != 1 {
			t.Fatalf("tie winner %d not among tied {0,1}", w)
		}
	}
}
