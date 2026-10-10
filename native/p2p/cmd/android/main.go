package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/pion/webrtc/v3"
	"ssh-tool-app/p2p/internal/tunnel"
	"sync"
	"time"
	"unsafe"
)

type entry struct {
	peer *tunnel.Peer
	port int
}

var peers = struct {
	sync.Mutex
	entries map[string]*entry
}{entries: make(map[string]*entry)}

func response(value interface{}) *C.char { b, _ := json.Marshal(value); return C.CString(string(b)) }

//export P2pLookup
func P2pLookup(input *C.char) *C.char {
	peers.Lock()
	defer peers.Unlock()
	e := peers.entries[C.GoString(input)]
	if e != nil && e.port != 0 {
		select {
		case <-e.peer.Done:
			delete(peers.entries, C.GoString(input))
			e.peer.Close()
		default:
			return response(map[string]interface{}{"port": e.port})
		}
	}
	return response(map[string]interface{}{})
}

//export P2pOffer
func P2pOffer(input *C.char) *C.char {
	var request struct {
		ID         string                     `json:"id"`
		Interfaces []tunnel.InterfaceSnapshot `json:"interfaces"`
	}
	if json.Unmarshal([]byte(C.GoString(input)), &request) != nil || request.ID == "" {
		return response(map[string]interface{}{"error": "手机 P2P 网络参数无效"})
	}
	id := request.ID
	peers.Lock()
	defer peers.Unlock()
	if e := peers.entries[id]; e != nil {
		e.peer.Close()
		delete(peers.entries, id)
	}
	p, err := tunnel.New(tunnel.STUNServers, request.Interfaces)
	if err != nil {
		return response(map[string]interface{}{"error": "手机 P2P 客户端启动失败: " + err.Error()})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	offer, err := p.Offer(ctx)
	if err != nil {
		p.Close()
		return response(map[string]interface{}{"error": "手机 P2P 协商失败: " + err.Error()})
	}
	peers.entries[id] = &entry{peer: p}
	return response(map[string]interface{}{"offer": offer})
}

//export P2pAnswer
func P2pAnswer(input *C.char) *C.char {
	var request struct {
		ID     string                    `json:"id"`
		Answer webrtc.SessionDescription `json:"answer"`
	}
	if json.Unmarshal([]byte(C.GoString(input)), &request) != nil {
		return response(map[string]interface{}{"error": "P2P 协商应答无效"})
	}
	peers.Lock()
	defer peers.Unlock()
	e := peers.entries[request.ID]
	if e == nil {
		return response(map[string]interface{}{"error": "P2P 协商已结束"})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	port, err := e.peer.Connect(ctx, request.Answer)
	if err != nil {
		packets := e.peer.PacketCounts
		message := err.Error()
		if packets != nil && packets.Sent.Load() > 0 && packets.Received.Load() == 0 {
			message = fmt.Sprintf("%s；手机已发出 %d 次探测，未收到对端响应", err, packets.Sent.Load())
		} else if packets != nil && packets.Sent.Load() == 0 {
			if sendErr := packets.LastSendError.Load(); sendErr != nil {
				message += "；手机 UDP 发送失败: " + sendErr.(string)
			}
		}
		e.peer.Close()
		delete(peers.entries, request.ID)
		return response(map[string]interface{}{"error": message})
	}
	e.port = port
	result := map[string]interface{}{"port": port}
	pair, pairErr := e.peer.PC.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if pairErr == nil && pair != nil {
		result["candidatePair"] = map[string]interface{}{
			"localAddress": pair.Local.Address, "remoteAddress": pair.Remote.Address,
			"localType": pair.Local.Typ.String(), "remoteType": pair.Remote.Typ.String(),
		}
	}
	return response(result)
}

//export P2pStop
func P2pStop(input *C.char) *C.char {
	peers.Lock()
	defer peers.Unlock()
	id := C.GoString(input)
	if e := peers.entries[id]; e != nil {
		e.peer.Close()
		delete(peers.entries, id)
	}
	return response(map[string]interface{}{})
}

//export P2pFree
func P2pFree(ptr *C.char) { C.free(unsafe.Pointer(ptr)) }
func main()               {}
