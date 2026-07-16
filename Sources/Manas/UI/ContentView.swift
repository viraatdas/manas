import SwiftUI

/// The day control panel. The header, add field, pager position, todo list,
/// and usage footer share one selected date. Vertical scrolling settles on
/// adjacent calendar days; checks still run automatically for today.
struct ContentView: View {
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())

    /// Content stays a comfortable column when the window gets wide.
    static let contentMaxWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            Group {
                MainHeaderView(selectedDate: $selectedDate)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                AddTodoField(day: selectedDate)
                    .padding(.bottom, 14)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: Self.contentMaxWidth)
            Divider()
            DayPager(selectedDate: $selectedDate)
            MainFooterView(day: selectedDate)
        }
        .background(Color.manasBackground)
    }
}

#Preview("Empty") {
    ContentView()
        .environment(AppStore.previewEmpty)
        .frame(width: 520, height: 760)
}

#Preview("Judged") {
    ContentView()
        .environment(AppStore.previewJudged)
        .frame(width: 520, height: 760)
}

#Preview("Discovered present") {
    ContentView()
        .environment(AppStore.previewWithDiscovered)
        .frame(width: 520, height: 760)
}

#Preview("Timeline") {
    ContentView()
        .environment(AppStore.previewTimeline)
        .frame(width: 520, height: 760)
}

#Preview("Wide") {
    ContentView()
        .environment(AppStore.previewTimeline)
        .frame(width: 900, height: 760)
}
