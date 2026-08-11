import AppKit

/// Subtle system sounds for lifecycle events — mirrors the original's
/// SoundManager (start pop, end tink, approval ping; mute toggle).
enum SoundManager {
    enum Kind {
        case start
        case end
        case alert
    }

    static func play(_ kind: Kind, volume: Double = 0.7) {
        let name: String
        switch kind {
        case .start: name = "Pop"
        case .end: name = "Tink"
        case .alert: name = "Ping"
        }
        guard let sound = NSSound(named: name) else {
            NSLog("CoderBar system sound is unavailable: %@", name)
            return
        }
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
    }
}
