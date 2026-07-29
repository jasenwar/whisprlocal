# Architecture

WhisprLocal is an unsandboxed, hardened-runtime macOS 26 utility built with
SwiftUI and narrow AppKit bridges. `project.yml` is the XcodeGen source of
truth; the generated Xcode project is intentionally not committed.

## Runtime flow

1. `GlobalFnMonitor` observes Globe/Fn modifier changes in-process.
2. `AudioCaptureService` captures mono floating-point PCM and resamples to
   16 kHz without writing a file.
3. `ParakeetTranscriptionEngine` calls sherpa-onnx v1.13.4 directly. Dictionary
   terms and snippet triggers are SentencePiece-encoded and passed through the
   per-stream hotword API with modified beam search and score 1.5.
4. `FoundationCleanupEngine` creates a fresh guided-output
   `LanguageModelSession` for conservative English cleanup.
5. `SnippetExpander` performs Unicode-aware, whole-phrase, longest-first
   expansion.
6. `SystemPasteService` snapshots every pasteboard item/type, posts Command-V,
   waits for the destination to consume it, and restores the snapshot.
7. `LocalDatabase` stores the raw and corrected text and processing metadata.

`DictationCoordinator` is the only owner of the state machine:

`idle → listening → transcribing → correcting → pasting → succeeded → idle`

Cancellation and failure transitions are explicit. Cleanup failure never loses
the transcript: raw Parakeet text is the fallback.

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

The only application network call is in `ModelManager.download`: an explicit
user-initiated download of the official Parakeet archive. The archive is
SHA-256 verified before extraction. Normal dictation, cleanup, persistence, and
paste have no network path.

## Dependency reproducibility

- sherpa-onnx macOS XCFramework: v1.13.4, pinned URL and checksum
- ONNX Runtime package: pinned Git revision in both the local package manifest
  and `Package.resolved`
- Apple Foundation Models: provided by macOS and not bundled
