package tunnel

import (
	"bytes"
	"context"
	"fmt"
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

func TestMultiplePhonePeersKeepIndependentConnections(t *testing.T) {
	remote, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	go func() {
		for {
			c, err := remote.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	clients := make([]*Peer, 2)
	servers := make([]*Peer, 2)
	ports := make([]int, 2)
	for i := range clients {
		clients[i], err = New(nil, []InterfaceSnapshot{{Name: "phone", Index: 99 + i, Addresses: []string{fmt.Sprintf("127.0.0.%d", i+2)}}})
		if err != nil {
			t.Fatal(err)
		}
		defer clients[i].Close()
		servers[i], err = New(nil)
		if err != nil {
			t.Fatal(err)
		}
		defer servers[i].Close()
		offer, err := clients[i].Offer(ctx)
		if err != nil {
			t.Fatal(err)
		}
		answer, err := servers[i].Answer(ctx, offer, remote.Addr().(*net.TCPAddr).Port)
		if err != nil {
			t.Fatal(err)
		}
		ports[i], err = clients[i].Connect(ctx, answer)
		if err != nil {
			t.Fatal(err)
		}
	}
	if ports[0] == ports[1] {
		t.Fatal("phone listeners share a port")
	}
	exchange := func(port int, payload string) error {
		c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			return err
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err = c.Write([]byte(payload)); err != nil {
			return err
		}
		got := make([]byte, len(payload))
		if _, err = io.ReadFull(c, got); err != nil {
			return err
		}
		if string(got) != payload {
			return fmt.Errorf("phone data crossed sessions")
		}
		return nil
	}
	results := make(chan error, 2)
	for i := range ports {
		go func(i int) { results <- exchange(ports[i], fmt.Sprintf("phone-%d", i)) }(i)
	}
	for range ports {
		if err = <-results; err != nil {
			t.Fatal(err)
		}
	}
	clients[0].Close()
	servers[0].Close()
	if err = exchange(ports[1], "second phone remains connected"); err != nil {
		t.Fatal(err)
	}
}
