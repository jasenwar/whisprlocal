# WhisprLocal

WhisprLocal is a privacy-first, fully local macOS dictation utility. Hold Globe/Fn,
speak, and release to transcribe with Parakeet Unified English, conservatively
clean the text with a pinned on-device Qwen2.5 3B model, and paste it into the
application that was already focused. Cleanup can be disabled independently.

The application has no account system, billing, cloud API, analytics, updater,
or Docker service. Its Dock icon appears only while Settings is open, and an
optional menu-bar icon can reopen Settings or quit. With the menu-bar icon off,
dictation continues running invisibly. WhisprLocal stores raw and corrected
text locally for recovery, but never stores microphone audio. The transient
dictation overlay can be placed at six top or bottom screen positions.
Launch at login uses a bundled, signed helper that starts the main app with an
explicit background argument; manual opening remains the only path that shows
Settings and the Dock icon.

The microphone setting offers **System Default** and **Mac Microphone**.
System Default follows macOS Sound settings, including AirPods. Mac Microphone
keeps the built-in input active while audio continues through AirPods, avoiding
Bluetooth profile-switch delays. Capture preparation runs off the main thread,
waits for a real input buffer, and retries once if the device starts without
delivering audio.

The **Pause media while dictating** setting pauses the active macOS Now Playing
session as microphone preparation begins and resumes it when recording finishes
or is cancelled. Media that was already paused is left paused. Media control
runs concurrently so it cannot delay microphone startup. A narrowly adapted
copy of OpenWhispr's state-aware MediaRemote bridge performs explicit Pause
and Play commands locally, avoiding unreliable direct private-framework state
queries and unsafe play/pause toggles.

## Requirements

- Apple-silicon Mac running macOS 26 or newer
- Xcode 26 or newer
- Microphone and Accessibility permissions

## Install

Download the latest ZIP from
[GitHub Releases](https://github.com/jasenwar/whisprlocal/releases/latest),
move `WhisprLocal.app` to Applications, and run:

```sh
xattr -cr /Applications/WhisprLocal.app
open /Applications/WhisprLocal.app
```

This personal build is Apple Development signed but not notarized for public
distribution.

## Build

```sh
./script/build_and_run.sh build
./script/build_and_run.sh run
./script/build_and_run.sh test
./script/build_and_run.sh release
./script/build_and_run.sh verify
```

`release` produces a signed personal build at `dist/WhisprLocal.app`.

The first run clones existing Parakeet and local-cleanup model caches when
available. Otherwise, Model Setup in Settings downloads and verifies the
official model files. The cleanup model is a separate 2.1 GB download.

## Privacy

After explicit model setup, dictation and cleanup run offline. The local
cleanup helper listens only on a random loopback port, requires an ephemeral
API key, disables its web UI and network model access, and is terminated when
WhisprLocal quits. The local database is stored at:

`~/Library/Application Support/WhisprLocal/whisprlocal.sqlite`

## Upstream

WhisprLocal began as a hard fork of
[OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr). The native
rewrite intentionally diverges and preserves the upstream MIT license and
attribution in [UPSTREAM.md](UPSTREAM.md).

The bundled MediaRemote adapter is adapted from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
v0.7.6 under its BSD 3-Clause license. Its source and license are retained in
`Vendor/MediaRemoteAdapter`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the state machine, privacy boundary,
native dependency design, and persistence contract.
