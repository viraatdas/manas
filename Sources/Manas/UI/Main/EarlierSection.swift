import SwiftUI

/// The timeline's history, sitting above today: a single muted disclosure
/// row ("Earlier · 3 days") that expands into one read-only card per past
/// day, newest first. Collapsed on every launch — history is there when
/// wanted, never in the way.
struct EarlierSection: View {
    @Environment(AppStore.self) private var store
    @State private var isExpanded: Bool

    init(initiallyExpanded: Bool = false) {
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let pastDays = store.pastDays
        if !pastDays.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                disclosureRow(count: pastDays.count)
                if isExpanded {
                    ForEach(pastDays) { group in
                        PastDayCard(group: group)
                    }
                }
            }
        }
    }

    private func disclosureRow(count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("Earlier · \(count) \(count == 1 ? "day" : "days")")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
        .accessibilityLabel(isExpanded ? "Collapse earlier days" : "Expand earlier days")
    }
}

/// One past day: muted header over a card of frozen rows.
private struct PastDayCard: View {
    var group: DayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DayLabel.title(for: group.day))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(group.todos) { todo in
                    PastTodoRow(todo: todo)
                    if todo.id != group.todos.last?.id {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .manasCard(padding: 0)
        }
    }
}

/// A history row: the checkbox is state, not a control, and a verdict keeps
/// its chip and evidence with no accept/dismiss — the day is settled. The
/// one live affordance is pulling an unfinished todo forward to today.
private struct PastTodoRow: View {
    @Environment(AppStore.self) private var store
    var todo: Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(todo.isDone ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
                .accessibilityLabel(todo.isDone ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 6) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(.secondary)
                if !todo.isDone, let verdict = todo.verdict, verdict.accepted != false {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Chip(
                            text: verdict.status.label,
                            systemImage: verdict.status.systemImage,
                            tint: verdict.status.tint
                        )
                        Text(verdict.evidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
            if !todo.isDone {
                Button("Move to today") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        store.moveToToday(todo.id)
                    }
                }
                .buttonStyle(.ghost)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#Preview("Earlier, collapsed") {
    EarlierSection()
        .environment(AppStore.previewTimeline)
        .padding(24)
        .frame(width: 520)
        .background(Color.manasBackground)
}

#Preview("Earlier, expanded") {
    EarlierSection(initiallyExpanded: true)
        .environment(AppStore.previewTimeline)
        .padding(24)
        .frame(width: 520)
        .background(Color.manasBackground)
}
