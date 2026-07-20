import SwiftUI

/// Compact control for putting a new todo into a group, backed by a popover of
/// existing groups (built-in Work and Personal first) plus a field to name a
/// new one and pick its emoji. Grouping is manual: this picker at add time,
/// dragging afterwards.
struct TodoGroupPickerButton: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?
    var onClose: () -> Void = {}

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                if let selection {
                    Text(store.emoji(forGroup: selection))
                    Text(selection)
                        .lineLimit(1)
                        .frame(maxWidth: 108, alignment: .leading)
                        .foregroundStyle(Color.primary)
                } else {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.secondary)
                    Text("Group")
                        .foregroundStyle(Color.secondary)
                }
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
        .accessibilityLabel(selection.map { "Group: \($0)" } ?? "Choose a group")
        .help("Put new todos in a group")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TodoGroupPickerPopover(selection: $selection) {
                isPresented = false
            }
        }
        .onChange(of: isPresented) { _, isPresented in
            if !isPresented { onClose() }
        }
    }
}

private struct TodoGroupPickerPopover: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?
    var close: () -> Void

    @State private var newGroup = ""
    @State private var newGroupEmoji = ""
    @FocusState private var isNewGroupFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to group")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    option(title: "No group", group: nil, badge: nil)
                    ForEach(groupOptions, id: \.self) { group in
                        option(title: group, group: group, badge: store.emoji(forGroup: group))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 200)

            Divider()

            newGroupEditor
        }
        .frame(width: 264)
    }

    private var newGroupEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.manasAccent)
                TextField("New group", text: $newGroup)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isNewGroupFocused)
                    .onSubmit(addGroup)
                    .accessibilityLabel("New group name")
                Button("Add", action: addGroup)
                    .buttonStyle(.borderedProminent)
                    .tint(.manasAccent)
                    .controlSize(.small)
                    .disabled(store.canonicalTodoGroup(newGroup) == nil)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 30), spacing: 4)],
                spacing: 4
            ) {
                ForEach(TodoGroupName.emojiPalette, id: \.self) { emoji in
                    Button {
                        newGroupEmoji = (newGroupEmoji == emoji) ? "" : emoji
                    } label: {
                        Text(emoji)
                            .font(.title3)
                            .frame(width: 30, height: 30)
                            .background(
                                newGroupEmoji == emoji ? Color.manasAccent.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Emoji \(emoji)")
                    .accessibilityAddTraits(newGroupEmoji == emoji ? .isSelected : [])
                }
            }
        }
        .padding(10)
    }

    /// Existing groups, plus the current selection when it isn't one of them
    /// yet (a just-typed new group stays visible until the todo is saved).
    private var groupOptions: [String] {
        guard let selection else { return store.availableTodoGroups }
        let key = TodoGroupName.key(for: selection)
        if store.availableTodoGroups.contains(where: { TodoGroupName.key(for: $0) == key }) {
            return store.availableTodoGroups
        }
        return store.availableTodoGroups + [selection]
    }

    private func option(title: String, group: String?, badge: String?) -> some View {
        Button {
            selection = group
            close()
        } label: {
            HStack(spacing: 9) {
                if let badge {
                    Text(badge).frame(width: 18)
                } else {
                    Image(systemName: "tray")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 18)
                }
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if selection == group {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.manasAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroupOptionButtonStyle())
        .accessibilityAddTraits(selection == group ? .isSelected : [])
    }

    private func addGroup() {
        guard let group = store.createGroup(
            newGroup, emoji: newGroupEmoji.isEmpty ? nil : newGroupEmoji
        ) else { return }
        selection = group
        newGroup = ""
        newGroupEmoji = ""
        close()
    }
}

private struct GroupOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GroupOptionButtonBody(configuration: configuration)
    }
}

private struct GroupOptionButtonBody: View {
    let configuration: ButtonStyle.Configuration
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
