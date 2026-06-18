// Command vote-engine ingests live chat, runs chaos vote rounds, writes the
// result to the bridge file the in-game mod reads, and serves the OBS overlay.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/bridge"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/catalog"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/chat"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/config"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/overlay"
	"github.com/caesarakalaeii/sub2_chaos/vote-engine/internal/vote"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("vote-engine: %v", err)
	}
}

func run() error {
	var (
		cfgPath       = flag.String("config", "config.yaml", "path to config.yaml")
		catalogPath   = flag.String("catalog", "", "override: path to events.json")
		simulate      = flag.Bool("simulate", false, "inject synthetic votes (no chat, no game)")
		bridgeFile    = flag.String("bridge-file", "", "override: absolute path to chaos_state.json")
		gameDir       = flag.String("game-dir", "", "override: SN2 install root")
		modDir        = flag.String("mod-dir", "", "override: mod folder")
		overlayPort   = flag.Int("overlay-port", 0, "override: overlay port")
		source        = flag.String("source", "", "override: twitch|allchat")
		twitchChannel = flag.String("twitch-channel", "", "override: twitch channel")
		allchatURL    = flag.String("allchat-url", "", "override: all-chat base URL")
		allchatUser   = flag.String("allchat-user", "", "override: all-chat streamer username")
		logLevel      = flag.String("log-level", "", "override: debug|info|warn|error")
		simVoters     = flag.Int("sim-voters", 60, "simulate: fake voter pool size")
		simRate       = flag.Duration("sim-rate", 120*time.Millisecond, "simulate: delay between fake votes")
	)
	flag.Parse()

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return err
	}
	applyOverrides(cfg, overrides{
		catalogPath: *catalogPath, bridgeFile: *bridgeFile, gameDir: *gameDir, modDir: *modDir,
		overlayPort: *overlayPort, source: *source, twitchChannel: *twitchChannel,
		allchatURL: *allchatURL, allchatUser: *allchatUser, logLevel: *logLevel,
	})

	logger := newLogger(cfg.Log.Level)

	if *simulate {
		if cfg.Overlay.Port <= 0 {
			cfg.Overlay.Port = 8777
		}
	} else if err := cfg.Validate(); err != nil {
		return err
	}
	for _, w := range cfg.Warnings() {
		logger("warn", "%s", w)
	}

	cat, err := catalog.Load(cfg.Catalog.Path)
	if err != nil {
		return err
	}
	logger("info", "catalog: %d events from %s", len(cat.Events), cfg.Catalog.Path)

	statePath, statusPath, src, err := bridge.Resolve(bridge.PathOpts{
		BridgeFile: cfg.Bridge.BridgeFile, StatusFile: cfg.Bridge.StatusFile,
		ModDir: cfg.Bridge.ModDir, GameDir: cfg.Bridge.GameDir,
		ModName: cfg.Bridge.ModName, UseDiscoveryFile: cfg.Bridge.UseDiscoveryFile,
	})
	if err != nil {
		return err
	}
	logger("info", "bridge: %s (resolved via %s)", statePath, src)
	writer, err := bridge.NewWriter(statePath)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var ov *overlay.Server
	if cfg.Overlay.Enabled {
		ov = overlay.New(cfg.Overlay.Bind, cfg.Overlay.Port)
		go func() {
			logger("info", "overlay: add this OBS browser source -> http://%s/overlay", ov.Addr())
			if err := ov.Run(ctx); err != nil {
				logger("error", "overlay: %v", err)
			}
		}()
	}

	m := vote.NewMachine(vote.Config{
		OptionsPerRound:      cfg.Vote.OptionsPerRound,
		VoteDuration:         cfg.Vote.VoteDuration(),
		Cooldown:             cfg.Vote.CooldownDuration(),
		ApplyHold:            cfg.Vote.ApplyHoldDuration(),
		AvoidImmediateRepeat: cfg.Vote.AvoidImmediateRepeat,
	}, cat, cfg.Vote.Seed)

	publish := func(st bridge.State) {
		if _, err := writer.Write(st); err != nil {
			logger("warn", "bridge write: %v", err)
		}
		if ov != nil {
			ov.Broadcast(st)
		}
	}

	active := make(chan bool, 1)
	go pollStatus(ctx, statusPath, active, logger)

	votes := make(chan chat.Message, 256)
	cs := buildSource(*simulate, cfg, *simVoters, *simRate, logger)
	go func() {
		logger("info", "chat: source=%s", cs.Name())
		if err := cs.Run(ctx, votes); err != nil {
			logger("error", "chat: %v", err)
		}
	}()

	tick := time.Second / time.Duration(maxInt(cfg.Bridge.WriteHz, 1))
	logger("info", "ready (mode=%s, options=%d, vote=%ds, cooldown=%ds)",
		srcMode(*simulate, cfg), cfg.Vote.OptionsPerRound, cfg.Vote.VoteDurationSeconds, cfg.Vote.CooldownSeconds)
	vote.Run(ctx, m, votes, active, tick, time.Now, publish)
	logger("info", "shutting down")
	return nil
}

type overrides struct {
	catalogPath, bridgeFile, gameDir, modDir       string
	source, twitchChannel, allchatURL, allchatUser string
	logLevel                                       string
	overlayPort                                    int
}

func applyOverrides(c *config.Config, o overrides) {
	if o.catalogPath != "" {
		c.Catalog.Path = o.catalogPath
	}
	if o.bridgeFile != "" {
		c.Bridge.BridgeFile = o.bridgeFile
	}
	if o.gameDir != "" {
		c.Bridge.GameDir = o.gameDir
	}
	if o.modDir != "" {
		c.Bridge.ModDir = o.modDir
	}
	if o.overlayPort != 0 {
		c.Overlay.Port = o.overlayPort
	}
	if o.source != "" {
		c.Source.Mode = o.source
	}
	if o.twitchChannel != "" {
		c.Source.Twitch.Channel = o.twitchChannel
	}
	if o.allchatURL != "" {
		c.Source.Allchat.BaseURL = o.allchatURL
	}
	if o.allchatUser != "" {
		c.Source.Allchat.StreamerUsername = o.allchatUser
	}
	if o.logLevel != "" {
		c.Log.Level = o.logLevel
	}
}

func buildSource(simulate bool, cfg *config.Config, voters int, rate time.Duration, logger logFn) chat.Source {
	if simulate {
		return &chat.FakeSource{Voters: voters, Options: cfg.Vote.OptionsPerRound, Interval: rate, Seed: cfg.Vote.Seed}
	}
	clog := func(f string, a ...any) { logger("info", f, a...) }
	switch cfg.Source.Mode {
	case "allchat":
		return chat.NewAllChat(chat.AllChatOpts{
			BaseURL: cfg.Source.Allchat.BaseURL, StreamerUsername: cfg.Source.Allchat.StreamerUsername,
			OverlayID: cfg.Source.Allchat.OverlayID, Token: cfg.Source.Allchat.Token, Logf: clog,
		})
	default:
		return chat.NewTwitchIRC(chat.TwitchOpts{
			Channel: cfg.Source.Twitch.Channel, Server: cfg.Source.Twitch.Server,
			UseTLS: cfg.Source.Twitch.UseTLS, RequestTags: cfg.Source.Twitch.RequestTags, Logf: clog,
		})
	}
}

// pollStatus reads chaos_status.json and pushes active-state changes to the
// machine's goroutine (so gameplay menus/pause halt voting).
func pollStatus(ctx context.Context, path string, active chan<- bool, logger logFn) {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	last := true
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			st, _ := bridge.ReadStatus(path)
			a := bridge.Active(st)
			if a != last {
				last = a
				logger("info", "gameplay active=%v", a)
				select {
				case active <- a:
				case <-ctx.Done():
					return
				}
			}
		}
	}
}

type logFn func(level, format string, a ...any)

func newLogger(level string) logFn {
	order := map[string]int{"debug": 0, "info": 1, "warn": 2, "error": 3}
	min, ok := order[strings.ToLower(level)]
	if !ok {
		min = 1
	}
	l := log.New(os.Stderr, "", log.LstdFlags)
	return func(lvl, format string, a ...any) {
		if order[lvl] < min {
			return
		}
		l.Printf("[%s] %s", strings.ToUpper(lvl), fmt.Sprintf(format, a...))
	}
}

func srcMode(simulate bool, cfg *config.Config) string {
	if simulate {
		return "simulate"
	}
	return cfg.Source.Mode
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
