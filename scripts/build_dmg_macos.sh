#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_dmg_macos.sh [options]

Options:
  --version <x.y.z>    Set dmg version suffix (default: read from pubspec.yaml)
  --name <AppName>     Override volume/app name shown in dmg
  --output <dir>       Output directory (default: ./dist)
  --skip-clean         Skip "flutter clean"
  --skip-build         Skip macOS app build
  --open               Open dmg after build
  -h, --help           Show help

Examples:
  ./scripts/build_dmg_macos.sh
  ./scripts/build_dmg_macos.sh --version 1.0.1 --open
  ./scripts/build_dmg_macos.sh --skip-clean --name "SSH Tool App"
EOF
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_xcode_for_macos_build() {
  local xcode_path=""
  xcode_path="$(xcode-select -p 2>/dev/null || true)"

  if [[ -z "$xcode_path" ]]; then
    fail "Xcode Command Line Tools not configured. Run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi

  if ! xcrun --find xcodebuild >/dev/null 2>&1; then
    fail "xcodebuild not found. Install full Xcode, then run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"
}

find_release_app() {
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

APP_VERSION=""
APP_NAME_OVERRIDE=""
OUTPUT_DIR="$PROJECT_ROOT/dist"
SKIP_CLEAN=0
SKIP_BUILD=0
OPEN_DMG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "Missing value for --version"
      APP_VERSION="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || fail "Missing value for --name"
      APP_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "Missing value for --output"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-clean)
      SKIP_CLEAN=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --open)
      OPEN_DMG=1
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must run on macOS (Darwin)."
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  fail "Only Apple Silicon (arm64) is supported in this build flow."
fi

need_cmd hdiutil

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  need_cmd flutter
  need_cmd xcode-select
  need_cmd xcrun
  require_xcode_for_macos_build
fi

cd "$PROJECT_ROOT"

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' pubspec.yaml | head -n1)"
fi
[[ -n "$APP_VERSION" ]] || APP_VERSION="0.0.0"

if [[ "$SKIP_CLEAN" -eq 0 ]]; then
  if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "[1/5] clean enabled"
  else
    echo "[1/5] clean skipped because build is skipped"
  fi
else
  echo "[1/5] skip flutter clean"
fi

echo "[2/5] prepare macOS app build"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  [[ -x "$BUILD_SCRIPT" ]] || fail "Build script not found or not executable: $BUILD_SCRIPT"

  echo "[3/5] build macOS app"
  BUILD_ARGS=()
  if [[ "$SKIP_CLEAN" -eq 1 ]]; then
    BUILD_ARGS+=(--skip-clean)
  fi
  "$BUILD_SCRIPT" "${BUILD_ARGS[@]}"
else
  echo "[3/5] skip flutter build"
fi

APP_PATH="$(find_release_app || true)"
[[ -n "$APP_PATH" ]] || fail "No .app found in build outputs"

APP_BASENAME="$(basename "$APP_PATH" .app)"
APP_NAME="${APP_NAME_OVERRIDE:-$APP_BASENAME}"
DMG_FILENAME="$(echo "${APP_NAME}-${APP_VERSION}-macos-arm64.dmg" | tr ' ' '_')"

OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"
STAGE_DIR="$OUTPUT_DIR/dmg-root"
DMG_PATH="$OUTPUT_DIR/$DMG_FILENAME"

echo "[4/5] stage app for dmg"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "[5/5] create dmg"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo
echo "Build success:"
echo "  APP: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo
echo "Install:"
echo "  open \"$DMG_PATH\""

if [[ "$OPEN_DMG" -eq 1 ]]; then
  open "$DMG_PATH"
fi
