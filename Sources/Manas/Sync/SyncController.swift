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
    @ObservationIgnored private let shareAPI = SupabaseShareAPI()
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
    ///   - auth: the phone-auth backend. Both platforms default to the same
    ///     Stytch-backed flow so either device can be the first one signed in.
    ///   - stateURL: where to persist the watermark + snapshot; defaults to
    ///     `sync-state.json` beside the app's state file.
    init(auth: (any SyncAuth)? = nil, stateURL: URL? = nil) {
        // Constructed before anything else touches auth: the real backend
        // reads the keychain from its initializer, on the main thread, before
        // the window exists — so the seam has to stand in for the backend
        // rather than merely ignore it.
        self.auth = auth ?? (Self.isDisabledByEnvironment ? SignedOutSyncAuth() : StytchSyncAuth())
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

    /// Dev/verification seam, alongside `MANAS_STATE_FILE` and
    /// `MANAS_DISABLE_AUTO_CHECKS`: a locally built copy of the app reads the
    /// same login keychain as the installed one (the keychain service name is
    /// fixed, not scoped by bundle id), so launching one to check a UI change
    /// otherwise signs in as the real user and pushes scratch todos to their
    /// live account. Setting this keeps the build permanently signed out.
    static var isDisabledByEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment["MANAS_DISABLE_SYNC"] ?? ""
        return !value.isEmpty && value != "0"
    }

    // MARK: - Sign in / out

    /// Re-reads a session restored from the shared keychain after the UI is up.
    func refreshAuthState() {
        guard !Self.isDisabledByEnvironment else { return }
        isSignedIn = auth.isSignedIn
        phoneNumber = auth.phone
        publishIdentity()
        if isSignedIn, phase == .signedOut { phase = .idle }
    }

    func requestCode(phone: String) async throws {
        try await auth.requestCode(phone: phone)
    }

    func verifyCode(phone: String, code: String) async throws {
        try await auth.verifyCode(phone: phone, code: code)
        isSignedIn = auth.isSignedIn
        phoneNumber = auth.phone
        publishIdentity()
        phase = .idle
        scheduleSync(after: .zero)
    }

    /// Tells the store who is signed in. That number is the identity behind
    /// shared groups — the author stamped onto new todos, and the member the
    /// UI draws as "you".
    private func publishIdentity() {
        store?.currentPhone = isSignedIn ? PhoneIdentity.normalized(phoneNumber) : nil
    }

    func signOut() {
        stop()
        auth.signOut()
        isSignedIn = false
        phoneNumber = nil
        store?.currentPhone = nil
        phase = .signedOut
        watermark = nil
        snapshot = [:]
        lastSyncedAt = nil
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Deletes the authenticated server account, then removes every local
    /// trace only after the server confirms success. A transient network error
    /// therefore never strands the user with local data gone but an account
    /// still active.
    func deleteAccount() async throws {
        stop()
        do {
            try await auth.deleteAccount()
        } catch {
            if isSignedIn { startLoopIfPossible() }
            throw error
        }

        store?.resetUserData()
        store?.saveNow()
        UsageAnalytics.shared.resetAfterAccountDeletion()
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
        guard !Self.isDisabledByEnvironment else { return }
        self.store = store
        publishIdentity()
        startLoopIfPossible()
    }

    private func startLoopIfPossible() {
        guard loopTask == nil, !Self.isDisabledByEnvironment else { return }
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

    /// Re-arms observation of the synced state; every change (except our own
    /// merge application) schedules a short-debounce push. Share rows are
    /// watched alongside the todos so inviting someone reaches them in seconds
    /// rather than at the next minute tick.
    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.todos
            _ = store.sharedGroupRecords
            _ = store.sharedMemberRecords
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
            // Shares go first, and their push lands before any todo does: a
            // todo carries its share id as a foreign key, so the group has to
            // exist on the server before a row can point at it.
            try await syncShares(store: store, token: token)
            let remote = try await api.changes(since: watermark, accessToken: token)
            let outcome = SyncMerge.merge(
                local: store.todos,
                snapshot: snapshot,
                remote: remote,
                previousWatermark: watermark,
                currentPhone: PhoneIdentity.normalized(phoneNumber),
                liveShareIDs: Set(store.sharedGroups.map(\.id))
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

    /// One pass over the share tables. They are small enough to pull whole,
    /// which is also what makes a revoked share disappear: the row simply
    /// stops coming back, and `applyShareMerge` releases its todos.
    private func syncShares(store: AppStore, token: String) async throws {
        let remoteGroups = try await shareAPI.groups(accessToken: token)
        let remoteMembers = try await shareAPI.members(accessToken: token)
        let groups = ShareMerge.merge(local: store.sharedGroupRecords, remote: remoteGroups)
        let members = ShareMerge.merge(local: store.sharedMemberRecords, remote: remoteMembers)

        // Only push what this device is allowed to write. The todo push has
        // carried this guard from the start; the share push did not, and the
        // consequence was worse than a lost edit: a member's client would send
        // back the group row it had just pulled, the server would reject it
        // with a 403 (only the owner may write that row), the throw would
        // abort syncShares — and because shares are pushed *before* todos are
        // fetched, that member never received a single shared todo again. It
        // looked exactly like an empty group, on every launch, forever.
        let pushable = ShareMerge.pushable(
            groups: groups.toPush,
            members: members.toPush,
            knownGroups: store.sharedGroupRecords,
            currentPhone: store.currentPhone
        )
        try await shareAPI.upsertGroups(pushable.groups, accessToken: token)
        try await shareAPI.upsertMembers(pushable.members, accessToken: token)
        isApplyingMerge = true
        store.applyShareMerge(groups: groups.records, members: members.records)
        isApplyingMerge = false
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
