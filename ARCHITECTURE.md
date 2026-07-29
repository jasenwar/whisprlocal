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

- `LSUIElement` and accessory activation keep the application out of the Dock.
- There is no `NSStatusItem` or `MenuBarExtra`.
- A nonactivating `NSPanel` appears only for transient dictation state.
- Manual launch and reopen present Settings.
- The embedded `WhisprLocalLoginHelper` starts the main executable with
  `--background`, producing no window.

## Local data

`~/Library/Application Support/WhisprLocal/whisprlocal.sqlite` contains only:

- `transcriptions`
- `dictionary`
- `snippets`
- `migration_metadata`

The legacy importer opens OpenWhispr SQLite data read-only and imports active
text, dictionary entries, and snippets once. It does not read, copy, change, or
delete legacy audio.

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
