//go:build windows

package main

import (
	"os"
	"time"

	"github.com/Luase233/zerobridge-mihomo/internal/health"
	"github.com/Luase233/zerobridge-mihomo/internal/settings"
	"golang.org/x/sys/windows"
)

type healthHeartbeat struct {
	path                 string
	PID                  int    `json:"pid"`
	Mode                 string `json:"mode"`
	Version              string `json:"version"`
	Source               string `json:"source"`
	ConfigSHA256         string `json:"config_sha256"`
	ProcessStartFiletime string `json:"process_start_filetime"`
	UpdatedUTC           string `json:"updated_utc"`
	health.Snapshot
}

func newHealthHeartbeat(path string, c settings.Config) (*healthHeartbeat, error) {
	hash, err := hashConfig(c)
	if err != nil {
		return nil, err
	}
	start, err := processStart(windows.CurrentProcess())
	if err != nil {
		return nil, err
	}
	return &healthHeartbeat{path: path, PID: os.Getpid(), Mode: "proxy", Version: version, Source: c.SourceIP, ConfigSHA256: hash, ProcessStartFiletime: start}, nil
}

func (h *healthHeartbeat) Write(snapshot health.Snapshot) error {
	h.Snapshot = snapshot
	h.UpdatedUTC = time.Now().UTC().Format(time.RFC3339Nano)
	return writeAtomicJSON(h.path, h)
}

func sendReturnPacket(m *health.Monitor, send func([]byte, uint32) error, packet []byte) error {
	index := m.ReturnIndex()
	if index == 0 {
		// Gateway records failed delivery but preserves its stack and flows. Do
		// not count consumed returns as transmitted bytes or use a default route.
		return health.ErrInterfaceUnavailable
	}
	return send(packet, index)
}
