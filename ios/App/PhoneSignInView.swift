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
    /// The national number after the dial code, digits only (formatting is
    /// applied for display and stripped on submit).
    @State private var nationalDigits = ""
    @State private var country: Country = .unitedStates
    @State private var showingCountryPicker = false
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var error: String?

    @FocusState private var phoneFocused: Bool

    /// The full E.164 number the backend is called with.
    private var e164: String { country.dialCode + nationalDigits }
    private var canSendCode: Bool {
        nationalDigits.count >= country.minDigits
            && nationalDigits.count <= country.maxDigits
            && !isSubmitting
    }
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
            // The actual app icon, so the sign-in screen matches the home
            // screen instead of a stand-in glyph. iOS-style rounded corners.
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            Text("Manas")
                .font(.largeTitle.weight(.semibold))
        }
    }

    // MARK: - Step 1 · phone

    private var phoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your phone number")
                .font(.headline)
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    phoneFocused = false
                    showingCountryPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(country.flag).font(.body)
                        Text(country.dialCode)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.hairline).frame(width: 0.5, height: 22)
                        .offset(x: 8)
                }
                TextField(country.placeholder, text: nationalField)
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
        .sheet(isPresented: $showingCountryPicker) {
            CountryPickerSheet(selected: country) { picked in
                country = picked
                nationalDigits = String(nationalDigits.prefix(picked.maxDigits))
            }
            .preferredColorScheme(.light)
        }
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
        Text("We'll text you a code to sign in. Standard rates may apply.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
    }

    // MARK: - Formatting

    /// Binding that keeps `nationalDigits` clean (digits only, clamped to the
    /// country's length) while the field shows a grouped number for legibility.
    private var nationalField: Binding<String> {
        Binding(
            get: { country.format(nationalDigits) },
            set: { nationalDigits = String($0.filter(\.isNumber).prefix(country.maxDigits)) }
        )
    }

    private var displayNumber: String { "\(country.dialCode) \(country.format(nationalDigits))" }

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

/// A dial-code choice for the sign-in field: enough metadata to validate,
/// clamp, and prettify a national number. A curated list beats a 240-row
/// picker for a beta; unlisted regions can ship later by adding rows.
struct Country: Identifiable, Equatable {
    let flag: String
    let name: String
    let dialCode: String
    let minDigits: Int
    let maxDigits: Int
    let placeholder: String
    /// Indexes (0-based) after which a space is inserted for display.
    let groupBreaks: [Int]

    var id: String { name }

    func format(_ digits: String) -> String {
        var out = ""
        for (index, ch) in digits.prefix(maxDigits).enumerated() {
            if groupBreaks.contains(index) { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    static let unitedStates = Country(
        flag: "🇺🇸", name: "United States", dialCode: "+1",
        minDigits: 10, maxDigits: 10, placeholder: "555 555 0100", groupBreaks: [3, 6]
    )

    /// A generic 7–15 digit country entry for the long tail, so any number can
    /// be dialed even without a bespoke format.
    private static func generic(_ flag: String, _ name: String, _ dial: String) -> Country {
        Country(flag: flag, name: name, dialCode: dial,
                minDigits: 6, maxDigits: 14, placeholder: "phone number", groupBreaks: [3, 6, 9])
    }

    static let all: [Country] = [
        .unitedStates,
        Country(flag: "🇨🇦", name: "Canada", dialCode: "+1",
                minDigits: 10, maxDigits: 10, placeholder: "555 555 0100", groupBreaks: [3, 6]),
        Country(flag: "🇬🇧", name: "United Kingdom", dialCode: "+44",
                minDigits: 9, maxDigits: 10, placeholder: "7911 123456", groupBreaks: [4]),
        Country(flag: "🇮🇳", name: "India", dialCode: "+91",
                minDigits: 10, maxDigits: 10, placeholder: "98765 43210", groupBreaks: [5]),
        Country(flag: "🇦🇺", name: "Australia", dialCode: "+61",
                minDigits: 9, maxDigits: 9, placeholder: "412 345 678", groupBreaks: [3, 6]),
        Country(flag: "🇩🇪", name: "Germany", dialCode: "+49",
                minDigits: 10, maxDigits: 11, placeholder: "1512 3456789", groupBreaks: [4]),
        Country(flag: "🇫🇷", name: "France", dialCode: "+33",
                minDigits: 9, maxDigits: 9, placeholder: "6 12 34 56 78", groupBreaks: [1, 3, 5, 7]),
        Country(flag: "🇯🇵", name: "Japan", dialCode: "+81",
                minDigits: 10, maxDigits: 10, placeholder: "90 1234 5678", groupBreaks: [2, 6]),
        Country(flag: "🇧🇷", name: "Brazil", dialCode: "+55",
                minDigits: 10, maxDigits: 11, placeholder: "11 91234 5678", groupBreaks: [2, 7]),
        Country(flag: "🇲🇽", name: "Mexico", dialCode: "+52",
                minDigits: 10, maxDigits: 10, placeholder: "55 1234 5678", groupBreaks: [2, 6]),
        Country(flag: "🇸🇬", name: "Singapore", dialCode: "+65",
                minDigits: 8, maxDigits: 8, placeholder: "9123 4567", groupBreaks: [4]),
        Country(flag: "🇦🇪", name: "United Arab Emirates", dialCode: "+971",
                minDigits: 9, maxDigits: 9, placeholder: "50 123 4567", groupBreaks: [2, 5]),
        generic("🇮🇪", "Ireland", "+353"), generic("🇳🇱", "Netherlands", "+31"),
        generic("🇪🇸", "Spain", "+34"), generic("🇮🇹", "Italy", "+39"),
        generic("🇵🇹", "Portugal", "+351"), generic("🇨🇭", "Switzerland", "+41"),
        generic("🇸🇪", "Sweden", "+46"), generic("🇳🇴", "Norway", "+47"),
        generic("🇩🇰", "Denmark", "+45"), generic("🇫🇮", "Finland", "+358"),
        generic("🇵🇱", "Poland", "+48"), generic("🇦🇹", "Austria", "+43"),
        generic("🇧🇪", "Belgium", "+32"), generic("🇬🇷", "Greece", "+30"),
        generic("🇨🇿", "Czechia", "+420"), generic("🇷🇴", "Romania", "+40"),
        generic("🇳🇿", "New Zealand", "+64"), generic("🇿🇦", "South Africa", "+27"),
        generic("🇳🇬", "Nigeria", "+234"), generic("🇰🇪", "Kenya", "+254"),
        generic("🇪🇬", "Egypt", "+20"), generic("🇸🇦", "Saudi Arabia", "+966"),
        generic("🇮🇱", "Israel", "+972"), generic("🇹🇷", "Türkiye", "+90"),
        generic("🇰🇷", "South Korea", "+82"), generic("🇨🇳", "China", "+86"),
        generic("🇭🇰", "Hong Kong", "+852"), generic("🇹🇼", "Taiwan", "+886"),
        generic("🇹🇭", "Thailand", "+66"), generic("🇮🇩", "Indonesia", "+62"),
        generic("🇲🇾", "Malaysia", "+60"), generic("🇵🇭", "Philippines", "+63"),
        generic("🇻🇳", "Vietnam", "+84"), generic("🇵🇰", "Pakistan", "+92"),
        generic("🇧🇩", "Bangladesh", "+880"), generic("🇱🇰", "Sri Lanka", "+94"),
        generic("🇦🇷", "Argentina", "+54"), generic("🇨🇱", "Chile", "+56"),
        generic("🇨🇴", "Colombia", "+57"), generic("🇵🇪", "Peru", "+51"),
        generic("🇺🇦", "Ukraine", "+380"), generic("🇷🇺", "Russia", "+7"),
    ]
}

/// A searchable full-screen country picker — better than a long inline menu.
/// Filter by name or dial code; tap to select.
private struct CountryPickerSheet: View {
    let selected: Country
    let onSelect: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Country.all }
        return Country.all.filter {
            $0.name.lowercased().contains(q) || $0.dialCode.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { country in
                Button {
                    Haptics.tap()
                    onSelect(country)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag).font(.title3)
                        Text(country.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(country.dialCode)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if country == selected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.manasAccent)
                        }
                    }
                }
                .listRowBackground(Color.surfaceRaised)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.manasBackground)
            .searchable(text: $query, prompt: "Search country or code")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Color.manasAccent)
                }
            }
        }
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
