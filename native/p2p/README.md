# Automatic SSH P2P

The app uses an authenticated existing SSH connection to deploy and start its
own Linux helper and exchange WebRTC/ICE signaling. No frp coordinator, XTCP
configuration, token or service name is entered by the user. Existing frp
installations are neither read nor modified. Built-in STUN servers perform
address discovery; this does not guarantee NAT traversal. No TURN relay is
configured. Failed direct setup returns to the original SSH transport.

The Android library and the helper use Pion WebRTC reliable ordered data
channels. Each TCP connection is carried by a separate data channel. The
helper connects to the local SSH listening port derived from SSH_CONNECTION,
not the public FRP forwarding port. SSH authentication still protects the new
SSH connection. A remote SSH banner is required before reporting P2P.
ICE excludes Tailscale, tun/tap and Mihomo interfaces on both endpoints, since
an overlay address can still carry traffic through a relay. Diagnostics record
the selected candidate addresses and types after a successful connection.
On Linux with a single usable physical IPv4 address, wildcard STUN sockets bind
to that source address. If system DNS returns a proxy Fake-IP (198.18.0.0/15),
the helper resolves that STUN hostname through 223.5.5.5 over TCP using the same source.
These changes apply only to helper sockets; no proxy, route or firewall
configuration is changed. Multiple physical IPv4 addresses retain system routing.

On first use the app uploads the CPU-specific helper with SFTP to
`~/.ssh_tool/p2p/agent-<SHA256>`, verifies its hash, and starts it as the SSH
user without sudo or systemd. Future connections reuse the verified binary.
The process is attached to a dedicated SSH command; it exits when the command
closes. The original SSH connection carries signaling and keeps the helper
alive, while direct SSH data goes over the P2P transport. App disconnect closes
the command and the native peer once no local session needs that connection.
The helper file remains available for the next connection.

Current platform support: Android phone, Linux x86_64/aarch64 computer with
SFTP and sha256sum. Unsupported computers keep ordinary SSH if fallback is on.
Credentials rejected by the original SSH server do not trigger P2P fallback.

Build: `scripts/build_p2p.sh`; `P2P_GO_ROOT` can point at a Go 1.21 installation.
It builds the Linux helpers and three Android ABIs using the existing Docker
SDK environment. `scripts/build_android.sh` invokes this before APK packaging.
Generated binaries are excluded from Git.

Checks: Go 1.21 `go test -race ./...` in this directory; Flutter tests
`test/p2p_service_test.dart`, `test/connection_form_p2p_test.dart` and related
connection/home tests. The native test transfers multiple TCP streams through
real loopback ICE peers. Physical-phone connectivity is a separate check and
can fail on a particular network even when the local transport checks pass.

Pion WebRTC is MIT licensed; see LICENSE.pion (also included in the APK).
