package vote

import (
	"math/rand"
	"strconv"
	"strings"
)

// ParseVote extracts a 0-based option index from a chat message. A vote is the
// LEADING number 1..n (so "1", "1!", "3 chaos" count; "vote 1" and "1a" do not).
// Returns (index, true) on a valid vote.
func ParseVote(text string, n int) (int, bool) {
	s := strings.TrimSpace(text)
	if s == "" {
		return 0, false
	}
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 {
		return 0, false // no leading digit
	}
	if i < len(s) { // a letter immediately after the number is ambiguous -> reject
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			return 0, false
		}
	}
	num, err := strconv.Atoi(s[:i])
	if err != nil || num < 1 || num > n {
		return 0, false
	}
	return num - 1, true
}

// Round accumulates votes for a single voting window. One vote per key
// (platform+userID); the first valid vote wins.
type Round struct {
	n     int
	votes map[string]int // key -> 0-based option index
}

// NewRound creates a round expecting n options.
func NewRound(n int) *Round {
	return &Round{n: n, votes: make(map[string]int)}
}

// Cast records a vote. Returns false if the index is out of range or the key
// already voted this round.
func (r *Round) Cast(key string, idx int) bool {
	if idx < 0 || idx >= r.n {
		return false
	}
	if _, ok := r.votes[key]; ok {
		return false
	}
	r.votes[key] = idx
	return true
}

// Counts returns per-option vote counts (length n).
func (r *Round) Counts() []int {
	c := make([]int, r.n)
	for _, idx := range r.votes {
		if idx >= 0 && idx < r.n {
			c[idx]++
		}
	}
	return c
}

// Total returns the number of distinct voters.
func (r *Round) Total() int { return len(r.votes) }

// Resolve returns the winning option index. Ties are broken uniformly at
// random; with zero votes a random option is chosen so the game always advances.
func Resolve(counts []int, rng *rand.Rand) int {
	if len(counts) == 0 {
		return 0
	}
	total, max := 0, -1
	for _, c := range counts {
		total += c
		if c > max {
			max = c
		}
	}
	if total == 0 {
		return rng.Intn(len(counts))
	}
	tied := make([]int, 0, len(counts))
	for i, c := range counts {
		if c == max {
			tied = append(tied, i)
		}
	}
	if len(tied) == 1 {
		return tied[0]
	}
	return tied[rng.Intn(len(tied))]
}
