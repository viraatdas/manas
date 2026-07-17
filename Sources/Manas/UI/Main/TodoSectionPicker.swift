import SwiftUI

/// Compact add-field control backed by a richer popover: familiar choices,
/// visible selection, semantic icons, and custom-section creation in one
/// place without turning todo entry into a form.
struct TodoSectionPickerButton: View {
    @Binding var selection: String?
    var onClose: () -> Void = {}

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selection.map(TodoSectionPresentation.systemImage) ?? "tag")
                    .foregroundStyle(selection == nil ? Color.secondary : Color.manasAccent)
                Text(selection ?? "Section")
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .leading)
                    .foregroundStyle(selection == nil ? Color.secondary : Color.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(isPresented ? 0.075 : 0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(selection.map { "Section: \($0)" } ?? "Choose a section")
        .help("Choose a section for new todos")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TodoSectionPickerPopover(selection: $selection) {
                isPresented = false
            }
        }
        .onChange(of: isPresented) { _, isPresented in
            if !isPresented { onClose() }
        }
    }
}

private struct TodoSectionPickerPopover: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?
    var close: () -> Void

    @State private var newSection = ""
    @FocusState private var isNewSectionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to section")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    option(title: "No section", section: nil, systemImage: "tray")
                    ForEach(sectionOptions, id: \.self) { section in
                        option(
                            title: section,
                            section: section,
                            systemImage: TodoSectionPresentation.systemImage(for: section)
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 220)

            Divider()

            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.manasAccent)
                TextField("New section", text: $newSection)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isNewSectionFocused)
                    .onSubmit(addSection)
                    .accessibilityLabel("New section name")
                Button("Add", action: addSection)
                    .buttonStyle(.borderedProminent)
                    .tint(.manasAccent)
                    .controlSize(.small)
                    .disabled(store.canonicalTodoSection(newSection) == nil)
            }
            .padding(10)
        }
        .frame(width: 250)
    }

    private var sectionOptions: [String] {
        guard let selection else { return store.availableTodoSections }
        let selectedKey = TodoSectionName.key(for: selection)
        if store.availableTodoSections.contains(where: {
            TodoSectionName.key(for: $0) == selectedKey
        }) {
            return store.availableTodoSections
        }
        return store.availableTodoSections + [selection]
    }

    private func option(
        title: String,
        section: String?,
        systemImage: String
    ) -> some View {
        Button {
            selection = section
            close()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(section == nil ? Color.secondary : Color.manasAccent)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if selection == section {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.manasAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(TodoSectionOptionButtonStyle())
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    private func addSection() {
        guard let section = store.canonicalTodoSection(newSection) else { return }
        selection = section
        newSection = ""
        close()
    }
}

private struct TodoSectionOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    fileprivate struct Body: View {
        var configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovered ? 0.05 : 0)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

private enum TodoSectionPresentation {
    static func systemImage(for section: String) -> String {
        switch TodoSectionName.key(for: section) {
        case TodoSectionName.key(for: "Work"):
            "briefcase"
        case TodoSectionName.key(for: "Personal"):
            "person"
        case TodoSectionName.key(for: "Projects"):
            "hammer"
        default:
            "tag"
        }
    }
}
