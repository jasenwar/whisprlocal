@preconcurrency import AppKit
import OSLog

private let soundEffectLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "SoundEffects"
)

@MainActor
final class SoundEffectPlayer: NSObject, NSSoundDelegate {
    private var activeSounds: [ObjectIdentifier: NSSound] = [:]

    func play(named name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            soundEffectLogger.error(
                "System sound is unavailable: \(name, privacy: .public)"
            )
            return
        }

        sound.stop()
        sound.delegate = self
        sound.volume = 1
        activeSounds[ObjectIdentifier(sound)] = sound

        if sound.play() {
            soundEffectLogger.info(
                "Played system sound: \(name, privacy: .public)"
            )
        } else {
            activeSounds.removeValue(forKey: ObjectIdentifier(sound))
            soundEffectLogger.error(
                "System sound failed to play: \(name, privacy: .public)"
            )
        }
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        Task { @MainActor [weak self] in
            self?.activeSounds.removeValue(forKey: ObjectIdentifier(sound))
        }
    }
}
