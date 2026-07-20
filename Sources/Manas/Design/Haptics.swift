import AppKit

/// Thin wrapper over the trackpad's haptic engine. Force Touch trackpads turn
/// these into physical taps; on hardware without haptics (or when the user has
/// turned "Force Click and haptic feedback" off) the calls are simply ignored,
/// so callers never need to check. Every call hops to the main actor because
/// the performer is main-thread only.
@MainActor
enum Haptics {
    /// A light tap for landing keyboard selection on a row.
    static func tap() { perform(.levelChange) }

    /// The firmest feedback we can produce. macOS exposes no intensity control
    /// and only three fixed patterns, so "stronger" means stacking strikes:
    /// two quick `.levelChange` hits a beat apart land as one solid thunk
    /// rather than a single light tick. Used for every drag event (lift, each
    /// row the card passes, bucket crossings, drop) and the swipe threshold.
    static func bump() {
        perform(.levelChange)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(26))
            perform(.levelChange)
        }
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
