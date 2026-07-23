import XCTest
@testable import Manas

/// Live end-to-end tests against the real Supabase backend, exercising the
/// exact client code the apps ship: phone-OTP sign-in, token refresh, and a
/// full two-device sync conversation through `SyncMerge` + `SupabaseTodoAPI`.
/// Gated behind MANAS_E2E=1 so ordinary `swift test` runs stay offline;
/// `scripts/e2e.sh` (and CI) set it. Uses the beta test-OTP numbers, so no
/// SMS is ever sent. The backend's per-number send throttle is 5s — the two
/// tests use different numbers so a full run never trips it.
final class SyncEndToEndTests: XCTestCase {
    private func requireE2E() throws {
        guard ProcessInfo.processInfo.environment["MANAS_E2E"] == "1" else {
            throw XCTSkip("Set MANAS_E2E=1 to run live backend tests.")
        }
        guard SupabaseConfig.isConfigured else {
            throw XCTSkip("SupabaseConfig has no live backend configured.")
        }
    }

    private static let testCode = "123456"

    /// The backend throttles OTP sends per number (seconds apart); the curl
    /// contract check may have just used the same number, so retry briefly
    /// instead of failing on the throttle.
    private func requestCodeTolerantly(_ auth: SupabaseAuthClient, phone: String) async throws {
        for attempt in 0..<4 {
            do {
                try await auth.requestCode(phone: phone)
                return
            } catch {
                let message = error.localizedDescription.lowercased()
                guard message.contains("security purposes") || message.contains("rate"),
                      attempt < 3
                else { throw error }
                try await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: - Auth

    func testPhoneOTPSignInAndRefresh() async throws {
        try requireE2E()
        let auth = SupabaseAuthClient()
        let phone = "+15555550100"

        try await requestCodeTolerantly(auth, phone: phone)
        let session = try await auth.verifyCode(phone: phone, code: Self.testCode)
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertFalse(session.refreshToken.isEmpty)
        XCTAssertEqual(session.phone, phone)
        XCTAssertGreaterThan(session.expiresAt, Date())

        let refreshed = try await auth.refresh(session)
        XCTAssertFalse(refreshed.accessToken.isEmpty)
        XCTAssertEqual(refreshed.userID, session.userID)
    }

    func testWrongCodeIsRejected() async throws {
        try requireE2E()
        let auth = SupabaseAuthClient()
        do {
            _ = try await auth.verifyCode(phone: "+15555550100", code: "000000")
            XCTFail("A wrong code must not produce a session")
        } catch {
            // Expected: the server refuses the bogus code.
        }
    }

    // MARK: - Two-device sync conversation

    /// One "device" = the state a real SyncController persists.
    private struct Device {
        var snapshot: [UUID: TodoRecord] = [:]
        var watermark: Date?
        var todos: [Todo] = []
    }

    /// Runs one full sync pass for a device, exactly as SyncController does:
    /// pull, merge, push, adopt the outcome.
    private func sync(_ device: inout Device, api: SupabaseTodoAPI, token: String) async throws {
        let remote = try await api.changes(since: device.watermark, accessToken: token)
        let outcome = SyncMerge.merge(
            local: device.todos,
            snapshot: device.snapshot,
            remote: remote,
            previousWatermark: device.watermark
        )
        try await api.upsert(outcome.toPush, accessToken: token)
        device.todos = outcome.todos
        device.snapshot = outcome.snapshot
        device.watermark = outcome.watermark
    }

    /// Hard-deletes every row the signed-in user owns, so runs are hermetic.
    private func wipeUserRows(token: String) async throws {
        var request = URLRequest(
            url: SupabaseConfig.projectURL
                .appendingPathComponent("rest/v1/todos")
                .appending(queryItems: [URLQueryItem(name: "created_at", value: "gte.1970-01-01")])
        )
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    func testTwoDevicesConvergeThroughTheLiveBackend() async throws {
        try requireE2E()
        let auth = SupabaseAuthClient()
        let api = SupabaseTodoAPI()
        let phone = "+14155550137"

        try await requestCodeTolerantly(auth, phone: phone)
        let session = try await auth.verifyCode(phone: phone, code: Self.testCode)
        let token = session.accessToken
        try await wipeUserRows(token: token)

        var mac = Device()
        var phoneDevice = Device()

        // 1. The Mac plans the day.
        let planned = Todo(text: "E2E: ship the sync", group: "Work")
        mac.todos = [planned]
        try await sync(&mac, api: api, token: token)

        // 2. The iPhone signs in fresh and sees it.
        try await sync(&phoneDevice, api: api, token: token)
        XCTAssertEqual(phoneDevice.todos.map(\.text), ["E2E: ship the sync"])
        XCTAssertEqual(phoneDevice.todos.first?.group, "Work")

        // 3. The iPhone checks it off; the Mac converges.
        phoneDevice.todos[0].isDone = true
        try await sync(&phoneDevice, api: api, token: token)
        try await sync(&mac, api: api, token: token)
        XCTAssertEqual(mac.todos.first?.isDone, true, "the Mac must see the phone's completion")

        // 4. The Mac deletes it; the iPhone converges to empty.
        mac.todos = []
        try await sync(&mac, api: api, token: token)
        try await sync(&phoneDevice, api: api, token: token)
        XCTAssertTrue(phoneDevice.todos.isEmpty, "the deletion must propagate as a tombstone")

        // 5. Quiescence: another pass on both sides pushes nothing.
        let remoteForMac = try await api.changes(since: mac.watermark, accessToken: token)
        let settled = SyncMerge.merge(
            local: mac.todos,
            snapshot: mac.snapshot,
            remote: remoteForMac,
            previousWatermark: mac.watermark
        )
        XCTAssertTrue(settled.toPush.isEmpty, "a converged pair must sync to a no-op")

        try await wipeUserRows(token: token)
    }
}
