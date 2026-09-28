#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_macos_app.sh [options]

Options:
  --skip-clean         Skip "flutter clean"
  --open               Open the built app after success
  --derived-data <dir> Override Xcode derived data directory
  -h, --help           Show help

Examples:
  ./scripts/build_macos_app.sh
  ./scripts/build_macos_app.sh --skip-clean
  ./scripts/build_macos_app.sh --open
EOF
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"
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

setup_utf8_env() {
  export LANG="en_US.UTF-8"
  export LC_ALL="en_US.UTF-8"
  export LC_CTYPE="en_US.UTF-8"
}

setup_local_cocoapods_env() {
  setup_utf8_env
  if [[ "$USE_SYSTEM_COCOAPODS" -eq 1 ]]; then
    return
  fi
  export GEM_HOME="$COCOAPODS_GEM_HOME"
  export GEM_PATH="$COCOAPODS_GEM_HOME"
  export PATH="$COCOAPODS_BIN_DIR:$PATH"
}

ensure_local_cocoapods() {
  if command -v pod >/dev/null 2>&1 && pod --version >/dev/null 2>&1; then
    USE_SYSTEM_COCOAPODS=1
    return
  fi

  mkdir -p "$COCOAPODS_BIN_DIR"

  if [[ ! -x "$PORTABLE_RUBY_BIN" || ! -x "$PORTABLE_GEM_BIN" ]]; then
    fail "Homebrew portable-ruby not found. Expected: $PORTABLE_RUBY_BIN"
  fi

  ln -sf "$PORTABLE_RUBY_BIN" "$COCOAPODS_BIN_DIR/ruby"

  if setup_local_cocoapods_env && pod --version >/dev/null 2>&1; then
    return
  fi

  echo "  installing local CocoaPods via portable-ruby"
  GEM_HOME="$COCOAPODS_GEM_HOME" \
  GEM_PATH="$COCOAPODS_GEM_HOME" \
  "$PORTABLE_GEM_BIN" install cocoapods -N --clear-sources --source "$COCOAPODS_GEM_SOURCE"

  ln -sf "$PORTABLE_RUBY_BIN" "$COCOAPODS_BIN_DIR/ruby"

  if ! (setup_local_cocoapods_env && pod --version >/dev/null 2>&1); then
    fail "CocoaPods installation failed"
  fi
}

find_built_app() {
  find "$DERIVED_DATA_PATH/Build/Products/Release" -maxdepth 1 -type d -name '*.app' | head -n1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_CLEAN=0
OPEN_APP=0
DERIVED_DATA_PATH="$PROJECT_ROOT/build/macos_xcode"

COCOAPODS_GEM_HOME="${COCOAPODS_GEM_HOME:-$HOME/.local/cocoapods-gem}"
COCOAPODS_BIN_DIR="$COCOAPODS_GEM_HOME/bin"
COCOAPODS_GEM_SOURCE="${COCOAPODS_GEM_SOURCE:-https://gems.ruby-china.com/}"
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix 2>/dev/null || printf /opt/homebrew)}"
PORTABLE_RUBY_BIN="$HOMEBREW_PREFIX/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"
PORTABLE_GEM_BIN="$HOMEBREW_PREFIX/Library/Homebrew/vendor/portable-ruby/current/bin/gem"
USE_SYSTEM_COCOAPODS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-clean)
      SKIP_CLEAN=1
      shift
      ;;
    --open)
      OPEN_APP=1
      shift
      ;;
    --derived-data)
      [[ $# -ge 2 ]] || fail "Missing value for --derived-data"
      DERIVED_DATA_PATH="$2"
      shift 2
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

need_cmd flutter
need_cmd xcode-select
need_cmd xcrun
require_xcode_for_macos_build

cd "$PROJECT_ROOT"

if [[ "$SKIP_CLEAN" -eq 0 ]]; then
  echo "[1/5] flutter clean"
  flutter clean
else
  echo "[1/5] skip flutter clean"
fi

echo "[2/5] flutter pub get"
flutter pub get

echo "[3/5] ensure local CocoaPods"
ensure_local_cocoapods

echo "[4/5] pod install + flutter config"
(
  setup_local_cocoapods_env
  cd "$PROJECT_ROOT/macos"
  pod install
)

(
  setup_local_cocoapods_env
  flutter build macos --release --config-only --no-pub
)

echo "[5/5] xcodebuild release"
setup_utf8_env
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$(find_built_app)"
[[ -n "$APP_PATH" ]] || fail "No .app found in $DERIVED_DATA_PATH/Build/Products/Release"

echo
echo "Build success:"
echo "  APP: $APP_PATH"
echo
echo "Run:"
echo "  open \"$APP_PATH\""

if [[ "$OPEN_APP" -eq 1 ]]; then
  open "$APP_PATH"
fi
