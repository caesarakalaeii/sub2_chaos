// Package config loads and validates the vote-engine YAML config. It enforces
// the exclusive-or between chat sources structurally (Validate errors unless
// exactly one source is fully specified).
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config is the full vote-engine configuration.
type Config struct {
	Source  SourceConfig  `yaml:"source"`
	Vote    VoteConfig    `yaml:"vote"`
	Bridge  BridgeConfig  `yaml:"bridge"`
	Overlay OverlayConfig `yaml:"overlay"`
	Catalog CatalogConfig `yaml:"catalog"`
	Log     LogConfig     `yaml:"log"`
}

// SourceConfig selects exactly one chat source.
type SourceConfig struct {
	Mode    string        `yaml:"mode"` // "twitch" | "allchat"
	Twitch  TwitchConfig  `yaml:"twitch"`
	Allchat AllchatConfig `yaml:"allchat"`
}

// TwitchConfig configures the anonymous Twitch IRC source.
type TwitchConfig struct {
	Channel     string `yaml:"channel"`
	Server      string `yaml:"server"`
	UseTLS      bool   `yaml:"useTLS"`
	RequestTags bool   `yaml:"requestTags"`
}

// AllchatConfig configures the all-chat WebSocket source.
type AllchatConfig struct {
	BaseURL          string `yaml:"baseURL"`
	StreamerUsername string `yaml:"streamerUsername"`
	OverlayID        string `yaml:"overlayId"`
	Token            string `yaml:"token"`
}

// VoteConfig tunes the round timing and selection.
type VoteConfig struct {
	OptionsPerRound      int   `yaml:"optionsPerRound"`
	VoteDurationSeconds  int   `yaml:"voteDurationSeconds"`
	CooldownSeconds      int   `yaml:"cooldownSeconds"`
	ApplyHoldSeconds     int   `yaml:"applyHoldSeconds"`
	AnnounceLeadSeconds  int   `yaml:"announceLeadSeconds"`
	AvoidImmediateRepeat bool  `yaml:"avoidImmediateRepeat"`
	CategoryBalance      bool  `yaml:"categoryBalance"`
	Seed                 int64 `yaml:"seed"`
}

// BridgeConfig locates the chaos_state.json / chaos_status.json files.
type BridgeConfig struct {
	ModName          string `yaml:"modName"`
	GameDir          string `yaml:"gameDir"`
	ModDir           string `yaml:"modDir"`
	BridgeFile       string `yaml:"bridgeFile"`
	StatusFile       string `yaml:"statusFile"`
	UseDiscoveryFile bool   `yaml:"useDiscoveryFile"`
	WriteHz          int    `yaml:"writeHz"`
}

// OverlayConfig configures the OBS browser-source server.
type OverlayConfig struct {
	Enabled bool   `yaml:"enabled"`
	Bind    string `yaml:"bind"`
	Port    int    `yaml:"port"`
}

// CatalogConfig points at the shared events.json.
type CatalogConfig struct {
	Path string `yaml:"path"`
}

// LogConfig sets verbosity.
type LogConfig struct {
	Level string `yaml:"level"`
}

// Default returns a config pre-populated with sensible defaults.
func Default() *Config {
	return &Config{
		Source: SourceConfig{
			Mode:    "twitch",
			Twitch:  TwitchConfig{Server: "irc.chat.twitch.tv:6697", UseTLS: true, RequestTags: true},
			Allchat: AllchatConfig{BaseURL: "https://allch.at"},
		},
		Vote: VoteConfig{
			OptionsPerRound:      4,
			VoteDurationSeconds:  30,
			CooldownSeconds:      20,
			ApplyHoldSeconds:     3,
			AnnounceLeadSeconds:  5,
			AvoidImmediateRepeat: true,
		},
		Bridge:  BridgeConfig{ModName: "Sub2Chaos", UseDiscoveryFile: true, WriteHz: 4},
		Overlay: OverlayConfig{Enabled: true, Bind: "127.0.0.1", Port: 8777},
		Catalog: CatalogConfig{Path: "./events.json"},
		Log:     LogConfig{Level: "info"},
	}
}

// Load reads YAML over the defaults. A missing file is not an error here (the
// caller decides whether config is required, e.g. --simulate runs on defaults).
func Load(path string) (*Config, error) {
	c := Default()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return c, nil
		}
		return nil, err
	}
	if err := yaml.Unmarshal(data, c); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}
	return c, nil
}

// Validate enforces the source XOR and value ranges.
func (c *Config) Validate() error {
	switch c.Source.Mode {
	case "twitch":
		if strings.TrimSpace(c.Source.Twitch.Channel) == "" {
			return fmt.Errorf("config: source.twitch.channel is required when mode is \"twitch\"")
		}
	case "allchat":
		if strings.TrimSpace(c.Source.Allchat.BaseURL) == "" {
			return fmt.Errorf("config: source.allchat.baseURL is required when mode is \"allchat\"")
		}
		hasUser := strings.TrimSpace(c.Source.Allchat.StreamerUsername) != ""
		hasOverlay := strings.TrimSpace(c.Source.Allchat.OverlayID) != ""
		if hasUser == hasOverlay {
			return fmt.Errorf("config: set exactly one of source.allchat.streamerUsername or source.allchat.overlayId")
		}
	default:
		return fmt.Errorf("config: source.mode must be \"twitch\" or \"allchat\" (got %q)", c.Source.Mode)
	}

	if c.Vote.OptionsPerRound < 2 || c.Vote.OptionsPerRound > 9 {
		return fmt.Errorf("config: vote.optionsPerRound must be between 2 and 9 (single-digit voting)")
	}
	if c.Vote.VoteDurationSeconds <= 0 {
		return fmt.Errorf("config: vote.voteDurationSeconds must be > 0")
	}
	if c.Vote.AnnounceLeadSeconds < 0 {
		return fmt.Errorf("config: vote.announceLeadSeconds must be >= 0")
	}
	if c.Overlay.Enabled && (c.Overlay.Port <= 0 || c.Overlay.Port > 65535) {
		return fmt.Errorf("config: overlay.port must be a valid port")
	}
	return nil
}

// Warnings returns non-fatal advisories (e.g. binding the overlay publicly).
func (c *Config) Warnings() []string {
	var w []string
	if c.Overlay.Enabled && c.Overlay.Bind != "127.0.0.1" && c.Overlay.Bind != "localhost" {
		w = append(w, fmt.Sprintf("overlay bound to %q (not loopback) — the overlay will be reachable from the network", c.Overlay.Bind))
	}
	return w
}

// Duration helpers.
func (v VoteConfig) VoteDuration() time.Duration {
	return time.Duration(v.VoteDurationSeconds) * time.Second
}
func (v VoteConfig) CooldownDuration() time.Duration {
	return time.Duration(v.CooldownSeconds) * time.Second
}
func (v VoteConfig) ApplyHoldDuration() time.Duration {
	return time.Duration(v.ApplyHoldSeconds) * time.Second
}
func (v VoteConfig) AnnounceLeadDuration() time.Duration {
	return time.Duration(v.AnnounceLeadSeconds) * time.Second
}
