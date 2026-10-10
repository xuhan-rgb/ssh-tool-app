package tunnel

import (
	"github.com/pion/webrtc/v3"
	"strings"
	"testing"
)

func TestPredictedRemotePortsKeepSignalingAndBoundProbeRange(t *testing.T) {
	sdp := "v=0\r\na=ice-ufrag:unchanged\r\na=ice-pwd:unchanged-password\r\na=candidate:1 1 udp 1694498815 124.127.79.158 44721 typ srflx raddr 10.79.153.182 rport 51100\r\na=end-of-candidates\r\n"
	got := withPredictedRemotePorts(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: sdp})
	if !strings.Contains(got.SDP, "124.127.79.158 44722 typ srflx") {
		t.Fatal("destination-dependent next port was not probed")
	}
	if strings.Count(got.SDP, "a=candidate:") != 33 {
		t.Fatal("predictions must be limited to 32 nearby ports")
	}
	if got.Type != webrtc.SDPTypeOffer || !strings.Contains(got.SDP, "a=ice-pwd:unchanged-password\r\n") {
		t.Fatal("signaling credentials changed")
	}
	if !strings.Contains(got.SDP, "124.127.79.158 44753 typ srflx") || strings.Contains(got.SDP, "124.127.79.158 44754 typ srflx") {
		t.Fatal("probe range is incorrect")
	}
}

func TestPredictedRemotePortsSkipPrivateHostRelayIPv6AndInvalidCandidates(t *testing.T) {
	sdp := "a=candidate:1 1 udp 1694498815 192.168.30.63 40000 typ srflx\r\na=candidate:2 1 udp 1694498815 100.71.145.96 40000 typ srflx\r\na=candidate:3 1 udp 1694498815 103.93.204.162 40000 typ host\r\na=candidate:4 1 udp 1694498815 103.93.204.162 40000 typ relay\r\na=candidate:5 1 udp 1694498815 240e::1 40000 typ srflx\r\na=candidate:invalid\r\n"
	if got := withPredictedRemotePorts(webrtc.SessionDescription{SDP: sdp}); got.SDP != sdp {
		t.Fatal("non-public UDP IPv4 reflexive candidates were expanded")
	}
}

func TestPredictedRemotePortsDoNotWrapAtPortLimit(t *testing.T) {
	sdp := "a=candidate:1 1 udp 1694498815 124.127.79.158 65534 typ srflx\r\n"
	got := withPredictedRemotePorts(webrtc.SessionDescription{SDP: sdp})
	if strings.Count(got.SDP, "a=candidate:") != 2 || !strings.Contains(got.SDP, " 65535 typ srflx") {
		t.Fatal("port range overflowed")
	}
}
