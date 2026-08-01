import SwiftUI

/// The two things the sources turned up that aren't on the list: work the user
/// appears to have done, and things they said they'd do. They are kept apart
/// because adding one files a checked-off todo and adding the other files a
/// live one — reading them under a single "you might have also done this"
/// heading would make an outstanding commitment look like finished work.
/// Visually quieter than the todo card: surface-1 background, no border,
/// slightly smaller text. Hidden entirely when nothing is pending.
struct DiscoveredSection: View {
    @Environment(AppStore.self) private var store

    private var pending: [DiscoveredActivity] {
        store.discoveredActivities.filter { $0.resolution == .pending }
    }

    private var owed: [DiscoveredActivity] { pending.filter { $0.kind == .owed } }
    private var done: [DiscoveredActivity] { pending.filter { $0.kind == .done } }

    private var isCollapsed: Bool { store.isCollapsed(SectionKey.discovered) }

    /// Commitments lead: they are the only half that still needs acting on.
    private var heading: String {
        if owed.isEmpty { return "You might have also done this" }
        if done.isEmpty { return "You said you'd do this" }
        return "Picked up from your day"
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        store.toggleCollapsed(SectionKey.discovered)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text(heading)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        // Folded, the count is the only thing left saying
                        // there's anything in here.
                        if isCollapsed {
                            Text("\(pending.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isCollapsed ? "Expand suggestions" : "Collapse suggestions")

                // Transitioned as one block rather than row by row, so folding
                // reads as a single panel closing instead of a stagger of
                // independent rows each fading on its own.
                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 12) {
                        if !owed.isEmpty, !done.isEmpty {
                            subheading("You said you'd do this")
                        }
                        ForEach(owed) { DiscoveredRow(activity: $0) }
                        if !owed.isEmpty, !done.isEmpty {
                            subheading("You might have also done this")
                        }
                        ForEach(done) { DiscoveredRow(activity: $0) }
                    }
                    .transition(.opacity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Only rendered when both halves are present; with one kind on screen the
    /// section heading already says which it is.
    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
    }
}

/// One discovered activity: title and evidence, with an add ghost button and
/// an x to dismiss. Adding turns it into a checked-off todo carrying the
/// evidence as an accepted done verdict.
struct DiscoveredRow: View {
    @Environment(AppStore.self) private var store
    var activity: DiscoveredActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)
                Text(activity.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Add") {
                store.addDiscoveredToTodos(activity.id)
            }
            .buttonStyle(.ghost)
            Button {
                store.dismissDiscovered(activity.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverIcon)
            .accessibilityLabel("Dismiss")
        }
    }
}

#Preview("Discovered activities") {
    DiscoveredSection()
        .environment(AppStore.previewWithDiscovered)
        .padding(16)
        .frame(width: 420)
        .background(Color.manasBackground)
}
