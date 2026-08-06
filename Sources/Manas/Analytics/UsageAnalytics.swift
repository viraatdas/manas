import Foundation
import Observation

/// A deliberately small, manual product-analytics client shared by macOS and
/// iOS. Manas does not load an analytics SDK: the only data that can leave the
/// app is represented by the finite `Event` enum below.
///
/// Collection is off until the user explicitly opts in. Events use a random
/// installation identifier, never the sync account, phone number, todo text,
/// group name, activity contents, browser history, or Messages data.
@MainActor
@Observable
final class UsageAnalytics {
    enum DayRelation: String {
        case past
        case today
        case future
    }

    enum Event: Equatable {
        case analyticsEnabled
        case appOpened
        case todoCreated(day: DayRelation, hasGroup: Bool)
        case todoCompleted(day: DayRelation, hasGroup: Bool)
        case todoReopened(day: DayRelation, hasGroup: Bool)
        case todoGroupChanged(hasGroup: Bool)
        case todoRescheduled(day: DayRelation)
        case groupCreated
        /// A group was opened up to another phone number. The number itself is
        /// never sent — only how many people the group now holds.
        case groupShared(memberCount: Int)
        case groupUnshared
        case sharedTodoAdded
        case discoveredTodoAdded
        case quickCaptureOpened
        case checkInStarted(automatic: Bool)
        case checkInCompleted(automatic: Bool, sourceCount: Int, todoCount: Int)
        case checkInFailed(automatic: Bool)

        fileprivate var name: String {
            switch self {
            case .analyticsEnabled: "manas_analytics_enabled"
            case .appOpened: "manas_app_opened"
            case .todoCreated: "manas_todo_created"
            case .todoCompleted: "manas_todo_completed"
            case .todoReopened: "manas_todo_reopened"
            case .todoGroupChanged: "manas_todo_group_changed"
            case .todoRescheduled: "manas_todo_rescheduled"
            case .groupCreated: "manas_group_created"
            case .groupShared: "manas_group_shared"
            case .groupUnshared: "manas_group_unshared"
            case .sharedTodoAdded: "manas_shared_todo_added"
            case .discoveredTodoAdded: "manas_discovered_todo_added"
            case .quickCaptureOpened: "manas_quick_capture_opened"
            case .checkInStarted: "manas_check_in_started"
            case .checkInCompleted: "manas_check_in_completed"
            case .checkInFailed: "manas_check_in_failed"
            }
        }

        fileprivate var properties: [String: AnalyticsValue] {
            switch self {
            case .analyticsEnabled, .appOpened, .groupCreated, .groupUnshared,
                 .sharedTodoAdded, .discoveredTodoAdded, .quickCaptureOpened:
                [:]
            case .groupShared(let memberCount):
                ["member_count": .integer(max(0, memberCount))]
            case .todoCreated(let day, let hasGroup),
                 .todoCompleted(let day, let hasGroup),
                 .todoReopened(let day, let hasGroup):
                [
                    "day": .string(day.rawValue),
                    "has_group": .bool(hasGroup),
                ]
            case .todoGroupChanged(let hasGroup):
                ["has_group": .bool(hasGroup)]
            case .todoRescheduled(let day):
                ["day": .string(day.rawValue)]
            case .checkInStarted(let automatic), .checkInFailed(let automatic):
                ["trigger": .string(automatic ? "automatic" : "manual")]
            case .checkInCompleted(let automatic, let sourceCount, let todoCount):
                [
                    "trigger": .string(automatic ? "automatic" : "manual"),
                    "source_count": .integer(max(0, sourceCount)),
                    "todo_count": .integer(max(0, todoCount)),
                ]
            }
        }
    }

    typealias Sender = @Sendable (URLRequest) async throws -> Void

    static let shared = UsageAnalytics()

    private enum Keys {
        static let enabled = "manas.analytics.enabled"
        static let askedForConsent = "manas.analytics.asked-for-consent"
        static let installationID = "manas.analytics.installation-id"
    }

    private(set) var isEnabled: Bool
    private(set) var hasAskedForConsent: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let projectToken: String
    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored private let sender: Sender
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastAppOpenAt: Date?

    var isConfigured: Bool { projectToken.hasPrefix("phc_") }
    var shouldRequestConsent: Bool { isConfigured && !hasAskedForConsent }

    init(
        defaults: UserDefaults = .standard,
        projectToken: String? = nil,
        endpoint: URL = URL(string: "https://us.i.posthog.com/i/v0/e/")!,
        now: @escaping @Sendable () -> Date = Date.init,
        sender: @escaping Sender = UsageAnalytics.liveSender
    ) {
        self.defaults = defaults
        self.projectToken = projectToken ?? Self.configuredProjectToken
        self.endpoint = endpoint
        self.now = now
        self.sender = sender
        isEnabled = defaults.bool(forKey: Keys.enabled)
        hasAskedForConsent = defaults.bool(forKey: Keys.askedForConsent)
    }

    /// Records an explicit consent choice. Turning collection off immediately
    /// stops capture and deletes the local identifier. A later opt-in receives
    /// a new identifier and cannot be joined to the earlier event stream.
    func setEnabled(_ enabled: Bool) {
        hasAskedForConsent = true
        defaults.set(true, forKey: Keys.askedForConsent)

        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            defaults.removeObject(forKey: Keys.installationID)
            lastAppOpenAt = nil
            return
        }

        guard isConfigured else { return }
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        capture(.analyticsEnabled)
        captureAppOpened()
    }

    /// Used after account deletion so analytics consent and the anonymous
    /// installation identifier are removed along with the user's app data.
    func resetAfterAccountDeletion() {
        isEnabled = false
        hasAskedForConsent = false
        defaults.removeObject(forKey: Keys.enabled)
        defaults.removeObject(forKey: Keys.askedForConsent)
        defaults.removeObject(forKey: Keys.installationID)
        lastAppOpenAt = nil
    }

    /// Captures a foreground activation at most once per 30 seconds. This
    /// avoids duplicate events from transient window activation changes.
    func captureAppOpened() {
        guard isEnabled else { return }
        let timestamp = now()
        if let lastAppOpenAt, timestamp.timeIntervalSince(lastAppOpenAt) < 30 {
            return
        }
        lastAppOpenAt = timestamp
        capture(.appOpened, timestamp: timestamp)
    }

    func capture(_ event: Event) {
        capture(event, timestamp: now())
    }

    static func dayRelation(for day: Date, now: Date = Date()) -> DayRelation {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return .today }
        return day < calendar.startOfDay(for: now) ? .past : .future
    }

    /// Internal seam for tests: the generated JSON is inspectable without
    /// sending a network request.
    func request(for event: Event, timestamp: Date? = nil) -> URLRequest? {
        guard isConfigured, isEnabled else { return nil }
        let eventTime = timestamp ?? now()
        let payload = CapturePayload(
            apiKey: projectToken,
            event: event.name,
            distinctID: installationID,
            properties: standardProperties.merging(event.properties) { _, eventValue in eventValue },
            timestamp: ISO8601DateFormatter().string(from: eventTime)
        )
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        return request
    }

    private func capture(_ event: Event, timestamp: Date) {
        guard let request = request(for: event, timestamp: timestamp) else { return }
        let sender = sender
        Task {
            try? await sender(request)
        }
    }

    private var installationID: String {
        if let existing = defaults.string(forKey: Keys.installationID), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Keys.installationID)
        return created
    }

    private var standardProperties: [String: AnalyticsValue] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "$process_person_profile": .bool(false),
            "$geoip_disable": .bool(true),
            "product": .string("manas"),
            "platform": .string(Self.platform),
            "app_version": .string(info["CFBundleShortVersionString"] as? String ?? "development"),
            "build_number": .string(info["CFBundleVersion"] as? String ?? "development"),
            "schema_version": .integer(1),
        ]
    }

    private static var platform: String {
        #if os(iOS)
        "ios"
        #elseif os(macOS)
        "macos"
        #else
        "unknown"
        #endif
    }

    private static var configuredProjectToken: String {
        if let value = ProcessInfo.processInfo.environment["MANAS_POSTHOG_PROJECT_TOKEN"],
           !value.isEmpty {
            return value
        }
        return Bundle.main.object(forInfoDictionaryKey: "ManasPostHogProjectToken") as? String ?? ""
    }

    private static let liveSender: Sender = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private enum AnalyticsValue: Encodable {
    case string(String)
    case integer(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

private struct CapturePayload: Encodable {
    let apiKey: String
    let event: String
    let distinctID: String
    let properties: [String: AnalyticsValue]
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case event
        case distinctID = "distinct_id"
        case properties
        case timestamp
    }
}
