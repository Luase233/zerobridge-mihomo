// Package health tracks recoverable link failures without releasing the
// interception handles or restarting established proxy connections.
package health

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

const (
	FailureThreshold  = 3
	RecoveryThreshold = 2
)

var ErrInterfaceUnavailable = errors.New("ZeroTier return interface unavailable; packet consumed with interception retained")

type Snapshot struct {
	InterfaceIndex       uint32 `json:"interface_index"`
	InterfaceAvailable   bool   `json:"interface_available"`
	GuardAvailable       bool   `json:"guard_available"`
	UpstreamStatus       string `json:"upstream_status"`
	UpstreamFailures     int    `json:"upstream_failures"`
	LastUpstreamCheckUTC string `json:"last_upstream_check_utc,omitempty"`
	LastError            string `json:"last_error"`
}

type Monitor struct {
	index               atomic.Uint32
	mu                  sync.Mutex
	guard               bool
	interfaceError      string
	upstreamError       string
	upstreamStatus      string
	failures, successes int
	checked             time.Time
}

func New(index uint32) *Monitor {
	m := &Monitor{guard: true, upstreamStatus: "checking"}
	m.index.Store(index)
	return m
}

// ReturnIndex is zero while the configured address/subnet has no unique active
// ZeroTier interface. Callers must never send via a stale index or a default route.
func (m *Monitor) ReturnIndex() uint32 { return m.index.Load() }

func (m *Monitor) UpdateInterface(index uint32, err error) {
	if index == 0 && err == nil {
		err = errors.New("resolved interface index is zero")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err != nil {
		m.index.Store(0)
		m.interfaceError = err.Error()
		return
	}
	m.index.Store(index)
	m.interfaceError = ""
}

func (m *Monitor) GuardFailed() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.guard = false
}

// UpdateUpstream debounces transient DNS/SOCKS failures. Upstream checks are
// advisory: this monitor never closes flows, changes nodes or restarts processes.
func (m *Monitor) UpdateUpstream(err error, now time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.checked = now.UTC()
	if err != nil {
		m.successes = 0
		m.failures++
		m.upstreamError = err.Error()
		if m.failures >= FailureThreshold {
			m.upstreamStatus = "unavailable"
		}
		return
	}
	m.failures = 0
	m.successes++
	if m.upstreamStatus != "unavailable" || m.successes >= RecoveryThreshold {
		m.upstreamStatus = "ready"
		m.upstreamError = ""
	}
}

func (m *Monitor) Snapshot() Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	index := m.index.Load()
	s := Snapshot{InterfaceIndex: index, InterfaceAvailable: index != 0, GuardAvailable: m.guard, UpstreamStatus: m.upstreamStatus, UpstreamFailures: m.failures}
	if !m.checked.IsZero() {
		s.LastUpstreamCheckUTC = m.checked.Format(time.RFC3339Nano)
	}
	switch {
	case !m.guard:
		s.LastError = "independent guard unavailable; client interception retained in drop mode"
	case index == 0:
		s.LastError = "ZeroTier return interface unavailable: " + m.interfaceError
	case m.upstreamStatus == "unavailable":
		s.LastError = "SOCKS/DNS health check unavailable: " + m.upstreamError
	case m.upstreamStatus == "checking":
		s.LastError = "waiting for initial SOCKS/DNS health check"
	}
	return s
}
