import SwiftUI

/// "You might have also done this" — work the sources saw that wasn't on the
/// list. Visually quieter than the todo card: surface-1 background, no
/// border, slightly smaller text. Hidden entirely when nothing is pending.
struct DiscoveredSection: View {
    @Environment(AppStore.self) private var store

    private var pending: [DiscoveredActivity] {
        store.discoveredActivities.filter { $0.resolution == .pending }
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("You might have also done this")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(pending) { activity in
                    DiscoveredRow(activity: activity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
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
                    .lineLimit(1)
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
                    .frame(width: 20, height: 20)
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
