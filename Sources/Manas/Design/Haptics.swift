#if os(macOS)
import AppKit

/// Thin wrapper over the trackpad's haptic engine. Force Touch trackpads turn
/// these into physical taps; on hardware without haptics (or when the user has
/// turned "Force Click and haptic feedback" off) the calls are simply ignored,
/// so callers never need to check. Every call hops to the main actor because
/// the performer is main-thread only.
@MainActor
enum Haptics {
    /// The performer drives a physical actuator, and each `perform` is a
    /// synchronous main-thread IOKit call. Asking it to fire faster than it can
    /// render distinct taps does two bad things: the taps smear into one
    /// continuous buzz (the "scratch" felt when a drag sweeps quickly across
    /// many rows), and the flood of synchronous calls starves the render loop
    /// so the window visibly stutters. So every request is coalesced — at most
    /// one strike sequence plays at a time, and starts are spaced by
    /// `minInterval`. A deliberate move (events well apart) still fires in full;
    /// a frantic sweep collapses to a few firm taps instead of a smear.
    private static let minInterval: Duration = .milliseconds(60)
    private static var lastStart: ContinuousClock.Instant?
    private static var sequenceInFlight = false

    /// A light tap for landing keyboard selection on a row.
    static func tap() { fire(strikes: 1) }

    /// The firmest feedback we can produce. macOS exposes no intensity control
    /// and only three fixed patterns, so "stronger" means stacking strikes:
    /// three quick `.levelChange` hits a beat apart land as one heavy thunk
    /// rather than a light tick. Used for every drag event (lift, each row the
    /// card passes, bucket crossings, drop) and the swipe threshold.
    static func bump() { fire(strikes: 3) }

    /// Fires up to `strikes` `.levelChange` hits as one felt event, but only if
    /// the actuator is idle and enough time has passed since the last sequence
    /// began. Requests that arrive mid-sequence or inside the interval are
    /// dropped, which is what keeps rapid movement from flooding the main thread.
    private static func fire(strikes: Int) {
        guard !sequenceInFlight else { return }
        let now = ContinuousClock.now
        if let lastStart, now - lastStart < minInterval { return }
        lastStart = now

        perform(.levelChange)
        guard strikes > 1 else { return }
        sequenceInFlight = true
        Task { @MainActor in
            defer { sequenceInFlight = false }
            for _ in 1..<strikes {
                try? await Task.sleep(for: .milliseconds(22))
                perform(.levelChange)
            }
        }
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

#else
import UIKit

/// The same haptic surface as the mac build, backed by the Taptic Engine. The
/// two calls keep their mac semantics — `tap()` for landing on a row, `bump()`
/// for the firm drag/threshold thunk — so shared call sites feel equivalent on
/// both platforms. iOS generators self-throttle far better than the trackpad
/// performer, but the same coalescing keeps a frantic sweep from smearing.
@MainActor
enum Haptics {
    private static let minInterval: Duration = .milliseconds(60)
    private static var lastStart: ContinuousClock.Instant?

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// A light tap for landing selection on a row.
    static func tap() { fire(light, intensity: 0.7) }

    /// The firmest feedback we produce — drag lifts, row passes, drops, and
    /// crossed thresholds.
    static func bump() { fire(rigid, intensity: 1.0) }

    private static func fire(_ generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        let now = ContinuousClock.now
        if let lastStart, now - lastStart < minInterval { return }
        lastStart = now
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
    }
}
#endif
