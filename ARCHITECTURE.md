# Architecture

WhisprLocal is an unsandboxed, hardened-runtime macOS 26 utility built with
SwiftUI and narrow AppKit bridges. `project.yml` is the XcodeGen source of
truth; the generated Xcode project is intentionally not committed.

## Runtime flow

1. `GlobalFnMonitor` observes Globe/Fn modifier changes in-process.
2. `MediaPlaybackService` concurrently invokes a bundled, state-aware MediaRemote adapter
   through `/usr/bin/perl`. The bridge performs one bounded
   pause-if-currently-playing operation and records pause ownership so the
   coordinator can later send an explicit Play command without toggle risk.
3. `AudioCaptureService` prepares AVAudioEngine off the main actor, optionally
   targets the Mac's built-in input without changing the system default, and
   waits for the first real buffer before reporting readiness. A bufferless
   start is retried once. It captures mono floating-point PCM and resamples to
   16 kHz without writing a file.
4. `DictationPipeline` runs detached from the main actor at user-initiated
   priority. It owns the complete transcription, cleanup, and snippet-expansion
   sequence so UI work cannot delay one stage from handing off to the next.
5. `ParakeetTranscriptionEngine` calls sherpa-onnx v1.13.4 directly. Dictionary
   terms and snippet triggers are SentencePiece-encoded and passed through the
   per-stream hotword API with modified beam search and score 1.5.
6. `LocalCleanupEngine` protects fragile values, then sends a deterministic
   conservative-cleanup request to the pinned Qwen2.5 3B model.
   `LlamaServerController` owns one bundled, signed `llama-server` helper on a
   random loopback port with an ephemeral API key and strict request deadline.
7. `SnippetExpander` performs Unicode-aware, whole-phrase, longest-first
   expansion.
8. `SystemPasteService` snapshots every pasteboard item/type, posts Command-V,
   waits for the destination to consume it, and restores the snapshot.
9. `LocalDatabase` stores the raw and corrected text and processing metadata.

`DictationCoordinator` is the only owner of the state machine:

`idle → preparing → listening → transcribing → correcting → pasting → succeeded → idle`

Fn release remains responsive during a slow Bluetooth route transition because
capture preparation does not run on the main actor. Cancellation and failure
transitions are explicit. Cleanup failure never loses the transcript: raw
Parakeet text is the fallback. A timeout terminates the exact owned helper
process; the next dictation starts a clean instance.

Only state publication, overlay updates, pasteboard/AppKit work, and database
view refreshes return to the main actor. Pipeline telemetry records both
background stage durations and pipeline-to-main-actor handoff delay so UI
contention is distinguishable from model latency.

## Process lifecycle

- `LSUIElement` and accessory activation keep the application out of the Dock
  while Settings is closed.
- Settings temporarily switches to regular activation so the app appears in the
  Dock. An optional `NSStatusItem` can reopen Settings or quit.
- A nonactivating `NSPanel` appears only for transient dictation state.
- Manual launch and reopen present Settings.
- `SMAppService.mainApp` registers launch at login. The login launch Apple event
  suppresses Settings so startup remains invisible.

## Local data

`~/Library/Application Support/WhisprLocal/whisprlocal.sqlite` contains only:

- `transcriptions`
- `dictionary`
- `snippets`

## Network boundary

The only external application network calls are explicit user-initiated model
downloads: the official Parakeet archive and the pinned Qwen2.5 GGUF file. Both
are SHA-256 verified before installation. Normal dictation, cleanup,
persistence, and paste have no external network path. Cleanup HTTP stays on
`127.0.0.1`, bypasses system proxies, and the helper runs with offline mode and
no web UI.

## Dependency reproducibility

- sherpa-onnx macOS XCFramework: v1.13.4, pinned URL and checksum
- ONNX Runtime package: pinned Git revision in both the local package manifest
  and `Package.resolved`
- llama.cpp b10180 (`11b068d06`): pinned release archive and SHA-256
- Qwen2.5 3B Instruct Q4_K_M: pinned revision, byte count, and SHA-256
- mediaremote-adapter v0.7.6: narrowed source adaptation with retained BSD
  3-Clause license, compiled locally as an arm64 framework
