package tunnel

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"time"

	"github.com/pion/transport/v2"
	"github.com/pion/transport/v2/stdnet"
)

type boundNet struct {
	*stdnet.Net
	ipv4 net.IP
}

func (n *boundNet) ResolveUDPAddr(network, address string) (*net.UDPAddr, error) {
	resolved, err := n.Net.ResolveUDPAddr(network, address)
	if err != nil || !proxyDNSAddress(resolved.IP) || n.ipv4 == nil {
		return resolved, err
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	// Fake-IP DNS addresses belong to the proxy, not to the STUN server.
	// Resolve only this request using a socket bound to our physical source.
	resolver := net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		// TCP avoids losing the only DNS query during the short ICE gather window.
		local := &net.TCPAddr{IP: n.ipv4}
		return (&net.Dialer{LocalAddr: local}).DialContext(ctx, "tcp", "223.5.5.5:53")
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ips, err := resolver.LookupIP(ctx, "ip4", host)
	if err != nil {
		return nil, err
	}
	for _, ip := range ips {
		if !proxyDNSAddress(ip) {
			p, err := strconv.Atoi(port)
			if err != nil {
				return nil, err
			}
			return &net.UDPAddr{IP: ip, Port: p}, nil
		}
	}
	return nil, fmt.Errorf("STUN DNS returned a proxy virtual address")
}

func proxyDNSAddress(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && v4[0] == 198 && v4[1]&0xfe == 18
}

// Bind wildcard STUN sockets to the same physical source used by host
// candidates. This affects only our sockets, without changing system routes.
func (n *boundNet) ListenUDP(network string, address *net.UDPAddr) (transport.UDPConn, error) {
	if network == "udp4" && n.ipv4 != nil && (address == nil || address.IP.IsUnspecified() || len(address.IP) == 0) {
		bound := net.UDPAddr{IP: n.ipv4}
		if address != nil {
			bound.Port = address.Port
		}
		return n.Net.ListenUDP(network, &bound)
	}
	return n.Net.ListenUDP(network, address)
}

func newBoundNet() (*boundNet, error) {
	base, err := stdnet.NewNet()
	if err != nil {
		return nil, err
	}
	n := &boundNet{Net: base}
	interfaces, err := base.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, ifc := range interfaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 || !directInterface(ifc.Name) {
			continue
		}
		addresses, _ := ifc.Addrs()
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil && ip.To4() != nil && ip.IsGlobalUnicast() {
				// Avoid choosing an arbitrary egress on a multihomed computer.
				if n.ipv4 != nil && !n.ipv4.Equal(ip) {
					n.ipv4 = nil
					return n, nil
				}
				n.ipv4 = ip
			}
		}
	}
	return n, nil
}
