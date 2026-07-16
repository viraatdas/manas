import SwiftUI

/// Screen 1: the day's control panel, laid out as a scrolling timeline.
/// Header with date navigation, refresh, and sync metadata; the add field
/// pinned above the scroll. Inside the scroll, top to bottom: collapsed
/// Earlier history, today's judged todo list and discovered activities,
/// muted Upcoming day sections, and the plan-a-day button. Checks run
/// automatically — there is no run button.
struct ContentView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedDate = Date()

    /// Content stays a comfortable column when the window gets wide.
    static let contentMaxWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            Group {
                MainHeaderView(selectedDate: $selectedDate)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                AddTodoField()
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: Self.contentMaxWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    EarlierSection()
                    TodoListSection()
                    DiscoveredSection()
                    UpcomingSection()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.todos)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.discoveredActivities)
            MainFooterView()
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
