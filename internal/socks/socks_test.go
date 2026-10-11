package socks

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"
)

// newUDPAssociation confines all datagrams to loopback while exercising the
// real UDP socket calls, including the lifetime of packet buffers after writes.
func newUDPAssociation(t testing.TB) (*Association, *net.UDPConn, netip.AddrPort) {
	t.Helper()
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.DialUDP("udp4", nil, relay.LocalAddr().(*net.UDPAddr))
	if err != nil {
		relay.Close()
		t.Fatal(err)
	}
	control, peer := net.Pipe()
	a := &Association{control: control, udp: udp}
	deadline := time.Now().Add(time.Minute)
	if err := udp.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	if err := relay.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close(); peer.Close(); relay.Close() })
	return a, relay, udp.LocalAddr().(*net.UDPAddr).AddrPort()
}

func udpPacket(target netip.AddrPort, payload []byte) []byte {
	packet := make([]byte, 10+len(payload))
	packet[3] = 1
	ip := target.Addr().As4()
	copy(packet[4:8], ip[:])
	binary.BigEndian.PutUint16(packet[8:10], target.Port())
	copy(packet[10:], payload)
	return packet
}

func TestAssociationRepeatedPackets(t *testing.T) {
	a, relay, local := newUDPAssociation(t)
	buf := make([]byte, 65535)
	// Alternating lengths catches stale bytes after reusing a larger packet.
	for i, size := range []int{1200, 1, 4096, 0, 90, 65497, 12} {
		target := netip.AddrPortFrom(netip.AddrFrom4([4]byte{203, 0, 113, byte(i + 1)}), uint16(1000+i))
		payload := bytes.Repeat([]byte{byte(i + 20)}, size)
		want := udpPacket(target, payload)
		n, err := a.WriteTo(payload, target)
		if err != nil || n != len(payload) {
			t.Fatalf("write %d: n=%d err=%v", i, n, err)
		}
		// The association must have copied the caller's data before returning.
		for j := range payload {
			payload[j] ^= 0xff
		}
		n, err = relay.Read(buf)
		if err != nil || !bytes.Equal(buf[:n], want) {
			t.Fatalf("relay packet %d: n=%d err=%v", i, n, err)
		}
		if _, err := relay.WriteToUDPAddrPort(want, local); err != nil {
			t.Fatal(err)
		}
		out := make([]byte, size)
		n, source, err := a.ReadFrom(out)
		if err != nil || source != target || !bytes.Equal(out[:n], want[10:]) {
			t.Fatalf("read %d: n=%d source=%s err=%v", i, n, source, err)
		}
	}
}

func TestAssociationRejectsUnsupportedPackets(t *testing.T) {
	a, relay, local := newUDPAssociation(t)
	target := netip.MustParseAddrPort("203.0.113.9:53")
	valid := udpPacket(target, []byte("answer"))
	for name, mutate := range map[string]func([]byte) []byte{
		"short":           func(b []byte) []byte { return b[:9] },
		"reserved":        func(b []byte) []byte { b[0] = 1; return b },
		"reserved second": func(b []byte) []byte { b[1] = 1; return b },
		"fragmented":      func(b []byte) []byte { b[2] = 1; return b },
		"hostname":        func(b []byte) []byte { b[3] = 3; return b },
		"ipv6":            func(b []byte) []byte { b[3] = 4; return b },
	} {
		t.Run(name, func(t *testing.T) {
			packet := mutate(bytes.Clone(valid))
			if _, err := relay.WriteToUDPAddrPort(packet, local); err != nil {
				t.Fatal(err)
			}
			out := bytes.Repeat([]byte{0xaa}, 64)
			n, source, err := a.ReadFrom(out)
			if err == nil || n != 0 || source.IsValid() || !bytes.Equal(out, bytes.Repeat([]byte{0xaa}, 64)) {
				t.Fatalf("malformed packet accepted or mutated caller: n=%d source=%s err=%v", n, source, err)
			}
		})
	}
	if _, err := relay.WriteToUDPAddrPort(valid, local); err != nil {
		t.Fatal(err)
	}
	out := []byte{0xaa}
	if n, source, err := a.ReadFrom(out); n != 0 || source.IsValid() || !errors.Is(err, io.ErrShortBuffer) || out[0] != 0xaa {
		t.Fatalf("short destination: n=%d source=%s err=%v out=%x", n, source, err, out)
	}
	if n, err := a.WriteTo(make([]byte, 65498), target); n != 0 || err == nil {
		t.Fatalf("oversized write accepted: n=%d err=%v", n, err)
	}
	if n, err := a.WriteTo([]byte("invalid"), netip.MustParseAddrPort("[::1]:53")); n != 0 || err == nil {
		t.Fatalf("IPv6 write accepted: n=%d err=%v", n, err)
	}
	if n, err := a.WriteTo([]byte("invalid"), netip.AddrPort{}); n != 0 || err == nil {
		t.Fatalf("invalid address accepted: n=%d err=%v", n, err)
	}
}

func TestAssociationConcurrentReadWrite(t *testing.T) {
	a, relay, _ := newUDPAssociation(t)
	const count = 24
	errors := make(chan error, count*2+1)
	results := make(chan string, count)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		var packet [2048]byte
		for range count {
			n, peer, err := relay.ReadFromUDPAddrPort(packet[:])
			if err != nil {
				errors <- err
				return
			}
			if _, err := relay.WriteToUDPAddrPort(packet[:n], peer); err != nil {
				errors <- err
				return
			}
		}
	}()
	for i := range count {
		wg.Add(2)
		go func() {
			defer wg.Done()
			target := netip.AddrPortFrom(netip.AddrFrom4([4]byte{203, 0, 113, byte(i + 1)}), uint16(4000+i))
			payload := bytes.Repeat([]byte{byte(i)}, 500+i)
			if _, err := a.WriteTo(payload, target); err != nil {
				errors <- err
			}
		}()
		go func() {
			defer wg.Done()
			var buf [2048]byte
			n, source, err := a.ReadFrom(buf[:])
			if err != nil {
				errors <- err
				return
			}
			index := int(source.Addr().As4()[3]) - 1
			if index < 0 || index >= count || source.Port() != uint16(4000+index) || n != 500+index || !bytes.Equal(buf[:n], bytes.Repeat([]byte{byte(index)}, n)) {
				errors <- fmt.Errorf("corrupt response: source=%s n=%d", source, n)
				return
			}
			results <- source.String()
		}()
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		t.Error(err)
	}
	close(results)
	seen := map[string]bool{}
	for source := range results {
		if seen[source] {
			t.Errorf("duplicate packet from %s", source)
		}
		seen[source] = true
	}
	if len(seen) != count {
		t.Fatalf("got %d distinct packets, want %d", len(seen), count)
	}
}

func TestAssociationCloseUnblocksRead(t *testing.T) {
	a, _, _ := newUDPAssociation(t)
	done := make(chan error, 1)
	go func() {
		_, _, err := a.ReadFrom(make([]byte, 1))
		done <- err
	}()
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("read error = %v, want net.ErrClosed", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Close blocked behind a read")
	}
}

func TestAssociationSteadyStateAllocations(t *testing.T) {
	a, relay, local := newUDPAssociation(t)
	target := netip.MustParseAddrPort("203.0.113.5:443")
	payload := make([]byte, 1200)
	packet := udpPacket(target, payload)
	readBuffer := make([]byte, len(packet))
	for name, packetIO := range map[string]func(*testing.T){
		"send": func(t *testing.T) {
			if _, err := a.WriteTo(payload, target); err != nil {
				t.Fatal(err)
			}
			if _, err := relay.Read(readBuffer); err != nil {
				t.Fatal(err)
			}
		},
		"receive": func(t *testing.T) {
			if _, err := relay.WriteToUDPAddrPort(packet, local); err != nil {
				t.Fatal(err)
			}
			if _, _, err := a.ReadFrom(readBuffer); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			// AllocsPerRun warms up once before measuring, so creation of the
			// association's retained buffer is deliberately outside this check.
			if got := testing.AllocsPerRun(100, func() { packetIO(t) }); got != 0 {
				t.Fatalf("steady-state allocations per packet = %v, want 0", got)
			}
		})
	}
}

func BenchmarkAssociationReadFrom(b *testing.B) {
	a, relay, local := newUDPAssociation(b)
	packet := udpPacket(netip.MustParseAddrPort("203.0.113.5:443"), make([]byte, 1200))
	out := make([]byte, 1200)
	b.ReportAllocs()
	b.SetBytes(1200)
	b.ResetTimer()
	for range b.N {
		if _, err := relay.WriteToUDPAddrPort(packet, local); err != nil {
			b.Fatal(err)
		}
		if _, _, err := a.ReadFrom(out); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkAssociationWriteTo(b *testing.B) {
	a, relay, _ := newUDPAssociation(b)
	payload := make([]byte, 1200)
	packet := make([]byte, 65535)
	target := netip.MustParseAddrPort("203.0.113.5:443")
	b.ReportAllocs()
	b.SetBytes(1200)
	b.ResetTimer()
	for range b.N {
		if _, err := a.WriteTo(payload, target); err != nil {
			b.Fatal(err)
		}
		if _, err := relay.Read(packet); err != nil {
			b.Fatal(err)
		}
	}
}
