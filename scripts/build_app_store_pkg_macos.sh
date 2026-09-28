#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_app_store_pkg_macos.sh [options]

Build a signed macOS .pkg that can be uploaded to App Store Connect.

Options:
  --bundle-id <id>               Override bundle identifier
  --team-id <id>                 Apple Developer Team ID
  --app-name <name>              Override product/app name
  --version <x.y.z>              Override marketing version (default: pubspec.yaml)
  --build-number <n>             Override build number (default: pubspec.yaml)
  --installer-identity <name>    Override installer certificate common name
  --output <dir>                 Output directory (default: ./dist/app_store)
  --archive-path <path>          Archive path (default: ./build/macos_app_store/Runner.xcarchive)
  --skip-clean                   Skip "flutter clean"
  --allow-provisioning-updates   Allow Xcode to fetch/manage provisioning profiles
  --open                         Reveal generated pkg in Finder after success
  -h, --help                     Show help

Examples:
  ./scripts/build_app_store_pkg_macos.sh \
    --team-id ABCDE12345 \
    --bundle-id com.example.ssh-tool-app

  ./scripts/build_app_store_pkg_macos.sh \
    --team-id ABCDE12345 \
    --bundle-id com.example.ssh-tool-app \
    --version 1.0.0 \
    --build-number 12 \
    --allow-provisioning-updates
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
  export GEM_HOME="$COCOAPODS_GEM_HOME"
  export GEM_PATH="$COCOAPODS_GEM_HOME"
  export PATH="$COCOAPODS_BIN_DIR:$PATH"
}

ensure_local_cocoapods() {
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

read_xcconfig_value() {
  local key="$1"
  sed -nE "s/^${key}[[:space:]]*=[[:space:]]*(.*)/\\1/p" "$APP_INFO_XCCONFIG" | head -n1 | sed 's/[[:space:]]*$//'
}

read_pubspec_version_name() {
  sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' "$PROJECT_ROOT/pubspec.yaml" | head -n1
}

read_pubspec_build_number() {
  sed -nE 's/^version:[[:space:]]*[^+[:space:]]+\+([[:digit:]]+).*/\1/p' "$PROJECT_ROOT/pubspec.yaml" | head -n1
}

resolve_project_path() {
  local path="$1"

  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$PROJECT_ROOT/$path"
  fi
}

find_archived_app() {
  find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name '*.app' | head -n1
}

pick_installer_identity() {
  local identity=""

  while IFS= read -r identity; do
    [[ -n "$identity" ]] || continue
    if [[ "$identity" == Mac\ Installer\ Distribution:* ]]; then
      printf '%s\n' "$identity"
      return 0
    fi
  done < <(security find-identity -v 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p')

  while IFS= read -r identity; do
    [[ -n "$identity" ]] || continue
    if [[ "$identity" == 3rd\ Party\ Mac\ Developer\ Installer:* ]]; then
      printf '%s\n' "$identity"
      return 0
    fi
  done < <(security find-identity -v 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p')

  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_INFO_XCCONFIG="$PROJECT_ROOT/macos/Runner/Configs/AppInfo.xcconfig"

SKIP_CLEAN=0
ALLOW_PROVISIONING_UPDATES=0
OPEN_PKG=0

APP_BUNDLE_ID="${APPSTORE_BUNDLE_ID:-}"
TEAM_ID="${APPSTORE_TEAM_ID:-}"
APP_NAME_OVERRIDE=""
APP_VERSION="${APPSTORE_VERSION:-}"
BUILD_NUMBER="${APPSTORE_BUILD_NUMBER:-}"
INSTALLER_IDENTITY="${APPSTORE_INSTALLER_IDENTITY:-}"
OUTPUT_DIR="$PROJECT_ROOT/dist/app_store"
ARCHIVE_PATH="$PROJECT_ROOT/build/macos_app_store/Runner.xcarchive"

COCOAPODS_GEM_HOME="${COCOAPODS_GEM_HOME:-$HOME/.local/cocoapods-gem}"
COCOAPODS_BIN_DIR="$COCOAPODS_GEM_HOME/bin"
COCOAPODS_GEM_SOURCE="${COCOAPODS_GEM_SOURCE:-https://gems.ruby-china.com/}"
PORTABLE_RUBY_BIN="/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"
PORTABLE_GEM_BIN="/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/gem"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id)
      [[ $# -ge 2 ]] || fail "Missing value for --bundle-id"
      APP_BUNDLE_ID="$2"
      shift 2
      ;;
    --team-id)
      [[ $# -ge 2 ]] || fail "Missing value for --team-id"
      TEAM_ID="$2"
      shift 2
      ;;
    --app-name)
      [[ $# -ge 2 ]] || fail "Missing value for --app-name"
      APP_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "Missing value for --version"
      APP_VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || fail "Missing value for --build-number"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --installer-identity)
      [[ $# -ge 2 ]] || fail "Missing value for --installer-identity"
      INSTALLER_IDENTITY="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "Missing value for --output"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --archive-path)
      [[ $# -ge 2 ]] || fail "Missing value for --archive-path"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --skip-clean)
      SKIP_CLEAN=1
      shift
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
      ;;
    --open)
      OPEN_PKG=1
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

need_cmd flutter
need_cmd xcode-select
need_cmd xcrun
need_cmd xcodebuild
need_cmd security
need_cmd codesign
need_cmd productbuild
need_cmd pkgutil
require_xcode_for_macos_build

[[ -f "$APP_INFO_XCCONFIG" ]] || fail "Missing config file: $APP_INFO_XCCONFIG"

if [[ -z "$APP_BUNDLE_ID" ]]; then
  APP_BUNDLE_ID="$(read_xcconfig_value PRODUCT_BUNDLE_IDENTIFIER || true)"
fi
if [[ -z "$APP_NAME_OVERRIDE" ]]; then
  APP_NAME_OVERRIDE="$(read_xcconfig_value PRODUCT_NAME || true)"
fi
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(read_pubspec_version_name)"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(read_pubspec_build_number)"
fi

[[ -n "$APP_BUNDLE_ID" ]] || fail "Missing bundle identifier. Pass --bundle-id <id> or update $APP_INFO_XCCONFIG"
[[ "$APP_BUNDLE_ID" != com.example.* ]] || fail "Bundle identifier is still the default placeholder. Pass --bundle-id <id> or update $APP_INFO_XCCONFIG"
[[ -n "$TEAM_ID" ]] || fail "Missing Apple Developer Team ID. Pass --team-id <TEAMID> or set APPSTORE_TEAM_ID"
[[ -n "$APP_NAME_OVERRIDE" ]] || fail "Missing app name. Update PRODUCT_NAME in $APP_INFO_XCCONFIG or pass --app-name"
[[ -n "$APP_VERSION" ]] || fail "Missing app version. Update pubspec.yaml or pass --version"
[[ -n "$BUILD_NUMBER" ]] || fail "Missing build number. Update pubspec.yaml or pass --build-number"

OUTPUT_DIR="$(resolve_project_path "$OUTPUT_DIR")"
ARCHIVE_PATH="$(resolve_project_path "$ARCHIVE_PATH")"
PKG_FILENAME="$(echo "${APP_NAME_OVERRIDE}-${APP_VERSION}+${BUILD_NUMBER}-appstore.pkg" | tr ' ' '_')"
PKG_PATH="$OUTPUT_DIR/$PKG_FILENAME"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY="$(pick_installer_identity || true)"
fi
[[ -n "$INSTALLER_IDENTITY" ]] || fail "No installer signing identity found. Install a \"Mac Installer Distribution\" certificate or pass --installer-identity"

cd "$PROJECT_ROOT"

if [[ "$SKIP_CLEAN" -eq 0 ]]; then
  echo "[1/8] flutter clean"
  flutter clean
else
  echo "[1/8] skip flutter clean"
fi

echo "[2/8] flutter pub get"
flutter pub get

echo "[3/8] ensure local CocoaPods"
ensure_local_cocoapods

echo "[4/8] pod install"
(
  setup_local_cocoapods_env
  cd "$PROJECT_ROOT/macos"
  pod install
)

echo "[5/8] prepare Flutter macOS build settings"
(
  setup_local_cocoapods_env
  flutter build macos --release --config-only --no-pub --build-name "$APP_VERSION" --build-number "$BUILD_NUMBER"
)

echo "[6/8] archive signed macOS app"
setup_utf8_env
XCODEBUILD_ARGS=(
  -workspace macos/Runner.xcworkspace
  -scheme Runner
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  -destination "generic/platform=macOS"
  DEVELOPMENT_TEAM="$TEAM_ID"
  PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"
  PRODUCT_NAME="$APP_NAME_OVERRIDE"
  CODE_SIGN_STYLE=Automatic
)
if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  XCODEBUILD_ARGS+=(-allowProvisioningUpdates)
fi
XCODEBUILD_ARGS+=(archive)
xcodebuild "${XCODEBUILD_ARGS[@]}"

APP_PATH="$(find_archived_app || true)"
[[ -n "$APP_PATH" ]] || fail "No archived .app found in $ARCHIVE_PATH/Products/Applications"
[[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]] || fail "Archived app is missing embedded.provisionprofile. Check App Store signing/provisioning."

echo "[7/8] verify signed app"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

echo "[8/8] package signed installer"
rm -f "$PKG_PATH"
productbuild \
  --component "$APP_PATH" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  "$PKG_PATH"
pkgutil --check-signature "$PKG_PATH" >/dev/null

echo
echo "Build success:"
echo "  Archive: $ARCHIVE_PATH"
echo "  App:     $APP_PATH"
echo "  PKG:     $PKG_PATH"
echo
echo "Upload to App Store Connect with:"
echo "  Transporter, Xcode Organizer, or xcrun altool using the generated .pkg"

if [[ "$OPEN_PKG" -eq 1 ]]; then
  open -R "$PKG_PATH"
fi
