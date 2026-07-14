import SwiftUI

/// Screen 1: the day's control panel. Header with date navigation and sync
/// metadata, the add field pinned above the judged todo list, discovered
/// activities below, and the usage/Ask Claude footer.
struct ContentView: View {
    @Environment(AppStore.self) private var store

    /// Injected by the integration layer; runs one judge pass for today.
    /// Defaults to nil, which the footer surfaces as "not connected" on tap.
    var judgeToday: (@MainActor () async throws -> Void)?

    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            MainHeaderView(selectedDate: $selectedDate)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            AddTodoField()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TodoListSection()
                    DiscoveredSection()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .animation(.default, value: store.todos)
            .animation(.default, value: store.discoveredActivities)
            MainFooterView(judgeToday: judgeToday)
        }
        .background(Color.manasBackground)
    }
}

#Preview("Empty") {
    ContentView()
        .environment(AppStore.previewEmpty)
        .frame(width: 420, height: 640)
}

#Preview("Judged") {
    ContentView()
        .environment(AppStore.previewJudged)
        .frame(width: 420, height: 640)
}

#Preview("Discovered present") {
    ContentView(judgeToday: { try? await Task.sleep(for: .seconds(2)) })
        .environment(AppStore.previewWithDiscovered)
        .frame(width: 420, height: 640)
}
