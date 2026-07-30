# Local cleanup model decision

Date: 2026-07-30

WhisprLocal benchmarked local cleanup through a private, loopback-only
`llama-server` process using Metal, one prompt-cache slot, a 2,048-token
context, temperature 0, and synthetic dictation fixtures. No production
dictation history was used.

## Selected candidate

Qwen2.5 3B Instruct Q4_K_M with the Literal `local-plan` prompt is the
production candidate.

- Model size: 2,104,932,768 bytes
- Model SHA-256:
  `626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d`
- Pinned model revision:
  `7dabda4d13d513e3e842b20f0d435c732f172cbe`
- Runtime: llama.cpp b10180 (`11b068d06`)
- Runtime archive SHA-256:
  `789f717355fb2574becfaa70601714c78908bd1e5d6c6cadd6b8ccc98060d0f7`
- License: Apache-2.0 model, MIT runtime

Latest three-round result with the expanded production regression matrix:

- Server startup: 647 ms
- Prompt warmup: 714 ms
- Warm median: 290 ms
- Warm P95: 1,617 ms
- Prompt cache reuse: 500 cached tokens per measured request
- Production-shaped validation: 39/39

Short fixtures took 186–423 ms. The medium technical request took 673–897 ms.
The longest fixture took 1,336–1,621 ms. Safe deterministic finalization
supplied missing initial capitalization and terminal punctuation. The expanded
matrix also covers spoken punctuation, meaningful uses of "actually",
protected quoted speech, list intent, and Windows paths in addition to names,
email addresses, technical identifiers, quantities, prompt-like dictated text,
and explicit self-corrections.

## Rejected candidates

- Qwen2.5 0.5B Q4_K_M was very fast but deleted prompt-like dictated content
  and missed explicit self-correction.
- Qwen2.5 1.5B Q4_K_M preserved prompt-like text but still missed the explicit
  self-correction.
- LiquidAI LFM2.5 1.2B Q4_K_M was slower, reported no prompt-cache reuse, and
  twice returned a few-shot example instead of the supplied transcript.
- The current upstream OpenWhispr prompt did not outperform the safer Literal
  prompt on these fixtures; it dropped part of the prompt-like sentence.

## Production boundary

Production integration implements the benchmark boundary:

1. The model installer verifies the pinned byte count and SHA-256 and exposes
   status and download progress in Settings.
2. One owned helper listens on a random loopback port, requires an ephemeral
   API key, bypasses proxies, disables the web UI, and runs offline.
3. Word-count deadlines recycle the exact helper process on timeout. Health is
   checked before reuse, so a stale process is restarted after sleep or failure.
4. Dictionary terms, numeric values, URLs, addresses, identifiers, paths,
   commands, and code are protected with exact placeholders.
5. Empty, oversized, formatted, or placeholder-altering output is rejected.
   Raw Parakeet text remains the fallback on every failure.
6. Fn press prewarms transcription and seeds the cleanup prompt cache
   concurrently. The helper exits after ten idle minutes and on normal
   application termination.
7. A conservative request-budget estimate rejects transcripts that cannot fit
   the 2,048-token context, and timeouts use a short forced-recycle grace so raw
   fallback is not delayed.
