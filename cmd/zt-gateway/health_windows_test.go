//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/Luase233/zerobridge-mihomo/internal/health"
	"github.com/Luase233/zerobridge-mihomo/internal/settings"
)

func TestReturnPacketRecoversInPlaceAndNeverUsesStaleOrZeroIndex(t *testing.T) {
	m := health.New(19)
	var sent []uint32
	send := func(_ []byte, index uint32) error { sent = append(sent, index); return nil }
	if err := sendReturnPacket(m, send, []byte{1}); err != nil {
		t.Fatal(err)
	}
	m.UpdateInterface(19, errors.New("adapter disappeared"))
	if err := sendReturnPacket(m, send, []byte{2}); !errors.Is(err, health.ErrInterfaceUnavailable) {
		t.Fatalf("consumed return must report failure: %v", err)
	}
	m.UpdateInterface(34, nil)
	if err := sendReturnPacket(m, send, []byte{3}); err != nil {
		t.Fatal(err)
	}
	if len(sent) != 2 || sent[0] != 19 || sent[1] != 34 {
		t.Fatalf("sent via stale/zero interface: %v", sent)
	}
}

func TestHealthHeartbeatReplacesExistingJSON(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "gateway.json")
	if err := os.WriteFile(configPath, []byte(`{"source_ip":"10.147.20.2"}`), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "proxy.health.json")
	h, err := newHealthHeartbeat(path, settings.Config{SourceIP: "10.147.20.2", File: configPath})
	if err != nil {
		t.Fatal(err)
	}
	for _, index := range []uint32{19, 0, 34} {
		if err := h.Write(health.Snapshot{InterfaceIndex: index, InterfaceAvailable: index != 0, GuardAvailable: true, UpstreamStatus: "ready"}); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var got healthHeartbeat
		if err = json.Unmarshal(b, &got); err != nil {
			t.Fatal(err)
		}
		if got.InterfaceIndex != index || got.PID != os.Getpid() || got.Version != version || got.ProcessStartFiletime == "" || got.ConfigSHA256 == "" || got.UpdatedUTC == "" {
			t.Fatalf("bad owned heartbeat: %+v", got)
		}
	}
}

func TestGuardProofAllowsReturnInterfaceChangeButRejectsIdentityChanges(t *testing.T) {
	proof := guardReadiness{PID: 123, Mode: "guard", Source: "10.147.20.2", Interface: 19, Config: "hash", Start: "start"}
	if err := validateGuardProof(proof, 123, "hash", "start", "10.147.20.2"); err != nil {
		t.Fatal(err)
	}
	for _, mutation := range []func(*guardReadiness){
		func(p *guardReadiness) { p.PID++ },
		func(p *guardReadiness) { p.Mode = "proxy" },
		func(p *guardReadiness) { p.Source = "192.168.196.185" },
		func(p *guardReadiness) { p.Config = "changed" },
		func(p *guardReadiness) { p.Start = "reused-pid" },
	} {
		bad := proof
		mutation(&bad)
		if err := validateGuardProof(bad, 123, "hash", "start", "10.147.20.2"); err == nil {
			t.Fatalf("identity mismatch accepted: %+v", bad)
		}
	}
}
