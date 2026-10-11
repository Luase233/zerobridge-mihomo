package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func validConfig() Config {
	return Config{SourceIP: "10.147.20.2", WindowsIP: "10.147.20.1", InterfaceIndex: 18, Proxy: "127.0.0.1:7897", DNS: "1.1.1.1:53", MTU: 1280, MaxFlows: 256, IdleTimeoutSeconds: 120, WinDivertDLL: "runtime/WinDivert.dll"}
}

func TestRejectUnsafeConfig(t *testing.T) {
	c := validConfig()
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*Config){func(c *Config) { c.SourceIP = "0.0.0.0" }, func(c *Config) { c.SourceIP = c.WindowsIP }, func(c *Config) { c.Proxy = "8.8.8.8:1080" }, func(c *Config) { c.DNS = "127.0.0.1:53" }, func(c *Config) { c.MTU = 65535 }} {
		bad := c
		mutate(&bad)
		if bad.Validate() == nil {
			t.Fatalf("unsafe config accepted: %+v", bad)
		}
	}
}

func TestTCPIdleTimeoutBoundsAndLegacyCaller(t *testing.T) {
	for _, value := range []int{0, 120, 1800, 86400} {
		c := validConfig()
		c.TCPIdleTimeoutSeconds = value
		if err := c.Validate(); err != nil {
			t.Fatalf("valid TCP timeout %d rejected: %v", value, err)
		}
	}
	for _, value := range []int{-1, 1, 119, 86401} {
		c := validConfig()
		c.TCPIdleTimeoutSeconds = value
		if c.Validate() == nil {
			t.Fatalf("out-of-range TCP timeout %d accepted", value)
		}
	}
}

func TestLoadDefaultsLegacyTCPIdleAndPreservesUDP(t *testing.T) {
	for _, value := range []int{-1, 0, 120, 1800, 86400, 86401} {
		t.Run(strconv.Itoa(value), func(t *testing.T) {
			data, err := json.Marshal(validConfig())
			if err != nil {
				t.Fatal(err)
			}
			var fields map[string]any
			if err = json.Unmarshal(data, &fields); err != nil {
				t.Fatal(err)
			}
			if value == -1 {
				delete(fields, "tcp_idle_timeout_seconds")
			} else {
				fields["tcp_idle_timeout_seconds"] = value
			}
			data, err = json.Marshal(fields)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "gateway.json")
			if err = os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			c, err := Load(path)
			if value == 86401 {
				if err == nil {
					t.Fatal("Load accepted invalid TCP timeout")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			want := value
			if value <= 0 {
				want = DefaultTCPIdleTimeoutSeconds
			}
			if c.TCPIdleTimeoutSeconds != want || c.IdleTimeoutSeconds != 120 {
				t.Fatalf("timeout defaults changed protocol settings: %+v", c)
			}
		})
	}
}
