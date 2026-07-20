import AppKit

/// Thin wrapper over the trackpad's haptic engine. Force Touch trackpads turn
/// these into physical taps; on hardware without haptics (or when the user has
/// turned "Force Click and haptic feedback" off) the calls are simply ignored,
/// so callers never need to check. Every call hops to the main actor because
/// the performer is main-thread only.
@MainActor
enum Haptics {
    /// A light tap for landing keyboard selection on a row.
    static func tap() { perform(.generic) }

    /// The firm "snap into place" pattern (levelChange is the most pronounced
    /// of the three system patterns). Used for the frequent taps while
    /// dragging a card past each row and for committing a drop, so the drag
    /// feels physical and clicky rather than subtle.
    static func bump() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
