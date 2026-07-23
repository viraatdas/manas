import SwiftUI
import WidgetKit

// The widget's SwiftUI surfaces, one per family. They share a small kit of
// row and summary pieces so the visual language stays identical across sizes:
// flat, hairline separators, a single coral accent, system text styles.

/// Routes each widget family to its layout. `containerBackground` is applied
/// by the widget configuration, so the views only draw content.
struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var snapshot: TodaySnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .systemSmall:
            SmallTodayView(snapshot: snapshot)
        case .systemMedium:
            MediumTodayView(snapshot: snapshot)
        case .systemLarge:
            LargeTodayView(snapshot: snapshot, date: entry.date)
        case .accessoryRectangular:
            RectangularTodayView(snapshot: snapshot)
        default:
            MediumTodayView(snapshot: snapshot)
        }
    }
}

// MARK: - Small (count-focused)

private struct SmallTodayView: View {
    let snapshot: TodaySnapshot

    var body: some View {
        if snapshot.isEmpty || snapshot.allDone {
            ClearDayView(compact: true, allDone: snapshot.allDone)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: -2) {
                        Text("\(snapshot.remaining)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.manasAccent)
                        Text("left today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ProgressRing(done: snapshot.doneCount, total: snapshot.total)
                        .frame(width: 30, height: 30)
                }

                Spacer(minLength: 8)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.unfinished.prefix(2)) { todo in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.manasAccent)
                                .frame(width: 4, height: 4)
                            Text(todo.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Medium (up to 4 rows)

private struct MediumTodayView: View {
    let snapshot: TodaySnapshot

    var body: some View {
        if snapshot.isEmpty || snapshot.allDone {
            ClearDayView(compact: false, allDone: snapshot.allDone)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                TodoRows(todos: Array(snapshot.ordered.prefix(4)))
                Spacer(minLength: 0)
                if snapshot.total > 4 {
                    MoreFooter(hidden: snapshot.total - 4, done: snapshot.doneCount, total: snapshot.total)
                }
            }
        }
    }
}

// MARK: - Large (header + up to 9 rows)

private struct LargeTodayView: View {
    let snapshot: TodaySnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LargeHeader(date: date, snapshot: snapshot)
            Divider()
            if snapshot.isEmpty || snapshot.allDone {
                Spacer(minLength: 0)
                ClearDayView(compact: false, allDone: snapshot.allDone)
                Spacer(minLength: 0)
            } else {
                TodoRows(todos: Array(snapshot.ordered.prefix(9)))
                Spacer(minLength: 0)
                if snapshot.total > 9 {
                    MoreFooter(hidden: snapshot.total - 9, done: snapshot.doneCount, total: snapshot.total)
                }
            }
        }
    }
}

private struct LargeHeader: View {
    let date: Date
    let snapshot: TodaySnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.manasAccent)
                Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if snapshot.total > 0 {
                Text("\(snapshot.doneCount)/\(snapshot.total) done")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Lock screen (accessoryRectangular)

private struct RectangularTodayView: View {
    let snapshot: TodaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if snapshot.isEmpty || snapshot.allDone {
                Label(snapshot.allDone ? "All done today" : "Clear day", systemImage: "checkmark.seal")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            } else {
                Text("\(snapshot.remaining) left today")
                    .font(.headline)
                ForEach(snapshot.unfinished.prefix(2)) { todo in
                    Text(todo.text)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared pieces

/// A vertical stack of todo rows with hairline separators between them, in the
/// app's row layout: checkbox circle, optional group emoji prefix, text that
/// strikes through when done, and a verdict status dot when one exists.
private struct TodoRows: View {
    let todos: [Todo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                TodoRowView(todo: todo)
                if index != todos.count - 1 {
                    Divider()
                }
            }
        }
    }
}

private struct TodoRowView: View {
    let todo: Todo

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                .font(.footnote)
                .foregroundStyle(todo.isDone ? Color.manasAccent : Color.secondary)

            if let group = todo.group {
                Text(TodaySnapshot.emoji(forGroup: group))
                    .font(.caption)
            }

            Text(todo.text)
                .font(.subheadline)
                .strikethrough(todo.isDone)
                .foregroundStyle(todo.isDone ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let verdict = todo.verdict {
                Circle()
                    .fill(verdict.status.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(verdict.status.label)
            }
        }
        .padding(.vertical, 5)
    }
}

/// The "n more" tail shown when a family can't fit the whole day, paired with
/// the done fraction so the count still reads at a glance.
private struct MoreFooter: View {
    let hidden: Int
    let done: Int
    let total: Int

    var body: some View {
        HStack {
            Text("\(hidden) more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text("\(done)/\(total) done")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }
}

/// The calm end-of-day state: a filled seal, not an error. Doubles as the
/// "nothing planned" state for an empty day.
private struct ClearDayView: View {
    let compact: Bool
    let allDone: Bool

    private var title: String { allDone ? "All done" : "Clear day" }
    private var detail: String { allDone ? "Everything's checked off." : "Nothing on today." }

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(Color.manasAccent)
            Text(title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
            if !compact {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}

/// A thin progress ring: a hairline track with a coral arc for the done
/// fraction, matching the app's flat, accent-only treatment.
private struct ProgressRing: View {
    let done: Int
    let total: Int

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.manasAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
