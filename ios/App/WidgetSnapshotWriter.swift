import Foundation
import Observation
import WidgetKit

/// Keeps the widget's shared snapshot in step with the store: every todos
/// change writes the keychain payload (debounced a beat) and nudges WidgetKit
/// to rebuild timelines. Runs for the whole app session; cheap when idle.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()

    private weak var store: AppStore?
    private var started = false
    private var pendingWrite: Task<Void, Never>?

    func start(store: AppStore) {
        self.store = store
        guard !started else { return }
        started = true
        writeNow()
        observe()
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.todos
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleWrite()
                self.observe()
            }
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        guard let store else { return }
        WidgetSharedState.write(todos: store.todos)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
