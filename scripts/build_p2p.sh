#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/ssh-tool-app"
go_root="${P2P_GO_ROOT:-${FRP_GO_ROOT:-$cache_root/go1.21.13/go}}"
if [[ ! -x "$go_root/bin/go" ]]; then
  mkdir -p "$cache_root/go1.21.13"
  curl --fail --location --retry 3 https://dl.google.com/go/go1.21.13.linux-amd64.tar.gz -o "$cache_root/go1.21.13.tar.gz"
  tar -xzf "$cache_root/go1.21.13.tar.gz" -C "$cache_root/go1.21.13"
fi
mkdir -p "$cache_root/gomod" "$cache_root/gobuild" "$project_root/assets/p2p"
docker run --rm --network host --env HTTP_PROXY --env HTTPS_PROXY \
  -v "$project_root":/workspace -v "$go_root":/opt/go:ro \
  -v "$cache_root/gomod":/root/go/pkg/mod -v "$cache_root/gobuild":/root/.cache/go-build \
  -v ssh_tool_app_android_sdk:/opt/android-sdk \
  -w /workspace/native/p2p flutter-dev:latest bash -c '
    set -euo pipefail
    for arch in amd64 arm64; do
      GOOS=linux GOARCH="$arch" CGO_ENABLED=0 /opt/go/bin/go build -buildvcs=false -ldflags "-s -w" -o "/workspace/assets/p2p/agent-linux-$arch" ./cmd/agent
    done
    export GOOS=android CGO_ENABLED=1
    toolchain=/opt/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin
    for target in "arm64 arm64-v8a aarch64-linux-android21" "arm armeabi-v7a armv7a-linux-androideabi21" "amd64 x86_64 x86_64-linux-android21"; do
      read -r GOARCH abi compiler <<< "$target"
      export GOARCH CC="$toolchain/$compiler-clang" GOARM=7
      output="/workspace/android/app/src/main/jniLibs/$abi"
      mkdir -p "$output"
      /opt/go/bin/go build -buildvcs=false -buildmode=c-shared -ldflags "-s -w -extldflags=-Wl,-z,max-page-size=16384" -o "$output/libsshp2p.so" ./cmd/android
      if [[ -e "$output/libsshp2p.h" ]]; then rm -- "$output/libsshp2p.h"; fi
    done
  '
