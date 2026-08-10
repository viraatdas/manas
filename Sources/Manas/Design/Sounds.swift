import AVFoundation
import Foundation

#if os(macOS)
import AppKit
#endif

/// The app's one sound: a short pop when a todo is checked off.
///
/// Synthesised rather than shipped as an asset, and rather than borrowing
/// macOS's `/System/Library/Sounds/Pop.aiff`, so both platforms make exactly
/// the same noise. A system sound exists on the Mac and has no counterpart on
/// the phone, and the undocumented iOS `AudioServices` ids are neither stable
/// nor tuned — one generated waveform is the only way the two feel like the
/// same app.
///
/// Off by default. The apps switch it on at launch; tests, previews and
/// verification runs never make a sound they didn't ask for.
@MainActor
enum Sounds {
    /// Opt-in, so nothing that merely constructs an `AppStore` starts playing
    /// audio. `ManasApp` and `ManasIOSApp` turn it on.
    static var isEnabled = false

    /// A todo just became done.
    ///
    /// Deliberately silent when a todo is *un*-checked: the pop is the sound
    /// of finishing something, and hearing it while undoing reads as the app
    /// misunderstanding what you did.
    static func pop() {
        guard isEnabled, respectsSystemPreference else { return }
        // Completing a run of todos quickly should sound like a run of pops,
        // not one smear — but a held key repeating at 30Hz should not machine
        // gun either.
        let now = ContinuousClock.now
        if let lastPlayed, now - lastPlayed < minInterval { return }
        lastPlayed = now
        prepareSessionIfNeeded()
        nextPlayer()?.play()
    }

    // MARK: - Politeness

    /// macOS has a global "Play user interface sound effects" switch and an app
    /// that ignores it is a rude app. iOS has no equivalent toggle — the ring
    /// switch does the job there, which the `.ambient` category already honours.
    private static var respectsSystemPreference: Bool {
        #if os(macOS)
        // Absent key means "on", which is the system default.
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
        #else
        true
        #endif
    }

    #if os(iOS)
    private static var hasPreparedSession = false
    #endif

    /// `.ambient` + `.mixWithOthers`: a todo app must never stop somebody's
    /// music to announce that a checkbox moved, and `.ambient` is silenced by
    /// the ring switch, which is exactly the behaviour a UI sound should have.
    private static func prepareSessionIfNeeded() {
        #if os(iOS)
        guard !hasPreparedSession else { return }
        hasPreparedSession = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: - Playback

    private static let minInterval: Duration = .milliseconds(70)
    private static var lastPlayed: ContinuousClock.Instant?

    /// A small ring of players. One player restarted mid-sound cuts itself off,
    /// so two pops close together would clip the first; rotating lets them
    /// overlap and ring out the way real clicks do.
    private static var players: [AVAudioPlayer] = []
    private static var nextIndex = 0

    private static func nextPlayer() -> AVAudioPlayer? {
        if players.isEmpty {
            guard let data = popWAV else { return nil }
            players = (0..<3).compactMap { _ in
                let player = try? AVAudioPlayer(data: data)
                player?.volume = 0.35   // a UI tick, not an alert
                player?.prepareToPlay()
                return player
            }
        }
        guard !players.isEmpty else { return nil }
        let player = players[nextIndex % players.count]
        nextIndex += 1
        player.currentTime = 0
        return player
    }

    /// Built once and kept: the buffer is a few kilobytes and rebuilding it per
    /// tap would allocate on the main thread during an animation.
    static let popWAV: Data? = makePopWAV()

    /// A pop is a very short tone that drops in pitch as it dies away — the
    /// sound of something small and hollow being flicked. A pure decaying sine
    /// reads as a beep; the downward sweep is what makes it a pop.
    ///
    /// Exposed (rather than private) so a test can prove the bytes really are
    /// playable audio instead of merely non-empty.
    static func makePopWAV(
        sampleRate: Double = 44_100,
        duration: Double = 0.075,
        startFrequency: Double = 920,
        endFrequency: Double = 430
    ) -> Data? {
        let frameCount = Int(sampleRate * duration)
        guard frameCount > 0 else { return nil }

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        // Long enough that the onset is not a click, short enough to still
        // read as instant.
        let attack = 0.002
        let decay = 0.020
        var phase = 0.0
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let sweep = t / duration
            // Integrate the swept frequency rather than using `sin(2πft)`
            // directly: with f changing, the latter jumps phase every sample
            // and buzzes instead of sliding.
            let frequency = startFrequency + (endFrequency - startFrequency) * sweep
            phase += 2 * .pi * frequency / sampleRate
            let envelope = min(t / attack, 1) * exp(-t / decay)
            let value = sin(phase) * envelope
            samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max) * 0.9))
        }
        return wav(samples: samples, sampleRate: Int(sampleRate))
    }

    /// A minimal 16-bit mono RIFF/WAVE container.
    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data()

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append32(16)            // PCM header size
        append16(1)             // PCM, uncompressed
        append16(1)             // mono
        append32(sampleRate)
        append32(sampleRate * bytesPerSample)
        append16(bytesPerSample)
        append16(16)            // bits per sample
        append("data")
        append32(dataBytes)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
