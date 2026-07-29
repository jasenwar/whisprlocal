#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$repo_root/DerivedData"
scheme="WhisprLocal"
mode="${1:-run}"

generate_project() {
  command -v xcodegen >/dev/null || {
    echo "xcodegen is required (brew install xcodegen)." >&2
    exit 1
  }
  (cd "$repo_root" && xcodegen generate)
}

build_app() {
  generate_project
  xcodebuild \
    -project "$repo_root/WhisprLocal.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -derivedDataPath "$derived_data" \
    -destination "platform=macOS,arch=arm64" \
    build
}

case "$mode" in
  build)
    build_app
    ;;
  release)
    generate_project
    xcodebuild \
      -project "$repo_root/WhisprLocal.xcodeproj" \
      -scheme "$scheme" \
      -configuration Release \
      -derivedDataPath "$derived_data" \
      -destination "platform=macOS,arch=arm64" \
      clean build
    mkdir -p "$repo_root/dist"
    release_source="$derived_data/Build/Products/Release/WhisprLocal.app"
    release_destination="$repo_root/dist/WhisprLocal.app"
    if [[ -d "$release_destination" ]]; then
      mv "$release_destination" "$derived_data/WhisprLocal-previous-$RANDOM.app"
    fi
    /usr/bin/ditto "$release_source" "$release_destination"
    ;;
  run)
    build_app
    open "$derived_data/Build/Products/Debug/WhisprLocal.app"
    ;;
  debug)
    build_app
    lldb "$derived_data/Build/Products/Debug/WhisprLocal.app/Contents/MacOS/WhisprLocal"
    ;;
  log|logs)
    /usr/bin/log stream --style compact --predicate 'process == "WhisprLocal"'
    ;;
  telemetry)
    /usr/bin/log stream \
      --style compact \
      --level info \
      --predicate 'subsystem == "com.jasenguerra.whisprlocal" && (category == "AudioCapture" || category == "Transcription" || category == "Dictation")'
    ;;
  diagnostics)
    /usr/bin/log show \
      --last "${2:-10m}" \
      --style compact \
      --info \
      --predicate 'subsystem == "com.jasenguerra.whisprlocal" && (category == "AudioCapture" || category == "Transcription" || category == "Dictation")'
    ;;
  test)
    generate_project
    xcodebuild \
      -project "$repo_root/WhisprLocal.xcodeproj" \
      -scheme "$scheme" \
      -derivedDataPath "$derived_data" \
      -destination "platform=macOS,arch=arm64" \
      test
    ;;
  verify)
    build_app
    app="$derived_data/Build/Products/Debug/WhisprLocal.app"
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign -d --entitlements - "$app"
    /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$app/Contents/Info.plist"
    ;;
  *)
    echo "Usage: $0 {build|release|run|debug|log|telemetry|diagnostics|test|verify}" >&2
    exit 2
    ;;
esac
