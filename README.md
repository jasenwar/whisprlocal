# WhisprLocal

WhisprLocal is a private, fully local macOS dictation utility. Hold Globe/Fn,
speak, and release to transcribe with Parakeet Unified English, conservatively
clean the text with Apple's on-device Foundation Model, and paste it into the
application that was already focused.

The application has no account system, billing, cloud API, analytics, updater,
or Docker service. Its Dock icon appears only while Settings is open, and an
optional menu-bar icon can reopen Settings or quit. With the menu-bar icon off,
dictation continues running invisibly. WhisprLocal stores raw and corrected
text locally for recovery, but never stores microphone audio.

## Requirements

- Apple-silicon Mac running macOS 26 or newer
- Xcode 26 or newer
- Apple Intelligence enabled for optional grammar cleanup
- Microphone and Accessibility permissions

## Build

```sh
./script/build_and_run.sh build
./script/build_and_run.sh run
./script/build_and_run.sh test
./script/build_and_run.sh release
./script/build_and_run.sh verify
```

`release` produces a signed personal build at `dist/WhisprLocal.app`.

The first run clones an existing OpenWhispr Parakeet cache when available.
Otherwise, Model Setup in Settings downloads and verifies the official model
archive.

## Privacy

After explicit model setup, dictation and cleanup run offline. The local
database is stored at:

`~/Library/Application Support/WhisprLocal/whisprlocal.sqlite`

WhisprLocal can perform a one-time, read-only import of active transcription
text, dictionary entries, and snippets from an existing OpenWhispr database.
The original database and audio files are never modified.

## Upstream

WhisprLocal began as a hard fork of
[OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr). The native
rewrite intentionally diverges and preserves the upstream MIT license and
attribution in [UPSTREAM.md](UPSTREAM.md).

See [ARCHITECTURE.md](ARCHITECTURE.md) for the state machine, privacy boundary,
native dependency design, and persistence contract.
