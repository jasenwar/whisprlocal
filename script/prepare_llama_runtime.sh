#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_tag="b10180"
archive_name="llama-b10180-bin-macos-arm64.tar.gz"
archive_sha256="789f717355fb2574becfaa70601714c78908bd1e5d6c6cadd6b8ccc98060d0f7"
archive_url="https://github.com/ggml-org/llama.cpp/releases/download/$runtime_tag/$archive_name"
cache_directory="$repo_root/.runtime-cache"
archive_path="$cache_directory/$archive_name"
destination="$repo_root/Vendor/LocalCleanupRuntime"

mkdir -p "$cache_directory" "$destination"

verify_archive() {
  local actual_hash
  actual_hash="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  [[ "$actual_hash" == "$archive_sha256" ]]
}

if [[ ! -f "$archive_path" ]] || ! verify_archive; then
  temporary_archive="$cache_directory/$archive_name.download"
  curl -L --fail --output "$temporary_archive" "$archive_url"
  downloaded_hash="$(shasum -a 256 "$temporary_archive" | awk '{print $1}')"
  if [[ "$downloaded_hash" != "$archive_sha256" ]]; then
    echo "llama.cpp runtime SHA-256 mismatch." >&2
    echo "Expected: $archive_sha256" >&2
    echo "Actual:   $downloaded_hash" >&2
    exit 1
  fi
  mv "$temporary_archive" "$archive_path"
fi

extraction_root="$(mktemp -d)"
trap 'rm -rf "$extraction_root"' EXIT
tar -xzf "$archive_path" -C "$extraction_root"
source_directory="$extraction_root/llama-b10180"

for required_file in llama-server LICENSE; do
  if [[ ! -f "$source_directory/$required_file" ]]; then
    echo "Official runtime archive is missing $required_file." >&2
    exit 1
  fi
  /usr/bin/ditto "$source_directory/$required_file" "$destination/$required_file"
done

while IFS= read -r library; do
  /usr/bin/ditto "$library" "$destination/$(basename "$library")"
done < <(
  find "$source_directory" -maxdepth 1 \
    \( -type f -o -type l \) \
    -name '*.dylib' \
    -print
)

chmod 755 "$destination/llama-server" "$destination"/*.dylib

embedded_version="$("$destination/llama-server" --version 2>&1 | head -1)"
if [[ "$embedded_version" != *"10180"* ]]; then
  echo "Unexpected embedded llama-server version: $embedded_version" >&2
  exit 1
fi

echo "Prepared llama.cpp $runtime_tag in $destination"
