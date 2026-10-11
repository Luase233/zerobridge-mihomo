package health

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestSOCKSDNSHealthUsesProxyAndValidatesDNS(t *testing.T) {
	for _, corrupt := range []bool{false, true} {
		t.Run(map[bool]string{false: "valid", true: "wrong-id"}[corrupt], func(t *testing.T) {
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			serverResult := make(chan error, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					serverResult <- err
					return
				}
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(2 * time.Second))
				var greeting [3]byte
				if _, err = io.ReadFull(conn, greeting[:]); err != nil {
					serverResult <- err
					return
				}
				if _, err = conn.Write([]byte{5, 0}); err != nil {
					serverResult <- err
					return
				}
				var connect [10]byte
				if _, err = io.ReadFull(conn, connect[:]); err != nil {
					serverResult <- err
					return
				}
				if connect != [10]byte{5, 1, 0, 1, 1, 1, 1, 1, 0, 53} {
					serverResult <- io.ErrUnexpectedEOF
					return
				}
				if _, err = conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1}); err != nil {
					serverResult <- err
					return
				}
				var size [2]byte
				if _, err = io.ReadFull(conn, size[:]); err != nil {
					serverResult <- err
					return
				}
				body := make([]byte, binary.BigEndian.Uint16(size[:]))
				if _, err = io.ReadFull(conn, body); err != nil {
					serverResult <- err
					return
				}
				var query dnsmessage.Message
				if err = query.Unpack(body); err != nil {
					serverResult <- err
					return
				}
				query.Response = true
				if corrupt {
					query.ID++
				}
				body, err = query.Pack()
				if err != nil {
					serverResult <- err
					return
				}
				binary.BigEndian.PutUint16(size[:], uint16(len(body)))
				_, err = conn.Write(append(size[:], body...))
				serverResult <- err
			}()
			err = CheckSOCKSDNS(context.Background(), listener.Addr().String(), "1.1.1.1:53")
			if (err != nil) != corrupt {
				t.Fatalf("corrupt=%v result=%v", corrupt, err)
			}
			if err = <-serverResult; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSOCKSDNSHealthCancellationIsBounded(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		io.Copy(io.Discard, conn)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	if err = CheckSOCKSDNS(ctx, listener.Addr().String(), "1.1.1.1:53"); err == nil {
		t.Fatal("stalled SOCKS greeting succeeded")
	}
	if time.Since(started) > time.Second {
		t.Fatal("health check did not respect short parent deadline")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled health connection was not closed")
	}
}
