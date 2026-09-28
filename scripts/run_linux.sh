#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run_linux.sh
  ./scripts/run_linux.sh --help

启动当前源码的 Flutter Linux 桌面版。
宿主机有 Flutter 时直接运行，否则使用 flutter-dev:latest Docker 镜像。
EOF
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

run_with_host_flutter() {
  cd "$PROJECT_ROOT"
  flutter --no-version-check config --enable-linux-desktop >/dev/null
  exec flutter --no-version-check run -d linux
}

run_with_docker() {
  command -v docker >/dev/null 2>&1 || fail "未找到 flutter 或 docker。请先安装 Flutter，或安装 Docker。"
  docker image inspect flutter-dev:latest >/dev/null 2>&1 || fail \
    "未找到 flutter-dev:latest 镜像。请先构建 docker/flutter-dev/Dockerfile。"

  local -a docker_gpu_args=()
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    docker_gpu_args=(
      --gpus all
      --runtime=nvidia
      -e NVIDIA_DRIVER_CAPABILITIES=all
    )
  fi

  local -a docker_font_args=()
  if [[ -d /usr/share/fonts/truetype/wqy ]]; then
    docker_font_args=(
      -v
      /usr/share/fonts/truetype/wqy:/usr/local/share/fonts/wqy-host:ro
    )
  elif [[ -d /usr/share/fonts/opentype/noto ]]; then
    docker_font_args=(
      -v
      /usr/share/fonts/opentype/noto:/usr/local/share/fonts/noto-host:ro
    )
  fi

  if [[ -z "${DISPLAY:-}" ]]; then
    fail "未检测到 DISPLAY，Linux 桌面程序需要在图形桌面终端中运行。"
  fi

  if command -v xhost >/dev/null 2>&1; then
    xhost +local:docker >/dev/null 2>&1 || true
  fi

  exec docker run --rm -it \
    "${docker_gpu_args[@]}" \
    "${docker_font_args[@]}" \
    --network host \
    -e "DISPLAY=$DISPLAY" \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$PROJECT_ROOT":/workspace/ssh_tool_app \
    -v flutter-dev_flutter-pub-cache:/root/.pub-cache \
    -w /workspace/ssh_tool_app \
    flutter-dev:latest \
    bash -lc '
      linker_dir=/usr/lib/llvm-14/bin
      if [[ ! -d "$linker_dir" ]]; then
        echo "[ERROR] 容器缺少 LLVM 工具目录：$linker_dir" >&2
        exit 1
      fi
      if [[ ! -e "$linker_dir/ld.lld" && ! -e "$linker_dir/ld" ]]; then
        if [[ -x /usr/bin/ld ]]; then
          ln -s /usr/bin/ld "$linker_dir/ld"
        else
          echo "[ERROR] 容器缺少可用 linker：$linker_dir/ld" >&2
          exit 1
        fi
      fi
      if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f >/dev/null 2>&1 || true
      fi
      flutter --no-version-check config --enable-linux-desktop >/dev/null
      exec flutter --no-version-check run -d linux
    '
}

case "${1:-}" in
  "") ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    fail "未知参数: $1（使用 --help 查看用法）"
    ;;
esac

if command -v flutter >/dev/null 2>&1; then
  run_with_host_flutter
fi

run_with_docker
