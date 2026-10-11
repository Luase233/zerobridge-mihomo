package health

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net/netip"
	"time"

	"github.com/Luase233/zerobridge-mihomo/internal/socks"
	"golang.org/x/net/dns/dnsmessage"
)

const ProbeTimeout = 8 * time.Second

// CheckSOCKSDNS sends one small TCP DNS request through the configured loopback
// SOCKS proxy. There is no direct DNS/HTTP fallback, public IP lookup or website
// download. A failure is a diagnostic for this path, not proof all sites are down.
func CheckSOCKSDNS(parent context.Context, proxy, dns string) error {
	ctx, cancel := context.WithTimeout(parent, ProbeTimeout)
	defer cancel()
	c, err := socks.New(proxy)
	if err != nil {
		return err
	}
	target, err := netip.ParseAddrPort(dns)
	if err != nil {
		return err
	}
	conn, err := c.DialTCP(ctx, target)
	if err != nil {
		return fmt.Errorf("SOCKS TCP DNS connect: %w", err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	if err = conn.SetDeadline(deadline); err != nil {
		return err
	}
	var randomID [2]byte
	if _, err = rand.Read(randomID[:]); err != nil {
		return err
	}
	name, err := dnsmessage.NewName("example.com.")
	if err != nil {
		return err
	}
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: binary.BigEndian.Uint16(randomID[:]), RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	payload, err := query.Pack()
	if err != nil {
		return err
	}
	frame := make([]byte, len(payload)+2)
	binary.BigEndian.PutUint16(frame, uint16(len(payload)))
	copy(frame[2:], payload)
	if _, err = io.Copy(conn, bytes.NewReader(frame)); err != nil {
		return fmt.Errorf("TCP DNS request: %w", err)
	}
	var size [2]byte
	if _, err = io.ReadFull(conn, size[:]); err != nil {
		return fmt.Errorf("TCP DNS response: %w", err)
	}
	n := int(binary.BigEndian.Uint16(size[:]))
	if n < 12 {
		return fmt.Errorf("short TCP DNS response")
	}
	response := make([]byte, n)
	if _, err = io.ReadFull(conn, response); err != nil {
		return fmt.Errorf("TCP DNS response: %w", err)
	}
	var answer dnsmessage.Message
	if err = answer.Unpack(response); err != nil {
		return fmt.Errorf("TCP DNS parse: %w", err)
	}
	if answer.ID != query.ID || !answer.Response || answer.Truncated || answer.RCode != dnsmessage.RCodeSuccess || len(answer.Questions) != 1 || answer.Questions[0] != query.Questions[0] {
		return fmt.Errorf("invalid or unsuccessful TCP DNS health response")
	}
	return nil
}
