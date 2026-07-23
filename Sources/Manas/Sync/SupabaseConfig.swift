import Foundation

/// The Manas cloud backend (Supabase): phone-OTP auth plus a per-user todos
/// table, shared by the macOS and iOS apps so both render the same day feed.
/// The anon key is a publishable client key — row-level security on the server
/// is what protects data, so committing it is safe and standard.
enum SupabaseConfig {
    /// Provisioned 2026-07-23; see supabase/BACKEND.md.
    static let projectURL = URL(string: "https://gdnknuiqxmosuwoytrzc.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdkbmtudWlxeG1vc3V3b3l0cnpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ4Mzg3OTAsImV4cCI6MjEwMDQxNDc5MH0.g87OA50wBHMyz1Vef2J-0Ru3tknbNbl79AleNALX1mo"

    static var isConfigured: Bool {
        !anonKey.hasPrefix("REPLACE")
    }
}
