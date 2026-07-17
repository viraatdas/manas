import AppKit
import SwiftUI

/// A horizontal day carousel. Each date is a fixed-width page with a small
/// neighboring-page peek, while the page itself scrolls vertically when its
/// todo list is long. Horizontal gestures, arrow keys, and header controls all
/// settle on the same date binding.
struct DayPager: View {
    @Binding var selectedDate: Date
    @State private var isReadyForFeedback = false
    @State private var isPositioned = false
    @State private var pagePositions: [Date: CGFloat] = [:]
    @State private var viewportMidX: CGFloat = 0
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
            let pageWidth = Self.pageWidth(in: geometry.size.width)
            let sideMargin = max(0, (geometry.size.width - pageWidth) / 2)
            let neighboringPageScale = reduceMotion ? 1.0 : 0.965

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // Width and spacing are identical for every day, so the
                    // lazy stack can place off-screen targets exactly without
                    // the variable-height estimation that broke the former
                    // vertical pager.
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(days, id: \.self) { day in
                            ScrollView(.vertical) {
                                DayPageView(day: day)
                                    .frame(
                                        minHeight: max(360, geometry.size.height),
                                        alignment: .top
                                    )
                            }
                            .scrollIndicators(.automatic)
                            .frame(width: pageWidth, height: geometry.size.height)
                            .background(
                                Color.primary.opacity(0.022),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : neighboringPageScale)
                                    .opacity(phase.isIdentity ? 1 : 0.64)
                            }
                            .background {
                                GeometryReader { pageGeometry in
                                    Color.clear.preference(
                                        key: DayPagePositionKey.self,
                                        value: [
                                            day: pageGeometry.frame(in: .named("day-pager")).midX,
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
                .contentMargins(.horizontal, sideMargin, for: .scrollContent)
                .scrollTargetBehavior(DayScrollTargetBehavior(alignmentEnabled: jumpTarget == nil))
                .coordinateSpace(name: "day-pager")
                .onAppear {
                    viewportMidX = geometry.size.width / 2
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
                .onChange(of: geometry.size.width) { _, width in
                    viewportMidX = width / 2
                    guard isPositioned else { return }
                    jump(to: selectedDate, using: proxy, animated: false)
                }
                .onPreferenceChange(DayPagePositionKey.self) { positions in
                    pagePositions = positions
                    guard isPositioned else { return }
                    updateSelection(from: positions)
                }
                .onMoveCommand { direction in
                    switch direction {
                    case .left: move(by: -1)
                    case .right: move(by: 1)
                    default: break
                    }
                }
                .accessibilityLabel("Day timeline")
                .accessibilityHint("Scroll horizontally for the previous or next day")
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

    /// Programmatic navigation temporarily disables gesture alignment, then
    /// checks the page nearest the viewport center. The short convergence loop
    /// keeps the header, add field, and carousel on one exact date.
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
                        proxy.scrollTo(proxyDay, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(proxyDay, anchor: .center)
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
        let normalized = calendar.startOfDay(for: candidate)
        guard selectedDate != normalized else { return }
        if isReadyForFeedback { DaySnapFeedback.play() }
        scrollDrivenSelections.insert(normalized)
        selectedDate = normalized
    }

    private func visibleDay(from positions: [Date: CGFloat]) -> Date? {
        guard !positions.isEmpty else { return nil }
        return positions.min {
            abs($0.value - viewportMidX) < abs($1.value - viewportMidX)
        }?.key
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

    static func pageWidth(in viewportWidth: CGFloat) -> CGFloat {
        max(340, viewportWidth - 88)
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
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: ContentView.contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .top)
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
            Label(pageContext, systemImage: isToday ? "location.fill" : "calendar")
                .font(.caption.weight(isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Color.manasAccent : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if todos.isEmpty { return isToday ? "No todos yet" : "No saved todos" }
        if doneCount == todos.count { return "Everything complete" }
        return "\(doneCount) of \(todos.count) complete"
    }

    private var pageContext: String {
        if isToday { return "Today" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

#Preview("Day pager") {
    DayPager(selectedDate: .constant(Calendar.current.startOfDay(for: Date())))
        .environment(AppStore.previewTimeline)
        .frame(width: 520, height: 560)
}
