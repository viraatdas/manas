import AppKit
import SwiftUI

struct SourceHealthButton: View {
    @Environment(AppStore.self) private var store
    @State private var isPresented = false

    private var readyCount: Int {
        store.sourceStatuses.filter { $0.state == .ready }.count
    }

    private var hasIssue: Bool {
        store.sourceStatuses.contains { [.permissionRequired, .failed].contains($0.state) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(hasIssue ? Color.orange : (readyCount > 0 ? Color.green : Color.secondary))
                    .frame(width: 7, height: 7)
                Text("\(readyCount)/\(store.sourceStatuses.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverIcon)
        .help("Activity sources")
        .accessibilityLabel("\(readyCount) of \(store.sourceStatuses.count) activity sources ready")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SourceHealthPopover()
        }
    }
}

struct SourceHealthPopover: View {
    @Environment(AppStore.self) private var store

    private var needsPermission: Bool {
        store.sourceStatuses.contains { $0.state == .permissionRequired }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity sources")
                    .font(.headline)
                Text("Manas checks each source independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(store.sourceStatuses) { status in
                    SourceStatusRow(status: status)
                    if status.id != store.sourceStatuses.last?.id {
                        Divider().padding(.leading, 32)
                    }
                }
            }

            if needsPermission {
                Button("Open Full Disk Access") {
                    Self.openFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
                .tint(.manasAccent)
                .controlSize(.small)
            }

            Text("Read-only, same-day activity is summarized in memory. Derived snippets are sent through your Claude CLI for judging; raw databases are never saved by Manas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 330)
        .background(Color.manasBackground)
    }

    static func openFullDiskAccess() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SourceStatusRow: View {
    var status: ActivitySourceStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.source.systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.source.displayName)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status.state == .permissionRequired ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            statusIcon
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status.state {
        case .waiting:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .syncing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .permissionRequired:
            Image(systemName: "lock.circle.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var detail: String {
        if let detail = status.detail { return detail }
        return switch status.state {
        case .waiting: "Waiting for the first check"
        case .syncing: "Checking today…"
        case .ready:
            status.activityCount == 0
                ? "Ready · no activity today"
                : "Ready · \(status.activityCount) \(status.activityCount == 1 ? "activity" : "activities")"
        case .permissionRequired: "Full Disk Access required"
        case .unavailable: "Not available"
        case .failed: "Could not sync"
        }
    }
}

#Preview("Source health") {
    let store = AppStore.previewJudged
    store.sourceStatuses = [
        ActivitySourceStatus(source: .claude, state: .ready, activityCount: 3),
        ActivitySourceStatus(source: .codex, state: .ready, activityCount: 2),
        ActivitySourceStatus(source: .arc, state: .ready, activityCount: 14),
        ActivitySourceStatus(source: .screenTime, state: .permissionRequired, activityCount: 0),
        ActivitySourceStatus(source: .messages, state: .permissionRequired, activityCount: 0),
    ]
    return SourceHealthPopover().environment(store)
}
