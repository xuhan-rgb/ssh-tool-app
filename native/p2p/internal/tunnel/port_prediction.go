package tunnel

import (
	"net"
	"strconv"
	"strings"

	"github.com/pion/ice/v2"
	"github.com/pion/webrtc/v3"
)

// A destination-dependent NAT can allocate a nearby port for the peer instead
// of the STUN server. These are only candidates: ICE authentication must still
// validate the path before DTLS or SSH data is sent.
func withPredictedRemotePorts(desc webrtc.SessionDescription) webrtc.SessionDescription {
	lines := strings.Split(desc.SDP, "\n")
	seen := make(map[string]bool)
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) >= 8 && strings.HasPrefix(fields[0], "a=candidate:") {
			seen[fields[1]+":"+fields[2]+":"+fields[4]+":"+fields[5]] = true
		}
	}
	var result []string
	for _, line := range lines {
		result = append(result, line)
		if !strings.HasPrefix(line, "a=candidate:") {
			continue
		}
		candidate, err := ice.UnmarshalCandidate(strings.TrimSpace(strings.TrimPrefix(line, "a=candidate:")))
		if err != nil || candidate.Type() != ice.CandidateTypeServerReflexive || candidate.NetworkType() != ice.NetworkTypeUDP4 {
			continue
		}
		ip := net.ParseIP(candidate.Address())
		v4 := ip.To4()
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || v4 == nil ||
			(v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127) || proxyDNSAddress(ip) {
			continue
		}
		fields := strings.Fields(line)
		for offset := 1; offset <= 32 && candidate.Port()+offset <= 65535; offset++ {
			predicted := append([]string(nil), fields...)
			predicted[5] = strconv.Itoa(candidate.Port() + offset)
			key := predicted[1] + ":" + predicted[2] + ":" + predicted[4] + ":" + predicted[5]
			if seen[key] {
				continue
			}
			seen[key] = true
			predicted[0] += "p" + strconv.Itoa(offset)
			priority := candidate.Priority()
			if priority > uint32(offset) {
				priority -= uint32(offset)
			}
			predicted[3] = strconv.FormatUint(uint64(priority), 10)
			suffix := ""
			if strings.HasSuffix(line, "\r") {
				suffix = "\r"
			}
			result = append(result, strings.Join(predicted, " ")+suffix)
		}
	}
	desc.SDP = strings.Join(result, "\n")
	return desc
}
