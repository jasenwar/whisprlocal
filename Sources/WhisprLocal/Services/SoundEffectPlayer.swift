@preconcurrency import AppKit
import OSLog

private let soundEffectLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "SoundEffects"
)

@MainActor
final class SoundEffectPlayer {
    private let sounds: [String: NSSound]

    init() {
        sounds = Dictionary(
            uniqueKeysWithValues: ["Tink", "Pop", "Glass", "Basso", "Funk"]
                .compactMap { name in
                    NSSound(named: NSSound.Name(name)).map { (name, $0) }
                }
        )
        sounds.values.forEach { $0.volume = 1 }
    }

    func play(named name: String) {
        guard let sound = sounds[name] else {
            soundEffectLogger.error(
                "System sound is unavailable: \(name, privacy: .public)"
            )
            return
        }

        sound.stop()
        sound.volume = 1
        let started = ContinuousClock.now

        if sound.play() {
            let acceptanceDelay = (
                ContinuousClock.now - started
            ).timeInterval
            soundEffectLogger.info(
                "Played cached system sound: \(name, privacy: .public) acceptanceDelay=\(acceptanceDelay, format: .fixed(precision: 3), privacy: .public)s"
            )
        } else {
            soundEffectLogger.error(
                "System sound failed to play: \(name, privacy: .public)"
            )
        }
    }
}
