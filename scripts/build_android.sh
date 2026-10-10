#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_home="${HOME}/.android"

command -v docker >/dev/null 2>&1 || { echo "未找到 Docker" >&2; exit 1; }
[[ -f "$android_home/debug.keystore" ]] || {
  echo "缺少 $android_home/debug.keystore，无法保持 Android APK 签名一致" >&2
  exit 1
}

"$project_root/scripts/build_p2p.sh"

docker run --rm \
  -v "$project_root":/workspace/ssh_tool_app \
  -v "$android_home":/root/.android \
  -v "${HOME}/.gradle":/root/.gradle \
  -v ssh_tool_app_android_sdk:/opt/android-sdk \
  -v flutter-dev_flutter-pub-cache:/root/.pub-cache \
  -w /workspace/ssh_tool_app \
  flutter-dev:latest \
  flutter --no-version-check build apk --debug "$@"

echo "APK: $project_root/build/app/outputs/flutter-apk/app-debug.apk"
