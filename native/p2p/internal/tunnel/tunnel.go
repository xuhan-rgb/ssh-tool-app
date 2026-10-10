// Package tunnel carries SSH TCP streams over reliable WebRTC data channels.
// Signaling is exchanged by the app over an already authenticated SSH channel.
package tunnel

import (
	"context"
	"fmt"
	"io"
	"net"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v3"
)

var STUNServers = []string{"stun:stun.miwifi.com:3478", "stun:stun.cloudflare.com:3478"}

type Peer struct {
	PC                  *webrtc.PeerConnection
	PacketCounts        *PacketCounts
	Ready               chan struct{}
	Done                chan struct{}
	readyOnce, doneOnce sync.Once
	listener            net.Listener
	next                uint64
}

func New(servers []string, snapshots ...[]InterfaceSnapshot) (*Peer, error) {
	settings := webrtc.SettingEngine{}
	var packets *PacketCounts
	// Overlay interfaces may themselves use a relay. Do not advertise them as
	// direct paths: Android Tailscale uses tun0, while Linux uses tailscale0.
	settings.SetInterfaceFilter(directInterface)
	if len(snapshots) > 0 {
		network, err := newPlatformNet(snapshots[0])
		if err != nil {
			return nil, err
		}
		settings.SetNet(network)
		packets = network.packets
	} else if runtime.GOOS == "linux" {
		network, err := newBoundNet()
		if err != nil {
			return nil, err
		}
		settings.SetNet(network)
	}
	settings.DetachDataChannels()
	// Loopback is useful only for local transport tests without STUN. Advertising
	// it to a remote phone creates invalid outbound candidate pairs.
	settings.SetIncludeLoopbackCandidate(len(servers) == 0)
	api := webrtc.NewAPI(webrtc.WithSettingEngine(settings))
	cfg := webrtc.Configuration{}
	if len(servers) > 0 {
		cfg.ICEServers = []webrtc.ICEServer{{URLs: servers}}
	}
	pc, err := api.NewPeerConnection(cfg)
	if err != nil {
		return nil, err
	}
	p := &Peer{PC: pc, PacketCounts: packets, Ready: make(chan struct{}), Done: make(chan struct{})}
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateConnected {
			p.readyOnce.Do(func() { close(p.Ready) })
		}
		if state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateFailed {
			p.doneOnce.Do(func() { close(p.Done) })
		}
	})
	return p, nil
}

func directInterface(name string) bool {
	name = strings.ToLower(name)
	return !strings.HasPrefix(name, "tailscale") &&
		!strings.HasPrefix(name, "tun") && !strings.HasPrefix(name, "tap") &&
		!strings.HasPrefix(name, "docker") && !strings.HasPrefix(name, "veth") &&
		name != "mihomo"
}

func (p *Peer) Close() {
	if p.listener != nil {
		p.listener.Close()
	}
	p.PC.Close()
	p.doneOnce.Do(func() { close(p.Done) })
}

func (p *Peer) describe(ctx context.Context, desc webrtc.SessionDescription) (webrtc.SessionDescription, error) {
	gathered := webrtc.GatheringCompletePromise(p.PC)
	if err := p.PC.SetLocalDescription(desc); err != nil {
		return webrtc.SessionDescription{}, err
	}
	select {
	case <-gathered:
	case <-ctx.Done():
		// Host/reflexive candidates already gathered remain usable. Do not wait
		// indefinitely for an unreachable STUN server.
	}
	local := p.PC.LocalDescription()
	if local == nil {
		return webrtc.SessionDescription{}, fmt.Errorf("P2P 地址协商失败")
	}
	return *local, nil
}

func (p *Peer) Offer(ctx context.Context) (webrtc.SessionDescription, error) {
	// Establish SCTP in the offer; later streams need no renegotiation.
	control, err := p.PC.CreateDataChannel("control", nil)
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	control.OnOpen(func() { _, _ = control.Detach() })
	offer, err := p.PC.CreateOffer(nil)
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	return p.describe(ctx, offer)
}

func (p *Peer) Answer(ctx context.Context, offer webrtc.SessionDescription, port int) (webrtc.SessionDescription, error) {
	if port < 1 || port > 65535 {
		return webrtc.SessionDescription{}, fmt.Errorf("SSH 端口无效")
	}
	p.PC.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnOpen(func() {
			stream, err := dc.Detach()
			if err != nil {
				return
			}
			if dc.Label() == "control" {
				go func() { io.Copy(io.Discard, stream); stream.Close() }()
				return
			}
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 5*time.Second)
			if err != nil {
				stream.Close()
				return
			}
			go bridge(conn, stream)
		})
	})
	if err := p.PC.SetRemoteDescription(offer); err != nil {
		return webrtc.SessionDescription{}, err
	}
	answer, err := p.PC.CreateAnswer(nil)
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	return p.describe(ctx, answer)
}

func (p *Peer) Connect(ctx context.Context, answer webrtc.SessionDescription) (int, error) {
	if err := p.PC.SetRemoteDescription(answer); err != nil {
		return 0, err
	}
	select {
	case <-p.Ready:
	case <-p.Done:
		return 0, fmt.Errorf("P2P 连接已关闭")
	case <-ctx.Done():
		return 0, fmt.Errorf("当前网络未能建立 P2P 直连")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	p.listener = listener
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			dc, err := p.PC.CreateDataChannel(fmt.Sprintf("ssh-%d", atomic.AddUint64(&p.next, 1)), nil)
			if err != nil {
				conn.Close()
				continue
			}
			timer := time.AfterFunc(8*time.Second, func() { conn.Close(); dc.Close() })
			dc.OnOpen(func() {
				timer.Stop()
				stream, err := dc.Detach()
				if err != nil {
					conn.Close()
					return
				}
				go bridge(conn, stream)
			})
		}
	}()
	go func() { <-p.Done; listener.Close() }()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

func bridge(conn net.Conn, stream io.ReadWriteCloser) {
	defer conn.Close()
	defer stream.Close()
	done := make(chan struct{}, 1)
	// Limit each data-channel message to 16 KiB and preserve ordered delivery.
	go func() { io.CopyBuffer(stream, conn, make([]byte, 16*1024)); done <- struct{}{} }()
	io.CopyBuffer(conn, stream, make([]byte, 64*1024))
	conn.Close()
	stream.Close()
	<-done
}
