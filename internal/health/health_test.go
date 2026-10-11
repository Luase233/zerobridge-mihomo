package health

import (
	"errors"
	"testing"
	"time"
)

func TestInterfaceRecoversWithoutRestartOrStaleReturn(t *testing.T) {
	m := New(19)
	m.UpdateUpstream(nil, time.Now())
	m.UpdateInterface(19, errors.New("adapter disappeared"))
	if m.ReturnIndex() != 0 || m.Snapshot().InterfaceAvailable {
		t.Fatal("missing interface retained a usable stale index")
	}
	if !m.Snapshot().GuardAvailable {
		t.Fatal("link loss should retain independent guard")
	}
	m.UpdateInterface(34, nil)
	if m.ReturnIndex() != 34 || !m.Snapshot().InterfaceAvailable || m.Snapshot().LastError != "" {
		t.Fatalf("new index did not recover: %+v", m.Snapshot())
	}
	m.UpdateInterface(0, nil)
	if m.Snapshot().InterfaceAvailable {
		t.Fatal("zero index should fail closed")
	}
}

func TestUpstreamHysteresisDoesNotFlapOnOneFailure(t *testing.T) {
	m := New(19)
	now := time.Now()
	m.UpdateUpstream(nil, now)
	err := errors.New("fixture DNS timeout")
	m.UpdateUpstream(err, now)
	if m.Snapshot().UpstreamStatus != "ready" {
		t.Fatal("single failure interrupted ready state")
	}
	m.UpdateUpstream(nil, now)
	for range FailureThreshold {
		m.UpdateUpstream(err, now)
	}
	if m.Snapshot().UpstreamStatus != "unavailable" {
		t.Fatal("repeated failures were not reported")
	}
	if !m.Snapshot().InterfaceAvailable || !m.Snapshot().GuardAvailable {
		t.Fatal("advisory upstream failure disabled interface/guard")
	}
	m.UpdateUpstream(nil, now)
	if m.Snapshot().UpstreamStatus != "unavailable" {
		t.Fatal("single success cleared unavailable too early")
	}
	m.UpdateUpstream(nil, now)
	if m.Snapshot().UpstreamStatus != "ready" || m.Snapshot().LastError != "" {
		t.Fatal("two successful checks failed to recover")
	}
}

func TestGuardFailureCannotRecoverFromInterfaceOrUpstreamProbe(t *testing.T) {
	m := New(19)
	m.GuardFailed()
	m.UpdateInterface(34, nil)
	m.UpdateUpstream(nil, time.Now())
	if m.Snapshot().GuardAvailable {
		t.Fatal("interface recovery hid dead independent guard")
	}
}
