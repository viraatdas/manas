import SwiftUI

/// The sync block of the settings popover: sign in with a phone number to
/// mirror the day feed onto the iPhone app, or see the live session and sign
/// out. Kept popover-compact — two fields at most, errors inline.
struct SyncSettingsSection: View {
    @Environment(SyncController.self) private var sync

    private enum Step: Equatable {
        case idle
        case sendingCode
        case enterCode
        case verifying
    }

    @State private var phone = "+1"
    @State private var code = ""
    @State private var step: Step = .idle
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone sync")
                .font(.subheadline.weight(.medium))

            if sync.isSignedIn {
                signedInBody
            } else {
                signedOutBody
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.subheadline)
                    .foregroundStyle(Color.manasAccent)
                Text(sync.phoneNumber ?? "Signed in")
                    .font(.subheadline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: statusLineSymbol)
                    .font(.caption2)
                Text(statusLine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(statusLineTint)
            Button("Sign out") {
                sync.signOut()
                step = .idle
                code = ""
                errorText = nil
            }
            .buttonStyle(.ghost)
        }
    }

    private var statusSymbol: String {
        if case .syncing = sync.phase { return "arrow.triangle.2.circlepath" }
        return "checkmark.icloud"
    }

    private var statusLineSymbol: String {
        switch sync.phase {
        case .syncing: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    private var statusLineTint: Color {
        if case .error = sync.phase { return .red }
        return .secondary
    }

    private var statusLine: String {
        switch sync.phase {
        case .syncing:
            return "Syncing…"
        case .error(let message):
            return message
        default:
            if let last = sync.lastSyncedAt {
                let time = last.formatted(date: .omitted, time: .shortened).lowercased()
                return "Synced \(time) · changes appear on your iPhone"
            }
            return "Waiting for the first sync"
        }
    }

    @ViewBuilder
    private var signedOutBody: some View {
        Text("Sign in with your phone number to mirror this feed in the iPhone app.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if step == .idle || step == .sendingCode {
            HStack(spacing: 6) {
                TextField("+1 415 555 0137", text: $phone)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                Button(step == .sendingCode ? "Sending…" : "Send code") {
                    sendCode()
                }
                .buttonStyle(.ghost)
                .disabled(step == .sendingCode || normalizedPhone == nil)
            }
        } else {
            HStack(spacing: 6) {
                TextField("6-digit code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .onSubmit { verify() }
                Button(step == .verifying ? "Verifying…" : "Verify") {
                    verify()
                }
                .buttonStyle(.ghost)
                .disabled(step == .verifying || code.trimmingCharacters(in: .whitespaces).count < 6)
            }
            Button("Use a different number") {
                step = .idle
                code = ""
                errorText = nil
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// E.164 shape: digits with a leading plus; anything else disables Send.
    private var normalizedPhone: String? {
        let digits = phone.filter(\.isWholeNumber)
        guard digits.count >= 8 else { return nil }
        return "+\(digits)"
    }

    private func sendCode() {
        guard let normalizedPhone else { return }
        step = .sendingCode
        errorText = nil
        Task {
            do {
                try await sync.requestCode(phone: normalizedPhone)
                step = .enterCode
            } catch {
                errorText = error.localizedDescription
                step = .idle
            }
        }
    }

    private func verify() {
        guard let normalizedPhone else { return }
        step = .verifying
        errorText = nil
        Task {
            do {
                try await sync.verifyCode(
                    phone: normalizedPhone,
                    code: code.trimmingCharacters(in: .whitespaces)
                )
                step = .idle
            } catch {
                errorText = error.localizedDescription
                step = .enterCode
            }
        }
    }
}
