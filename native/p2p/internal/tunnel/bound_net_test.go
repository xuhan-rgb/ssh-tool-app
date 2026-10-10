package tunnel

import (
	"github.com/pion/transport/v2/stdnet"
	"net"
	"testing"
)

func TestWildcardUDPUsesPhysicalSourceAddress(t *testing.T) {
	n := &boundNet{Net: &stdnet.Net{}, ipv4: net.ParseIP("127.0.0.2")}
	c, err := n.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.LocalAddr().(*net.UDPAddr).IP.String() != "127.0.0.2" {
		t.Fatal("STUN socket remained wildcard-bound and can enter the proxy route")
	}
	explicit, err := n.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer explicit.Close()
	if explicit.LocalAddr().(*net.UDPAddr).IP.String() != "127.0.0.1" {
		t.Fatal("explicit ICE host binding was changed")
	}
}

func TestProxyVirtualDNSAddressIsNotReturnedAsSTUNServer(t *testing.T) {
	n := &boundNet{Net: &stdnet.Net{}, ipv4: net.ParseIP("127.0.0.2")}
	if address, err := n.ResolveUDPAddr("udp4", "198.18.0.56:3478"); err == nil {
		t.Fatalf("proxy virtual address was accepted as a STUN server: %v", address)
	}
	address, err := n.ResolveUDPAddr("udp4", "192.0.2.1:3478")
	if err != nil || address.IP.String() != "192.0.2.1" || address.Port != 3478 {
		t.Fatalf("ordinary address was changed: %v %v", address, err)
	}
}
