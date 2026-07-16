import AppKit
import SwiftUI

/// A continuous vertical run of calendar days. Each ordinary day occupies at
/// least the viewport, and view-aligned targeting settles the wheel/trackpad
/// on the next or previous date instead of between two days.
struct DayPager: View {
    @Binding var selectedDate: Date
    @State private var isReadyForFeedback = false
    @State private var isPositioned = false
    @State private var pagePositions: [Date: CGFloat] = [:]
    @State private var scrollDrivenSelections: Set<Date> = []
    @State private var jumpTarget: Date?
    @State private var jumpTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let calendar = Calendar.current

    init(selectedDate: Binding<Date>) {
        _selectedDate = selectedDate
    }

    private var days: [Date] { Self.dates(around: Date(), radius: 60, calendar: calendar) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Eager layout keeps every page's real height known. A
                    // LazyVStack estimates offsets for off-screen days; when
                    // today is content-heavy those estimates can land a
                    // programmatic jump on the wrong adjacent date.
                    VStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            DayPageView(day: day)
                                .frame(minHeight: max(360, geometry.size.height), alignment: .top)
                                .background(Color.manasBackground)
                                .background {
                                    GeometryReader { pageGeometry in
                                        Color.clear.preference(
                                            key: DayPagePositionKey.self,
                                            value: [
                                                day: pageGeometry.frame(in: .named("day-pager")).minY,
                                            ]
                                        )
                                    }
                                }
                                .id(day)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                // Native view alignment gives wheel/trackpad gestures their
                // snap. It is briefly bypassed for explicit arrow/Today
                // jumps; otherwise macOS rewrites an exact programmatic page
                // boundary to one of its adjacent targets.
                .scrollTargetBehavior(DayScrollTargetBehavior(alignmentEnabled: jumpTarget == nil))
                .coordinateSpace(name: "day-pager")
                .onAppear {
                    let normalized = calendar.startOfDay(for: selectedDate)
                    selectedDate = normalized
                    jump(to: normalized, using: proxy, animated: false, initial: true)
                }
                .onDisappear {
                    jumpTask?.cancel()
                }
                .onChange(of: selectedDate) { _, newDate in
                    guard isPositioned else { return }
                    let normalized = calendar.startOfDay(for: newDate)
                    // Preference updates can cross more than one day during a
                    // fast wheel gesture. Keep every internally-produced date
                    // until its binding change arrives so none is mistaken for
                    // an arrow/Today jump and fed back into the scroll proxy.
                    if scrollDrivenSelections.remove(normalized) != nil {
                        return
                    }
                    jump(to: normalized, using: proxy, animated: !reduceMotion)
                }
                .onPreferenceChange(DayPagePositionKey.self) { positions in
                    pagePositions = positions
                    guard isPositioned else { return }
                    updateSelection(from: positions)
                }
                .onMoveCommand { direction in
                    switch direction {
                    case .up: move(by: -1)
                    case .down: move(by: 1)
                    default: break
                    }
                }
                .accessibilityLabel("Day timeline")
                .accessibilityHint("Scroll vertically for the previous or next day")
                .overlay(alignment: .bottomTrailing) {
                    if !calendar.isDateInToday(selectedDate) {
                        Button {
                            selectedDate = calendar.startOfDay(for: Date())
                        } label: {
                            Label("Today", systemImage: "location.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.manasAccent)
                        .controlSize(.regular)
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("Jump to today (⌘T)")
                        .padding(16)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedDate)
            }
        }
    }

    private func move(by offset: Int) {
        guard let date = Self.moved(selectedDate, by: offset, calendar: calendar),
              days.contains(date)
        else { return }
        selectedDate = date
    }

    /// `viewAligned` can resolve a programmatic jump to an adjacent target on
    /// macOS. Start with the requested ID, measure the page that actually
    /// arrived, then compensate by the observed day delta. Scroll-driven
    /// selection is paused for this short convergence loop, so the header can
    /// never race an in-flight arrow or Today jump.
    private func jump(
        to requestedDay: Date,
        using proxy: ScrollViewProxy,
        animated: Bool,
        initial: Bool = false
    ) {
        jumpTask?.cancel()
        jumpTarget = requestedDay
        if initial { isPositioned = false }

        jumpTask = Task { @MainActor in
            // Let SwiftUI install the non-aligning target behavior before the
            // proxy issues its exact programmatic page jump.
            await Task.yield()
            var proxyDay = requestedDay
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                if animated, attempt == 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(proxyDay, anchor: .top)
                    }
                } else {
                    proxy.scrollTo(proxyDay, anchor: .top)
                }

                try? await Task.sleep(for: .milliseconds(animated && attempt == 0 ? 240 : 55))
                guard !Task.isCancelled else { return }
                let visible = visibleDay(from: pagePositions)
                guard let visible, visible != requestedDay else {
                    break
                }
                let delta = calendar.dateComponents([.day], from: visible, to: requestedDay).day ?? 0
                guard delta != 0,
                      let corrected = calendar.date(byAdding: .day, value: delta, to: proxyDay),
                      days.contains(corrected)
                else { break }
                proxyDay = corrected
            }

            jumpTarget = nil
            isPositioned = true
            if let visible = visibleDay(from: pagePositions), visible != selectedDate {
                scrollDrivenSelections.insert(visible)
                selectedDate = visible
            }
            await Task.yield()
            isReadyForFeedback = true
        }
    }

    private func updateSelection(from positions: [Date: CGFloat]) {
        guard jumpTarget == nil, let candidate = visibleDay(from: positions) else { return }
        // The selected date is the last page whose leading edge crossed the
        // viewport top. This remains correct while a tall day scrolls within
        // itself and changes only when the adjacent day truly arrives.
        let normalized = calendar.startOfDay(for: candidate)
        guard selectedDate != normalized else { return }
        if isReadyForFeedback { DaySnapFeedback.play() }
        scrollDrivenSelections.insert(normalized)
        selectedDate = normalized
    }

    private func visibleDay(from positions: [Date: CGFloat]) -> Date? {
        guard !positions.isEmpty else { return nil }
        let crossedTop = positions
            .filter { $0.value <= 1 }
            .max { $0.value < $1.value }
        return crossedTop?.key ?? positions.min { $0.value < $1.value }?.key
    }

    static func dates(around reference: Date, radius: Int, calendar: Calendar = .current) -> [Date] {
        guard radius >= 0 else { return [] }
        let center = calendar.startOfDay(for: reference)
        return (-radius...radius).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: center)
        }
    }

    static func moved(_ day: Date, by offset: Int, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: day))
    }
}

private struct DayScrollTargetBehavior: ScrollTargetBehavior {
    var alignmentEnabled: Bool
    private let aligned = ViewAlignedScrollTargetBehavior(limitBehavior: .always)

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard alignmentEnabled else { return }
        aligned.updateTarget(&target, context: context)
    }
}

private struct DayPagePositionKey: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]

    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

enum DaySnapFeedback {
    static func play() {
        guard ProcessInfo.processInfo.environment["MANAS_DISABLE_SOUNDS"] == nil else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}

struct DayPageView: View {
    @Environment(AppStore.self) private var store
    var day: Date

    private var todos: [Todo] { store.todos(on: day) }
    private var doneCount: Int { todos.filter(\.isDone).count }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            daySummary
            TodoListSection(day: day)
            if isToday {
                DiscoveredSection()
            }
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: ContentView.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color.manasBackground)
    }

    private var daySummary: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(todos.isEmpty ? .secondary : .primary)
            if isToday, store.isCheckingIn {
                Text("Observing now")
                    .font(.caption)
                    .foregroundStyle(Color.manasAccent)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.and.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Scroll for adjacent days")
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if todos.isEmpty { return isToday ? "No todos yet" : "No saved todos" }
        if doneCount == todos.count { return "Everything complete" }
        return "\(doneCount) of \(todos.count) complete"
    }
}

#Preview("Day pager") {
    DayPager(selectedDate: .constant(Calendar.current.startOfDay(for: Date())))
        .environment(AppStore.previewTimeline)
        .frame(width: 520, height: 560)
}
