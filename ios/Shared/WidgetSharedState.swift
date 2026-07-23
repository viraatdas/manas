import Foundation
import Security

/// The app ↔ widget data bridge. App Groups would be the textbook channel,
/// but registering one requires an Apple ID web session the CLI pipeline
/// doesn't have — keychain sharing needs no portal setup at all: every
/// provisioning profile allows access groups under the team prefix. The app
/// writes a compact snapshot of the todo list after every change; the widget
/// reads it when WidgetKit asks for a timeline.
enum WidgetSharedState {
    /// Team-prefixed keychain access group, shared by app and extension.
    /// Must match the `keychain-access-groups` entitlement in both targets.
    static let accessGroup = "3C4383262W.dev.viraat.manas.shared"
    private static let service = "dev.viraat.manas.widget"
    private static let account = "today-state"

    struct Payload: Codable {
        var todos: [Todo]
        var updatedAt: Date
    }

    /// Writes the whole list; the widget derives "today" itself so a snapshot
    /// taken before midnight still renders correctly after it.
    static func write(todos: [Todo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(todos: todos, updatedAt: Date())) else { return }

        var query = baseQuery(withGroup: true)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        // Simulator builds signed without entitlements can't use the shared
        // group; fall back to the app's own keychain so local flows still work.
        if status == errSecMissingEntitlement {
            var fallback = baseQuery(withGroup: false)
            SecItemDelete(fallback as CFDictionary)
            fallback[kSecValueData as String] = data
            fallback[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(fallback as CFDictionary, nil)
        }
    }

    static func read() -> [Todo]? {
        for withGroup in [true, false] {
            var query = baseQuery(withGroup: withGroup)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data
            else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let payload = try? decoder.decode(Payload.self, from: data) {
                return payload.todos
            }
        }
        return nil
    }

    private static func baseQuery(withGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if withGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
