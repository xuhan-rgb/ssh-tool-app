#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/open_macos_app.sh [options]

Options:
  --build-if-missing   Build the app if it does not exist
  --reveal             Reveal the app in Finder instead of launching it
  --print-path         Print the resolved app path and exit
  -h, --help           Show help

Examples:
  ./scripts/open_macos_app.sh
  ./scripts/open_macos_app.sh --build-if-missing
  ./scripts/open_macos_app.sh --reveal
EOF
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

find_built_app() {
  local release_dir=""

  for release_dir in \
    "$PROJECT_ROOT/build/macos_xcode/Build/Products/Release" \
    "$PROJECT_ROOT/build/macos/Build/Products/Release"; do
    if [[ -d "$release_dir" ]]; then
      find "$release_dir" -maxdepth 1 -type d -name '*.app' | head -n1
      return 0
    fi
  done

  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_macos_app.sh"

BUILD_IF_MISSING=0
REVEAL_ONLY=0
PRINT_PATH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-if-missing)
      BUILD_IF_MISSING=1
      shift
      ;;
    --reveal)
      REVEAL_ONLY=1
      shift
      ;;
    --print-path)
      PRINT_PATH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1 (use --help)"
      ;;
  esac
done

APP_PATH="$(find_built_app || true)"

if [[ -z "$APP_PATH" && "$BUILD_IF_MISSING" -eq 1 ]]; then
  [[ -x "$BUILD_SCRIPT" ]] || fail "Build script not found or not executable: $BUILD_SCRIPT"
  "$BUILD_SCRIPT"
  APP_PATH="$(find_built_app || true)"
fi

[[ -n "$APP_PATH" ]] || fail "No built app found. Run ./scripts/build_macos_app.sh first, or use --build-if-missing"

if [[ "$PRINT_PATH" -eq 1 ]]; then
  printf '%s\n' "$APP_PATH"
  exit 0
fi

if [[ "$REVEAL_ONLY" -eq 1 ]]; then
  open -R "$APP_PATH"
  exit 0
fi

open "$APP_PATH"
