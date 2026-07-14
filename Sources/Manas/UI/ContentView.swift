import SwiftUI

/// Placeholder root view. Later workers replace the files in UI/ but keep
/// ManasApp.swift's structure (a Window scene with AppStore in the environment).
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            Text("Manas")
                .font(.title2)
            Text("Control panel for the day")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chip(text: "Foundation ready", systemImage: "checkmark.circle.fill")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.manasBackground)
    }
}
