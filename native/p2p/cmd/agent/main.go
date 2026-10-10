package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"github.com/pion/webrtc/v3"
	"os"
	"ssh-tool-app/p2p/internal/tunnel"
	"time"
)

func main() {
	// No listener on the LAN, no root, no system service installation. This process
	// is scoped to its SSH command and exits when that command/channel closes.
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	if !scanner.Scan() {
		return
	}
	var request struct {
		Offer webrtc.SessionDescription `json:"offer"`
		Port  int                       `json:"port"`
	}
	if json.Unmarshal(scanner.Bytes(), &request) != nil {
		fail("P2P 协商请求无效")
		return
	}
	peer, err := tunnel.New(tunnel.STUNServers)
	if err != nil {
		fail("P2P 辅助程序启动失败")
		return
	}
	defer peer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	answer, err := peer.Answer(ctx, request.Offer, request.Port)
	cancel()
	if err != nil {
		fail("P2P 协商失败")
		return
	}
	json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"answer": answer})
	eof := make(chan struct{})
	go func() {
		for scanner.Scan() {
		}
		close(eof)
	}()
	select {
	case <-eof:
	case <-peer.Done:
	}
}
func fail(message string) { fmt.Printf("{\"error\":%q}\n", message) }
