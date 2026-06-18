package chat

import (
	"context"
	"fmt"
	"math/rand"
	"time"
)

// FakeSource emits synthetic votes for --simulate and tests. A pool of fake
// viewers each send a random "1".."N" at a steady interval, exercising the
// whole pipeline with no network. Votes outside a voting window are simply
// ignored by the machine, exactly like real chat.
type FakeSource struct {
	Voters   int           // size of the fake viewer pool
	Options  int           // N — votes are "1".."N"
	Interval time.Duration // delay between synthetic messages
	Seed     int64         // 0 => time-seeded
}

// Name implements Source.
func (f *FakeSource) Name() string { return "simulate" }

// Run implements Source.
func (f *FakeSource) Run(ctx context.Context, out chan<- Message) error {
	voters := f.Voters
	if voters <= 0 {
		voters = 50
	}
	n := f.Options
	if n <= 0 {
		n = 4
	}
	interval := f.Interval
	if interval <= 0 {
		interval = 150 * time.Millisecond
	}
	seed := f.Seed
	if seed == 0 {
		seed = time.Now().UnixNano()
	}
	rng := rand.New(rand.NewSource(seed))

	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			uid := fmt.Sprintf("sim%d", rng.Intn(voters))
			choice := rng.Intn(n) + 1
			msg := Message{
				Platform: "sim",
				UserID:   uid,
				Username: uid,
				Text:     fmt.Sprintf("%d", choice),
				TS:       time.Now(),
			}
			select {
			case out <- msg:
			case <-ctx.Done():
				return nil
			}
		}
	}
}
