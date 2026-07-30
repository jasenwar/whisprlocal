# Local cleanup benchmark

This development-only harness measures a local GGUF cleanup model without
changing WhisprLocal's production dictation pipeline.

It launches a private `llama-server` process bound to `127.0.0.1`, disables the
web UI and network model access, waits for the health endpoint, performs one
warmup request, and runs synthetic dictation fixtures. The child process is
terminated when the benchmark exits.

## Requirements

- Homebrew `llama.cpp`
- A local GGUF model

The default model is the production Qwen2.5 3B Instruct Q4_K_M file at:

`~/Library/Application Support/WhisprLocal/BenchmarkModels/qwen2.5-3b-instruct-q4_k_m.gguf`

For that filename, the runner requires SHA-256:

`626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d`

The runner also recognizes the previously evaluated Qwen2.5 0.5B and 1.5B
candidates and requires their pinned SHA-256 values:

`74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`

`6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`

The official LiquidAI LFM2.5 1.2B Instruct Q4_K_M candidate requires
SHA-256:

`b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5`

## Run

```sh
script/benchmark_cleanup.sh
```

Results and the server log are written to `.cleanup-benchmarks/`, which is
excluded from Git. Override inputs without editing the script:

```sh
WHISPRLOCAL_BENCHMARK_MODEL=/path/to/model.gguf \
WHISPRLOCAL_BENCHMARK_EXPECTED_SHA256=<64-character-sha256> \
WHISPRLOCAL_BENCHMARK_RUNS=5 \
script/benchmark_cleanup.sh
```

Unknown model filenames are rejected unless an explicit expected SHA-256 is
provided. The fixtures are synthetic and cover fillers, names, email
addresses, quantities, self-correction, already-clean text, prompt-like
dictation, spoken punctuation, meaningful hesitation words, quotation marks,
list intent, and Windows paths.
The report records the exact runtime version, model hash, startup time, warmup
time, warm-request latency, raw outputs, and deterministic validation results.
It reports both raw model validation and the production-shaped result after
safe first-letter capitalization and terminal punctuation.

Two immutable prompt profiles can be compared against the same fixtures:

```sh
WHISPRLOCAL_BENCHMARK_PROFILE=local-plan script/benchmark_cleanup.sh
WHISPRLOCAL_BENCHMARK_PROFILE=openwhispr script/benchmark_cleanup.sh
WHISPRLOCAL_BENCHMARK_PROFILE=hybrid script/benchmark_cleanup.sh
```

`local-plan` is the Literal prompt from the local cleanup implementation plan.
`openwhispr` is the current upstream OpenWhispr English cleanup prompt and
transcript wrapper, with the dynamic assistant name fixed to `Assistant` for
repeatable measurements.
`hybrid` retains the safer Literal contract and adds narrow upstream-inspired
self-correction and quoted-instruction guidance.
