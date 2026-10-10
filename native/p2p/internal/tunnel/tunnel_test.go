package tunnel

import (
	"bytes"
	"context"
	"github.com/pion/webrtc/v3"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDirectTunnelCarriesMultipleTCPStreams(t *testing.T) {
	remote, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	go func() {
		for {
			c, e := remote.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	client, err := New(nil, []InterfaceSnapshot{{Name: "android-lo", Index: 99, Addresses: []string{"127.0.0.2"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := New(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	offer, err := client.Offer(ctx)
	if err != nil {
		t.Fatal(err)
	}
	answer, err := server.Answer(ctx, offer, remote.Addr().(*net.TCPAddr).Port)
	if err != nil {
		t.Fatal(err)
	}
	port, err := client.Connect(ctx, answer)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := client.PC.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local.Address != "127.0.0.2" {
		t.Fatal("selected pair did not use the platform-provided interface")
	}
	if client.PacketCounts.Sent.Load() == 0 || client.PacketCounts.Received.Load() == 0 {
		t.Fatal("successful ICE handshake did not record real socket traffic")
	}
	for i := 0; i < 2; i++ {
		c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		payload := bytes.Repeat([]byte("ssh-p2p-stream\n"), 8192)
		done := make(chan error, 1)
		go func() { _, e := c.Write(payload); done <- e }()
		got := make([]byte, len(payload))
		_, err = io.ReadFull(c, got)
		c.Close()
		if err != nil {
			t.Fatal(err)
		}
		if err = <-done; err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, payload) {
			t.Fatal("stream was corrupted")
		}
	}
}
func TestPeerWithoutRemoteCannotConnect(t *testing.T) {
	p, err := New(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err = p.Offer(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Invalid signaling must fail rather than exposing a listener.
	_, err = p.Connect(ctx, webrtc.SessionDescription{})
	if err == nil {
		t.Fatal("invalid answer created a tunnel")
	}
}

func TestOfferUsesAndroidInterfaceSnapshotInsteadOfNetlink(t *testing.T) {
	p, err := New(nil, []InterfaceSnapshot{{Name: "android-lo", Index: 99, Addresses: []string{"127.0.0.2"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	offer, err := p.Offer(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(offer.SDP, "127.0.0.2") {
		t.Fatal("Android-provided network interface was ignored; offer still depends on system/netlink enumeration")
	}
}

func TestEmptyAndroidSnapshotDoesNotFallBackToNetlink(t *testing.T) {
	if p, err := New(nil, []InterfaceSnapshot{}); err == nil {
		p.Close()
		t.Fatal("empty platform snapshot silently used restricted system enumeration")
	}
}

func TestOfferExcludesOverlayInterfaces(t *testing.T) {
	p, err := New(nil, []InterfaceSnapshot{
		{Name: "wlan0", Index: 99, Addresses: []string{"127.0.0.2"}},
		{Name: "tailscale0", Index: 100, Addresses: []string{"127.0.0.3"}},
		{Name: "tun0", Index: 101, Addresses: []string{"127.0.0.4"}},
		{Name: "Mihomo", Index: 102, Addresses: []string{"127.0.0.5"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	offer, err := p.Offer(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(offer.SDP, "127.0.0.2") {
		t.Fatal("physical interface was excluded")
	}
	for _, address := range []string{"127.0.0.3", "127.0.0.4", "127.0.0.5"} {
		if strings.Contains(offer.SDP, address) {
			t.Fatalf("overlay address %s was advertised as direct P2P", address)
		}
	}
}
