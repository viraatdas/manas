import SwiftUI

// Manas is light mode with a native macOS feel: warm off-white surfaces,
// generous whitespace, and a single warm coral accent doing all the work.
// Everything not defined here pulls from system colors so the app adapts if
// dark mode is ever added. Icons are always SF Symbols. Text uses system text
// styles (.subheadline, .caption, ...) — never fixed point sizes. Copy is
// sentence case everywhere. No gradients, no heavy shadows: flat cards with
// hairline borders.

// MARK: - Palette

extension Color {
    /// The one accent color (warm coral, #D85A30). Use for primary actions,
    /// selected states, and verdict emphasis — and nothing else.
    static let manasAccent = Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)

    /// Warm off-white window surface (#FAF8F5). The default background.
    static let manasBackground = Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255)

    /// Slightly darker warm surface (#F2EFE9) for visually quieter secondary
    /// sections (e.g. discovered activities). Sits on `manasBackground`
    /// without a border.
    static let surface1 = Color(red: 242 / 255, green: 239 / 255, blue: 233 / 255)

    /// Hairline border color, straight from the system.
    static let hairline = Color(nsColor: .separatorColor)
}

// MARK: - Cards

/// A flat card: content background, 0.5pt hairline border, no shadow.
struct ManasCardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
    }
}

extension View {
    /// Wraps the view in a flat, hairline-bordered card.
    func manasCard(padding: CGFloat = 12) -> some View {
        modifier(ManasCardModifier(padding: padding))
    }
}

// MARK: - Buttons

/// Borderless button with accent-colored text, a faint tint on hover, and a
/// slightly stronger one while pressed. Use for secondary row actions like
/// accept/dismiss.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.subheadline)
                .foregroundStyle(configuration.isPressed ? Color.manasAccent.opacity(0.7) : Color.manasAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Color.manasAccent.opacity(configuration.isPressed ? 0.12 : (isHovered ? 0.08 : 0)),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    /// `Button("Accept") { ... }.buttonStyle(.ghost)`
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}

/// Plain icon button that picks up a soft neutral fill on hover — for the
/// header's chevrons, refresh, and gear.
struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(
                    Color.primary.opacity(
                        isEnabled && (isHovered || configuration.isPressed)
                            ? (configuration.isPressed ? 0.08 : 0.05) : 0
                    ),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

extension ButtonStyle where Self == HoverIconButtonStyle {
    /// `Button { } label: { Image(...) }.buttonStyle(.hoverIcon)`
    static var hoverIcon: HoverIconButtonStyle { HoverIconButtonStyle() }
}

// MARK: - Model picker

/// Segmented control in the app's own chip language — selected segment gets
/// the accent, never the system tint. Native segmented controls follow the
/// system accent color (blue), which would break the one-accent rule.
struct JudgeModelPicker: View {
    @Binding var selection: JudgeModel
    var label: (JudgeModel) -> String = { $0.displayName }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(JudgeModel.allCases) { model in
                Button {
                    selection = model
                } label: {
                    Text(label(model))
                        .font(.subheadline)
                        .foregroundStyle(selection == model ? Color.manasAccent : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            selection == model ? Color.manasAccent.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == model ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.surface1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model")
    }
}

// MARK: - Chips

/// A small capsule with a tinted background, for verdicts and metadata.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = .manasAccent

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Verdict presentation

extension Verdict.Status {
    /// Sentence-case label for chips.
    var label: String {
        switch self {
        case .done: "Done"
        case .inProgress: "In progress"
        case .notStarted: "Not started"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .notStarted: "circle.dashed"
        case .unknown: "questionmark.circle"
        }
    }

    /// Chip tint: the accent carries positive signal; everything else stays muted.
    var tint: Color {
        switch self {
        case .done, .inProgress: .manasAccent
        case .notStarted, .unknown: Color(nsColor: .secondaryLabelColor)
        }
    }
}
