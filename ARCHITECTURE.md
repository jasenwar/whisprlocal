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
5. In Groq Preferred mode, `HybridTranscriptionEngine` sends the in-memory WAV
   payload to Groq Whisper and falls back to `ParakeetTranscriptionEngine` when
   the selected Groq path is unavailable or limited. Fully Local mode uses
   Parakeet directly. A shared vocabulary planner ranks enabled, applicable
   preferred spellings and snippet triggers. Groq receives a deduplicated,
   token-bounded spelling prompt; Parakeet receives exact SentencePiece
   per-stream hotwords through modified beam search. Pinned entries receive a
   bounded score boost above the 1.5 default. Unsupported local hotwords are
   counted and skipped without exposing vocabulary text in logs.
6. `VocabularyResolver` applies preferred capitalization and reviewed spoken
   variants before cleanup. Matching is Unicode-aware, whole-phrase,
   longest-first, app-scoped, and nonrecursive. The original engine transcript
   remains unchanged in History for recovery and review.
7. `HybridCleanupEngine` first requests conservative cleanup from the selected
   Groq model. Preservation failures get one independent Groq safety-model
   attempt before `LocalCleanupEngine` takes over. Capability- and model-scoped
   cooldowns prevent one Groq failure from disabling unrelated paths. The local
   engine protects fragile values, then sends a deterministic request to the
   pinned Qwen2.5 3B model.
   `LlamaServerController` owns one bundled, signed `llama-server` helper on a
   random loopback port with an ephemeral API key and strict request deadline.
   A deterministic preservation validator rejects deleted sentence boundaries
   or substantial content loss, causing the pipeline to paste the intact raw
   transcript instead.
8. `SnippetExpander` performs a single Unicode-aware, whole-phrase,
   longest-first expansion pass after cleanup.
9. `SystemPasteService` snapshots every pasteboard item/type, posts Command-V,
   and schedules a guarded restore after the destination has consumed it. A
   transient ownership marker prevents the restore from overwriting anything
   the user copies during the handoff, and restoration does not hold up the
   visible dictation pipeline.
10. `LocalDatabase` stores the raw and corrected text and processing metadata.

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
- A nonactivating `NSPanel` appears only for transient dictation state. It owns
  one fixed-size `NSHostingController` for its lifetime and updates that
  controller in place, avoiding synchronous layout, controller replacement,
  resize, animation, and window-order churn between dictation stages. The
  material is clipped to the capsule with no panel-edge shadow, so the
  surrounding panel corners remain fully transparent.
- Manual launch and reopen present Settings.
- `SMAppService.loginItem` registers a tiny bundled helper in
  `Contents/Library/LoginItems`. The helper launches the main app with an
  explicit `--background` argument and without activation, then exits. This
  keeps startup invisible without relying on timing-sensitive login Apple
  events. Existing `SMAppService.mainApp` registrations are migrated in place,
  and the helper registration follows the signed app when it is upgraded or
  moved.

## Local data

`~/Library/Application Support/WhisprLocal/whisprlocal.sqlite` contains only:

- `transcriptions`
- `dictionary`
- `snippets`

Dictionary schema migrations are transactional and preserve legacy terms.
Each entry stores a preferred spelling, reviewed spoken variants, term type,
enabled state, pinned priority, optional application scope, source, and local
usage metadata. When the user enables **Learn from corrections**, a read-only
Accessibility monitor briefly follows only the exact range that WhisprLocal
just pasted. High-confidence spelling, name, acronym, and compact phrase edits
can become global dictionary aliases. Secure fields, unsupported editors,
focus drift, ambiguous rewrites, grammar-only changes, numbers, URLs, paths,
and commands fail closed. Surrounding document text is neither logged nor
persisted, and the latest learned batch can be undone from Dictionary. A typed
learning event is emitted only after the database refresh succeeds. The shared
nonactivating overlay presents its confirmed mappings transiently, queues them
behind active dictation, and never writes those private terms to system logs.

## Network boundary

Groq Preferred mode sends recorded audio to Groq for transcription and sends
the transcript to Groq for cleanup. If context awareness is enabled, application
metadata and selected text are included; Focused Window mode may also include
an in-memory JPEG of only the focused window. Screenshots and microphone audio
are never persisted. The user-provided Groq key is stored in macOS Keychain.

Fully Local mode makes no runtime network requests after model setup. The only
external requests in that mode are explicit user-initiated downloads of the
official Parakeet archive and pinned Qwen2.5 GGUF file, both SHA-256 verified.
Local cleanup HTTP stays on `127.0.0.1`, bypasses system proxies, and the helper
runs with offline mode and no web UI. Persistence and paste never use a network
path in either mode.

## Dependency reproducibility

- sherpa-onnx macOS XCFramework: v1.13.4, pinned URL and checksum
- ONNX Runtime package: pinned Git revision in both the local package manifest
  and `Package.resolved`
- llama.cpp b10180 (`11b068d06`): pinned release archive and SHA-256
- Qwen2.5 3B Instruct Q4_K_M: pinned revision, byte count, and SHA-256
- mediaremote-adapter v0.7.6: narrowed source adaptation with retained BSD
  3-Clause license, compiled locally as an arm64 framework
