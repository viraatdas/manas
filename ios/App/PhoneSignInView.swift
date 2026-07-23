import SwiftUI

/// Phone-OTP sign-in for the companion app. Two calm steps on one screen: a
/// phone-number field, then a six-box code entry. Both are driven by
/// `SyncController.requestCode` / `verifyCode`; errors surface inline in
/// sentence case (no alerts). The design follows the shared language — flat
/// surfaces, hairline borders, the single coral accent, generous whitespace,
/// system text styles — so it reads as the same app as the mac build.
struct PhoneSignInView: View {
    @Environment(SyncController.self) private var sync

    /// The flow is a single view with two visual states rather than a pushed
    /// navigation stack: sending a code slides in the six-box entry, and
    /// "Use a different number" slides back. Keeping both here means the typed
    /// phone number never has to be threaded through a second screen.
    private enum Step: Equatable { case phone, code }

    @State private var step: Step = .phone
    /// The national number after the +1 prefix, digits only (formatting is
    /// applied for display and stripped on submit).
    @State private var nationalDigits = ""
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var error: String?

    @FocusState private var phoneFocused: Bool

    /// The full E.164 number the backend is called with. Fixed +1 for the beta;
    /// the field only collects the national part.
    private var e164: String { "+1" + nationalDigits }
    private var canSendCode: Bool { nationalDigits.count == 10 && !isSubmitting }
    private var canVerify: Bool { code.count == 6 && !isSubmitting }

    var body: some View {
        ZStack {
            Color.manasBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                mark
                    .padding(.bottom, 36)
                Group {
                    switch step {
                    case .phone: phoneStep
                    case .code: codeStep
                    }
                }
                .frame(maxWidth: 380)
                Spacer(minLength: 0)
                footnote
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        // Tapping the empty background dismisses the keyboard so the layout
        // settles for a clear read of the current step.
        .contentShape(Rectangle())
        .onTapGesture { phoneFocused = false }
    }

    // MARK: - Brand mark

    private var mark: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(Color.manasAccent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 5) {
                Text("Manas")
                    .font(.largeTitle.weight(.semibold))
                Text("Plan your day. See what actually happened.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Step 1 · phone

    private var phoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your phone number")
                .font(.headline)
            HStack(spacing: 10) {
                Text("+1")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.hairline).frame(width: 0.5, height: 22)
                            .offset(x: 8)
                    }
                TextField("555 555 0100", text: nationalField)
                    .font(.body.monospacedDigit())
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($phoneFocused)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(phoneFocused ? Color.manasAccent.opacity(0.7) : Color.hairline,
                                  lineWidth: phoneFocused ? 1.5 : 0.5)
            )
            .animation(.easeOut(duration: 0.15), value: phoneFocused)

            if let error { errorLine(error) }

            primaryButton(title: "Send code", isBusy: isSubmitting, enabled: canSendCode, action: sendCode)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .task {
            // Land focus on the field the first time the phone step appears so
            // the number pad is ready without a tap.
            try? await Task.sleep(for: .milliseconds(350))
            if step == .phone { phoneFocused = true }
        }
    }

    // MARK: - Step 2 · code

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter the code")
                    .font(.headline)
                Text("Sent to \(displayNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            CodeEntryField(code: $code) { if canVerify { verify() } }

            if let error { errorLine(error) }

            primaryButton(title: "Verify", isBusy: isSubmitting, enabled: canVerify, action: verify)

            Button("Use a different number") {
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.2)) {
                    error = nil
                    code = ""
                    step = .phone
                }
            }
            .buttonStyle(.ghost)
            .frame(maxWidth: .infinity)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: - Shared pieces

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(Color.manasAccent)
        .transition(.opacity)
    }

    private func primaryButton(title: String, isBusy: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.body.weight(.semibold))
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.manasAccent.opacity(enabled ? 1 : 0.4),
                       in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }

    private var footnote: some View {
        Text("SMS uses test numbers during the beta. Try +1 555 555 0100 with code 123456.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
    }

    // MARK: - Formatting

    /// Binding that keeps `nationalDigits` clean (digits only, max 10) while the
    /// field shows a grouped "555 555 0100" for legibility.
    private var nationalField: Binding<String> {
        Binding(
            get: { Self.formatNational(nationalDigits) },
            set: { nationalDigits = String($0.filter(\.isNumber).prefix(10)) }
        )
    }

    /// Groups up to ten digits as 3-3-4, the familiar US shape.
    private static func formatNational(_ digits: String) -> String {
        let d = Array(digits.prefix(10))
        var out = ""
        for (index, ch) in d.enumerated() {
            if index == 3 || index == 6 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    private var displayNumber: String { "+1 " + Self.formatNational(nationalDigits) }

    // MARK: - Actions

    private func sendCode() {
        error = nil
        isSubmitting = true
        phoneFocused = false
        Task {
            do {
                try await sync.requestCode(phone: e164)
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.22)) { step = .code }
            } catch {
                Haptics.bump()
                withAnimation(.easeOut(duration: 0.15)) { self.error = Self.sentence(error) }
            }
            isSubmitting = false
        }
    }

    private func verify() {
        error = nil
        isSubmitting = true
        Task {
            do {
                try await sync.verifyCode(phone: e164, code: code)
                Haptics.bump() // a firm confirm as the session lands
            } catch {
                Haptics.bump()
                withAnimation(.easeOut(duration: 0.15)) {
                    self.error = Self.sentence(error)
                    code = ""
                }
                isSubmitting = false
            }
            // On success the root swaps to the feed, so no state reset is needed.
        }
    }

    /// Server messages arrive in assorted casing; present them as one tidy
    /// sentence with a trailing period.
    private static func sentence(_ error: Error) -> String {
        var message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Something went wrong. Try again." }
        message = message.prefix(1).uppercased() + message.dropFirst()
        if let last = message.last, !".!?".contains(last) { message.append(".") }
        return message
    }
}

/// A six-box one-time-code field. A single hidden `.oneTimeCode` text field
/// captures input (so SMS autofill and the number pad both work), while six
/// boxes mirror the typed digits with the active slot ringed in accent — the
/// auto-advancing feel without six separate responders to coordinate.
private struct CodeEntryField: View {
    @Binding var code: String
    var onComplete: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: field)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Verification code")

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    box(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }

    private func box(at index: Int) -> some View {
        let digits = Array(code)
        let isFilled = index < digits.count
        let isActive = focused && index == digits.count
        return Text(isFilled ? String(digits[index]) : "")
            .font(.title2.weight(.semibold).monospacedDigit())
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.manasAccent : (isFilled ? Color.manasAccent.opacity(0.4) : Color.hairline),
                                  lineWidth: isActive ? 1.5 : (isFilled ? 1 : 0.5))
            )
            .animation(.easeOut(duration: 0.12), value: isActive)
            .animation(.easeOut(duration: 0.12), value: isFilled)
    }

    /// Clamps input to six digits and fires completion on the sixth so the
    /// caller can verify the moment the code is full.
    private var field: Binding<String> {
        Binding(
            get: { code },
            set: { raw in
                let digits = String(raw.filter(\.isNumber).prefix(6))
                let wasIncomplete = code.count < 6
                code = digits
                if digits.count == 6, wasIncomplete { onComplete() }
            }
        )
    }
}
