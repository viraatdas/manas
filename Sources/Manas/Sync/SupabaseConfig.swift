import Foundation

/// The Manas cloud backend (Supabase): phone-OTP auth plus a per-user todos
/// table, shared by the macOS and iOS apps so both render the same day feed.
/// The anon key is a publishable client key — row-level security on the server
/// is what protects data, so committing it is safe and standard.
enum SupabaseConfig {
    /// Filled in by the backend provisioning; see supabase/BACKEND.md.
    static let projectURL = URL(string: "https://REPLACE_PROJECT_REF.supabase.co")!
    static let anonKey = "REPLACE_ANON_KEY"

    static var isConfigured: Bool {
        !anonKey.hasPrefix("REPLACE")
    }
}
