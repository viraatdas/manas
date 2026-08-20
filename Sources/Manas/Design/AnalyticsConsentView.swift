import SwiftUI

/// The analytics opt-in, asked once.
///
/// It used to be a system alert whose message ran the whole privacy story
/// together in one sentence — "never sends todo text, messages, browsing,
/// phone numbers, keystrokes, or screen recordings" — which is the most
/// reassuring thing Manas has to say and the least readable way to say it.
/// The two halves are now separate lists, so what leaves the device and what
/// never does can each be read at a glance rather than parsed.
///
/// Shared by both platforms because the promise has to be identical on both:
/// two wordings of a privacy commitment is two commitments.
struct AnalyticsConsentView: View {
    var onDecision: (Bool) -> Void

    private static let shares = [
        "Which features get used",
        "Whether a check-in succeeded",
        "Counts and timings, as numbers",
    ]

    private static let never = [
        "Your todos, or anything they say",
        "Messages, browsing, or screen contents",
        "Phone numbers or contacts",
        "Keystrokes or recordings",
    ]

    var body: some View {
        VStack(spacing: 0) {
            bindu
                .padding(.top, 28)
                .padding(.bottom, 18)

            Text("Help improve Manas?")
                .font(.title2.weight(.semibold))
            Text("Anonymous usage only — never your content.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                group("What Manas sends", items: Self.shares,
                      symbol: "checkmark", tint: Color.manasAccent)
                group("What it never sends", items: Self.never,
                      symbol: "xmark", tint: .secondary)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)

            Text("You can change this anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 20)

            buttons
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 26)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    /// The app's own mark, at the size a favicon would be: this is a question
    /// about Manas, so Manas should be the thing at the top of it.
    private var bindu: some View {
        VStack(spacing: 5) {
            Circle()
                .fill(Color.manasAccent)
                .frame(width: 30, height: 30)
            Capsule()
                .fill(Color.manasAccent)
                .frame(width: 44, height: 4)
        }
        .accessibilityHidden(true)
    }

    private func group(
        _ title: String, items: [String], symbol: String, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 13)
                    Text(item)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sharing is the accented action and declining is a plain one, but
    /// declining is deliberately a full-width button rather than a link — an
    /// opt-in whose refusal is hard to find is not really an opt-in.
    private var buttons: some View {
        VStack(spacing: 9) {
            Button {
                onDecision(true)
            } label: {
                Text("Share anonymous usage")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.manasAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                onDecision(false)
            } label: {
                Text("Not now")
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
