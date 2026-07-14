import SwiftUI

/// Screen 1 header: date navigation on the left, settings gear on the right,
/// with a muted metadata row ("Last checked 2:14 pm · 2 sources synced")
/// underneath.
struct MainHeaderView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedDate: Date
    @State private var showingSettings = false

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                dayButton(systemImage: "chevron.left", byAdding: -1)
                    .accessibilityLabel("Previous day")
                Text(selectedDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.headline)
                dayButton(systemImage: "chevron.right", byAdding: 1)
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
                Spacer(minLength: 0)
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsPopover()
                }
            }
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dayButton(systemImage: String, byAdding days: Int) -> some View {
        Button {
            if let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
                selectedDate = moved
            }
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var metadata: String {
        var parts: [String] = []
        if let lastChecked = store.lastCheckedAt {
            let time = lastChecked.formatted(date: .omitted, time: .shortened).lowercased()
            parts.append("Last checked \(time)")
        } else {
            parts.append("Not checked yet")
        }
        if store.syncedSourceCount > 0 {
            let noun = store.syncedSourceCount == 1 ? "source" : "sources"
            parts.append("\(store.syncedSourceCount) \(noun) synced")
        }
        return parts.joined(separator: " · ")
    }
}

/// Small settings surface behind the gear: the model dial and the soft daily
/// token budget, both bound straight to `AppStore` so they persist.
struct SettingsPopover: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $store.selectedModel) {
                    ForEach(JudgeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(store.selectedModel.detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Daily token budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Daily token budget", value: $store.dailyTokenBudget, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}

#Preview("Header") {
    MainHeaderView(selectedDate: .constant(Date()))
        .environment(AppStore.previewJudged)
        .padding(16)
        .frame(width: 420)
        .background(Color.manasBackground)
}

#Preview("Settings popover") {
    SettingsPopover()
        .environment(AppStore.previewEmpty)
}
