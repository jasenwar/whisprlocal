#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$repo_root/Vendor/MediaRemoteAdapter"
output_root="${1:-$repo_root/DerivedData/MediaRemoteRuntime}"

if [[ "$output_root" != /* ]]; then
  output_root="$PWD/$output_root"
fi

if [[ "${output_root##*/}" != "MediaRemoteRuntime" || "$output_root" == "/MediaRemoteRuntime" ]]; then
  echo "Refusing unsafe MediaRemote runtime output path: $output_root" >&2
  exit 1
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/whisprlocal-mediaremote.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT

runtime_root="$staging_root/MediaRemoteRuntime"
framework_root="$runtime_root/MediaRemoteAdapter.framework"
version_root="$framework_root/Versions/A"

mkdir -p "$version_root/Resources"
ln -s A "$framework_root/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$framework_root/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$framework_root/Resources"

/usr/bin/ditto "$source_root/Info.plist" "$version_root/Resources/Info.plist"
/usr/bin/ditto "$source_root/mediaremote-adapter.pl" "$runtime_root/mediaremote-adapter.pl"
/usr/bin/ditto "$source_root/LICENSE" "$runtime_root/LICENSE"
/usr/bin/ditto "$source_root/VERSION" "$runtime_root/VERSION"

/usr/bin/xcrun clang \
  -fobjc-arc \
  -fblocks \
  -fvisibility=default \
  -O2 \
  -target arm64-apple-macos26.0 \
  "$source_root/WhisprLocalMediaRemoteAdapter.m" \
  -dynamiclib \
  -Wl,-install_name,@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -compatibility_version 1.0.0 \
  -current_version 0.7.6 \
  -framework Foundation \
  -o "$version_root/MediaRemoteAdapter"

/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  "$framework_root"

mkdir -p "$(dirname "$output_root")"
if [[ -e "$output_root" ]]; then
  rm -rf "$output_root"
fi
mv "$runtime_root" "$output_root"

echo "Built MediaRemote runtime at $output_root"
