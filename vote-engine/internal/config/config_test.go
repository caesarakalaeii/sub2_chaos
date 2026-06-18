package config

import "testing"

func TestDefaults(t *testing.T) {
	c := Default()
	if c.Vote.OptionsPerRound != 4 || c.Overlay.Port != 8777 || c.Bridge.ModName != "Sub2Chaos" {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestValidateTwitch(t *testing.T) {
	c := Default()
	c.Source.Mode = "twitch"
	c.Source.Twitch.Channel = ""
	if c.Validate() == nil {
		t.Fatal("twitch without channel should error")
	}
	c.Source.Twitch.Channel = "somechannel"
	if err := c.Validate(); err != nil {
		t.Fatalf("valid twitch config errored: %v", err)
	}
}

func TestValidateAllchatXOR(t *testing.T) {
	c := Default()
	c.Source.Mode = "allchat"
	c.Source.Allchat.BaseURL = "https://allch.at"

	if c.Validate() == nil {
		t.Fatal("allchat with neither username nor overlayId should error")
	}
	c.Source.Allchat.StreamerUsername = "user"
	if err := c.Validate(); err != nil {
		t.Fatalf("allchat with username should pass: %v", err)
	}
	c.Source.Allchat.OverlayID = "ovl"
	if c.Validate() == nil {
		t.Fatal("allchat with BOTH username and overlayId should error (XOR)")
	}
}

func TestValidateModeAndRange(t *testing.T) {
	c := Default()
	c.Source.Mode = "youtube"
	if c.Validate() == nil {
		t.Fatal("unknown mode should error")
	}
	c = Default()
	c.Source.Mode = "twitch"
	c.Source.Twitch.Channel = "c"
	c.Vote.OptionsPerRound = 10
	if c.Validate() == nil {
		t.Fatal("optionsPerRound > 9 should error")
	}
}
