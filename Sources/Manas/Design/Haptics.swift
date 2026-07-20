import AppKit

/// Thin wrapper over the trackpad's haptic engine. Force Touch trackpads turn
/// these into physical taps; on hardware without haptics (or when the user has
/// turned "Force Click and haptic feedback" off) the calls are simply ignored,
/// so callers never need to check. Every call hops to the main actor because
/// the performer is main-thread only.
@MainActor
enum Haptics {
    /// A light tap for picking a card up or landing selection on a row.
    static func tap() { perform(.generic) }

    /// The "snap into place" pattern, for when a dragged card crosses into a
    /// new drop target or a swipe passes its trigger threshold. This is the
    /// alignment-guide feel from Finder and Photos.
    static func align() { perform(.alignment) }

    /// A firmer confirm, for committing a drop into a new group.
    static func commit() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
