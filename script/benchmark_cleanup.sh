#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_path="${WHISPRLOCAL_BENCHMARK_MODEL:-$HOME/Library/Application Support/WhisprLocal/BenchmarkModels/qwen2.5-3b-instruct-q4_k_m.gguf}"
server_path="${WHISPRLOCAL_LLAMA_SERVER:-$(command -v llama-server || true)}"
runs="${WHISPRLOCAL_BENCHMARK_RUNS:-3}"
prompt_profile="${WHISPRLOCAL_BENCHMARK_PROFILE:-local-plan}"
custom_expected_hash="${WHISPRLOCAL_BENCHMARK_EXPECTED_SHA256:-}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_path="${WHISPRLOCAL_BENCHMARK_OUTPUT:-$repo_root/.cleanup-benchmarks/$timestamp.json}"
binary_path="$repo_root/build/tools/CleanupBenchmark"
expected_05b_hash="74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
expected_15b_hash="6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
expected_3b_hash="626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d"
expected_lfm_hash="b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5"

if [[ -z "$server_path" || ! -x "$server_path" ]]; then
  echo "llama-server was not found. Install the Homebrew llama.cpp formula or set WHISPRLOCAL_LLAMA_SERVER." >&2
  exit 1
fi

if [[ ! -f "$model_path" ]]; then
  echo "Benchmark model was not found at: $model_path" >&2
  exit 1
fi

model_filename="$(basename "$model_path")"
expected_hash=""
if [[ "$model_filename" == "qwen2.5-0.5b-instruct-q4_k_m.gguf" ]]; then
  expected_hash="$expected_05b_hash"
elif [[ "$model_filename" == "qwen2.5-1.5b-instruct-q4_k_m.gguf" ]]; then
  expected_hash="$expected_15b_hash"
elif [[ "$model_filename" == "qwen2.5-3b-instruct-q4_k_m.gguf" ]]; then
  expected_hash="$expected_3b_hash"
elif [[ "$model_filename" == "LFM2.5-1.2B-Instruct-Q4_K_M.gguf" ]]; then
  expected_hash="$expected_lfm_hash"
elif [[ -n "$custom_expected_hash" ]]; then
  expected_hash="$custom_expected_hash"
else
  echo "No pinned SHA-256 is known for benchmark model: $model_filename" >&2
  echo "Set WHISPRLOCAL_BENCHMARK_EXPECTED_SHA256 to benchmark an explicit custom model." >&2
  exit 1
fi

if [[ ! "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Benchmark model SHA-256 must contain exactly 64 hexadecimal characters." >&2
  exit 1
fi

actual_hash="$(shasum -a 256 "$model_path" | awk '{print $1}')"
normalized_expected_hash="$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual_hash" != "$normalized_expected_hash" ]]; then
  echo "Benchmark model SHA-256 mismatch." >&2
  echo "Expected: $normalized_expected_hash" >&2
  echo "Actual:   $actual_hash" >&2
  exit 1
fi

mkdir -p "$repo_root/build/tools" "$(dirname "$output_path")"

xcrun swiftc \
  -O \
  "$repo_root/Tools/CleanupBenchmark/main.swift" \
  -o "$binary_path"

exec "$binary_path" \
  --server "$server_path" \
  --model "$model_path" \
  --profile "$prompt_profile" \
  --runs "$runs" \
  --output "$output_path"
