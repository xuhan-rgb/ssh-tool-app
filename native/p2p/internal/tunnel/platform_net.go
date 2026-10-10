package tunnel

import (
	"fmt"
	"github.com/pion/transport/v2"
	"github.com/pion/transport/v2/stdnet"
	"net"
	"strings"
	"sync/atomic"
)

// InterfaceSnapshot comes from Android's supported NetworkInterface API.
type InterfaceSnapshot struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	Addresses []string `json:"addresses"`
}

// Socket/DNS operations use ordinary permitted Go APIs, but interface discovery
// uses the snapshot so it never creates an Android-restricted netlink socket.
type platformNet struct {
	*stdnet.Net
	interfaces []*transport.Interface
	packets    *PacketCounts
}

func newPlatformNet(snapshots []InterfaceSnapshot) (*platformNet, error) {
	n := &platformNet{Net: &stdnet.Net{}, packets: &PacketCounts{}}
	for _, snapshot := range snapshots {
		ifc := transport.NewInterface(net.Interface{Index: snapshot.Index, Name: snapshot.Name, Flags: net.FlagUp})
		for _, address := range snapshot.Addresses {
			ip := net.ParseIP(strings.Split(address, "%")[0])
			if ip == nil || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
				continue
			}
			ifc.AddAddress(&net.IPAddr{IP: ip})
		}
		if addresses, _ := ifc.Addrs(); len(addresses) > 0 {
			n.interfaces = append(n.interfaces, ifc)
		}
	}
	if len(n.interfaces) == 0 {
		return nil, fmt.Errorf("手机未获取到可用网络地址")
	}
	return n, nil
}

// Pion v3's candidate-pair request counters are unimplemented. Count actual
// socket operations so diagnostics never interpret those zero values as traffic.
type PacketCounts struct {
	Sent, Received, SendErrors atomic.Uint64
	LastSendError              atomic.Value
}

type countedUDP struct {
	transport.UDPConn
	packets *PacketCounts
}

func iceCheck(data []byte) bool {
	if len(data) <= 20 || data[0] >= 4 || data[4] != 0x21 || data[5] != 0x12 || data[6] != 0xa4 || data[7] != 0x42 {
		return false
	}
	for offset := 20; offset+4 <= len(data); {
		typ := uint16(data[offset])<<8 | uint16(data[offset+1])
		length := int(data[offset+2])<<8 | int(data[offset+3])
		if offset+4+length > len(data) {
			return false
		}
		if typ == 0x0006 || typ == 0x0008 { // USERNAME / MESSAGE-INTEGRITY
			return true
		}
		offset += 4 + (length+3)&^3
	}
	return false
}

func (c *countedUDP) WriteTo(data []byte, address net.Addr) (int, error) {
	n, err := c.UDPConn.WriteTo(data, address)
	if iceCheck(data) {
		if err != nil {
			c.packets.SendErrors.Add(1)
			c.packets.LastSendError.Store(err.Error())
		} else {
			c.packets.Sent.Add(1)
		}
	}
	return n, err
}

func (c *countedUDP) ReadFrom(data []byte) (int, net.Addr, error) {
	n, address, err := c.UDPConn.ReadFrom(data)
	if n > 0 && iceCheck(data[:n]) {
		c.packets.Received.Add(1)
	}
	return n, address, err
}

func (n *platformNet) ListenUDP(network string, address *net.UDPAddr) (transport.UDPConn, error) {
	conn, err := n.Net.ListenUDP(network, address)
	if err != nil {
		return nil, err
	}
	return &countedUDP{UDPConn: conn, packets: n.packets}, nil
}
func (n *platformNet) Interfaces() ([]*transport.Interface, error) { return n.interfaces, nil }
func (n *platformNet) InterfaceByIndex(index int) (*transport.Interface, error) {
	for _, ifc := range n.interfaces {
		if ifc.Index == index {
			return ifc, nil
		}
	}
	return nil, transport.ErrInterfaceNotFound
}
func (n *platformNet) InterfaceByName(name string) (*transport.Interface, error) {
	for _, ifc := range n.interfaces {
		if ifc.Name == name {
			return ifc, nil
		}
	}
	return nil, transport.ErrInterfaceNotFound
}
