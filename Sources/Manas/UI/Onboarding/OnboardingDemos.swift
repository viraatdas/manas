import SwiftUI

/// A miniature, looping version of the product's core value: observed work
/// turns a todo into grounded evidence and surfaces something the user forgot
/// to write down.
struct OnboardingIntelligenceDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                    Text("Manas is connecting the dots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(stage >= 1 ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(stage >= 1 ? "5 sources" : "Observing")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider()

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: stage >= 3 ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(stage >= 3 ? Color.manasAccent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeOut(duration: 0.18), value: stage)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Ship the onboarding")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 6) {
                        Chip(
                            text: verdictText,
                            systemImage: verdictIcon,
                            tint: stage >= 2 ? .manasAccent : Color(nsColor: .secondaryLabelColor)
                        )
                        Text(evidenceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        }
        .task { await runDemo() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example: Manas observes five sources and marks Ship the onboarding done with evidence")
    }

    private var verdictText: String {
        switch stage {
        case 0: "Not checked"
        case 1: "Watching"
        case 2: "In progress"
        default: "Done"
        }
    }

    private var verdictIcon: String {
        switch stage {
        case 0: "circle.dashed"
        case 1: "eye"
        case 2: "circle.lefthalf.filled"
        default: "checkmark.circle.fill"
        }
    }

    private var evidenceText: String {
        switch stage {
        case 0: "Waiting for today's activity"
        case 1: "Claude and Codex activity found"
        case 2: "Three files changed in Manas"
        default: "Built in the 3:42 PM Codex session"
        }
    }

    @MainActor
    private func runDemo() async {
        if reduceMotion {
            stage = 3
            return
        }
        while !Task.isCancelled {
            stage = 3
            try? await Task.sleep(for: .milliseconds(1_600))
            stage = 0
            try? await Task.sleep(for: .milliseconds(550))
            for next in 1...3 {
                stage = next
                try? await Task.sleep(for: .milliseconds(next == 3 ? 1_800 : 650))
            }
        }
    }
}

struct OnboardingLoopView: View {
    var body: some View {
        HStack(spacing: 10) {
            loopStep(systemImage: "square.and.pencil", title: "Write it")
            connector
            loopStep(systemImage: "waveform.path.ecg", title: "Manas observes")
            connector
            loopStep(systemImage: "checkmark.circle", title: "You confirm")
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Write a todo, Manas observes your activity, then you confirm the result")
    }

    private func loopStep(systemImage: String, title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.manasAccent)
                .frame(width: 42, height: 42)
                .background(Color.manasAccent.opacity(0.10), in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var connector: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
