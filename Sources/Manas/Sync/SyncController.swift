import Foundation
import Observation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Owns the cloud session and keeps `AppStore.todos` and the server table
/// converged. Sync is an overlay: signed out, the app is exactly the local
/// app it always was. Signed in, every local change pushes shortly after it
/// happens and remote changes fold in on a steady cadence.
@MainActor
@Observable
final class SyncController {
    enum Phase: Equatable {
        case signedOut
        case idle
        case syncing
        case error(String)
    }

    private(set) var isSignedIn: Bool
    private(set) var phoneNumber: String?
    private(set) var phase: Phase = .signedOut
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private let auth: any SyncAuth
    @ObservationIgnored private let api = SupabaseTodoAPI()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var isApplyingMerge = false
    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private let logger = Logger(subsystem: "Manas", category: "Sync")

    /// On-disk sync bookkeeping, next to the state file.
    private struct SyncState: Codable {
        var watermark: Date?
        var snapshot: [UUID: TodoRecord]
    }

    @ObservationIgnored private var watermark: Date?
    @ObservationIgnored private var snapshot: [UUID: TodoRecord] = [:]

    /// - Parameters:
    ///   - auth: the platform's auth backend; the Mac's Supabase phone auth by
    ///     default, iOS injects a Firebase-backed one.
    ///   - stateURL: where to persist the watermark + snapshot; defaults to
    ///     `sync-state.json` beside the app's state file.
    init(auth: (any SyncAuth)? = nil, stateURL: URL? = nil) {
        self.auth = auth ?? SupabaseSyncAuth()
        self.stateURL = stateURL
            ?? AppStore.defaultStateURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
        isSignedIn = self.auth.isSignedIn
        phoneNumber = self.auth.phone
        if isSignedIn { phase = .idle }
        if let data = try? Data(contentsOf: self.stateURL),
           let saved = try? TodoRecord.makeDecoder().decode(SyncState.self, from: data) {
            watermark = saved.watermark
            snapshot = saved.snapshot
        }
    }

    // MARK: - Sign in / out

    func requestCode(phone: String) async throws {
        try await auth.requestCode(phone: phone)
    }

    func verifyCode(phone: String, code: String) async throws {
        try await auth.verifyCode(phone: phone, code: code)
        isSignedIn = auth.isSignedIn
        phoneNumber = auth.phone
        phase = .idle
        scheduleSync(after: .zero)
    }

    func signOut() {
        auth.signOut()
        isSignedIn = false
        phoneNumber = nil
        phase = .signedOut
        watermark = nil
        snapshot = [:]
        lastSyncedAt = nil
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Sync loop

    /// Binds to the store and starts the cadence: an immediate pass, a pass
    /// ~2s after any local change, and a steady pull every minute.
    func start(store: AppStore) {
        self.store = store
        guard loopTask == nil else { return }
        observeStore()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        pendingSync?.cancel()
        pendingSync = nil
    }

    /// Re-arms observation of the todos array; every change (except our own
    /// merge application) schedules a short-debounce push.
    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.todos
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isApplyingMerge {
                    self.scheduleSync(after: .seconds(2))
                }
                self.observeStore()
            }
        }
    }

    private func scheduleSync(after delay: Duration) {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One full pass: refresh the token if needed, pull, merge, apply, push.
    func syncNow() async {
        guard SupabaseConfig.isConfigured, isSignedIn, let store, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        phase = .syncing
        do {
            let token = try await auth.bearerToken()
            let remote = try await api.changes(since: watermark, accessToken: token)
            let outcome = SyncMerge.merge(
                local: store.todos,
                snapshot: snapshot,
                remote: remote,
                previousWatermark: watermark
            )
            try await api.upsert(outcome.toPush, accessToken: token)
            if outcome.todos != store.todos {
                isApplyingMerge = true
                store.todos = outcome.todos
                isApplyingMerge = false
            }
            watermark = outcome.watermark
            snapshot = outcome.snapshot
            persistSyncState()
            lastSyncedAt = Date()
            phase = .idle
            reloadWidgets()
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
        }
    }

    private func persistSyncState() {
        let state = SyncState(watermark: watermark, snapshot: snapshot)
        if let data = try? TodoRecord.makeEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// The widget renders from the shared state file; nudge it after changes.
    private func reloadWidgets() {
        #if os(iOS) && canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
