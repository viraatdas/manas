import SwiftUI

/// Sentinel key for the leading unlabeled cluster in the drag machinery.
private let ungroupedDragKey = "__ungrouped__"
private let todoDragSpace = "today-todos"

/// Drives the custom press-to-lift drag: which todo is lifted, how far it has
/// moved, and which bucket it is hovering over. Buckets register their frames
/// so a plain point test tells us the drop target as the row follows the cursor.
@MainActor
@Observable
final class TodoDragController {
    var draggingID: Todo.ID?
    var translation: CGSize = .zero
    /// The bucket key currently under the row (nil-cluster uses the sentinel).
    var targetKey: String?
    /// The row's own bucket, so a drop back onto it is a no-op.
    var sourceKey: String?
    @ObservationIgnored private var frames: [String: CGRect] = [:]

    var isActive: Bool { draggingID != nil }
    func isDragging(_ id: Todo.ID) -> Bool { draggingID == id }
    func isTargeted(_ key: String) -> Bool { isActive && targetKey == key && targetKey != sourceKey }

    func setFrames(_ frames: [String: CGRect]) { self.frames = frames }

    func lift(id: Todo.ID, sourceKey: String) {
        draggingID = id
        self.sourceKey = sourceKey
        targetKey = sourceKey
        translation = .zero
    }

    func move(translation: CGSize, location: CGPoint) {
        self.translation = translation
        targetKey = frames.first { $0.value.contains(location) }?.key ?? sourceKey
    }

    /// The group label to drop into, or a two-state result: nil label means the
    /// ungrouped cluster; `false` return means no change (dropped on its own bucket).
    func resolveDrop(at location: CGPoint) -> (changed: Bool, label: String?) {
        let key = frames.first { $0.value.contains(location) }?.key ?? sourceKey
        guard let key, key != sourceKey else { return (false, nil) }
        return (true, key == ungroupedDragKey ? nil : key)
    }

    func reset() {
        draggingID = nil
        translation = .zero
        targetKey = nil
        sourceKey = nil
    }
}

private struct GroupFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Date-scoped add field. The visible pager day and this field always share
/// the same normalized date, so adding while looking at Friday cannot land on
/// today by accident. Todos arrive ungrouped; the judge clusters them.
struct AddTodoField: View {
    private enum FocusedField: Hashable {
        case todo
    }

    @Environment(AppStore.self) private var store
    var day: Date
    @State private var draft = ""
    @State private var selectedGroup: String?
    @FocusState private var focusedField: FocusedField?

    init(day: Date = Date()) {
        self.day = Calendar.current.startOfDay(for: day)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(focusedField != nil ? Color.manasAccent : .secondary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focusedField, equals: .todo)
                .onSubmit(submit)
                .accessibilityLabel(accessibilityLabel)

            Divider()
                .frame(height: 19)

            TodoGroupPickerButton(selection: $selectedGroup) {
                focusedField = .todo
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    focusedField != nil ? Color.manasAccent.opacity(0.7) : Color.hairline,
                    lineWidth: focusedField != nil ? 1 : 0.5
                )
        )
        .animation(.easeOut(duration: 0.15), value: focusedField)
    }

    /// The picked group sticks across adds so several todos can go into the
    /// same group in a row.
    private func submit() {
        guard store.addTodo(draft, on: day, group: selectedGroup) != nil else { return }
        draft = ""
        focusedField = .todo
    }

    private var accessibilityLabel: String {
        guard let selectedGroup else { return placeholder }
        return "\(placeholder), in \(selectedGroup)"
    }
}

private extension AddTodoField {
    var placeholder: String {
        switch Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: day
        ).day {
        case 0: "Add to today"
        case -1: "Add to yesterday"
        case 1: "Add to tomorrow"
        default: "Add to \(day.formatted(.dateTime.weekday(.wide)))"
        }
    }
}

struct TodoListSection: View {
    @Environment(AppStore.self) private var store
    var day: Date

    init(day: Date = Date()) {
        self.day = Calendar.current.startOfDay(for: day)
    }

    private var mode: TodoRow.Mode {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return .today }
        return day < calendar.startOfDay(for: Date()) ? .history : .planned
    }

    @State private var dragController = TodoDragController()

    var body: some View {
        let todos = store.todos(on: day)
        if todos.isEmpty {
            DayEmptyState(day: day)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(displayGroups) { group in
                    TodoGroupBlock(
                        group: group,
                        mode: mode,
                        showsHeader: group.group != nil,
                        dragController: mode == .today ? dragController : nil
                    )
                    // Float the bucket holding the lifted row above the others
                    // so it is never occluded while dragging across buckets.
                    .zIndex(group.todos.contains { $0.id == dragController.draggingID } ? 1 : 0)
                }
            }
            .coordinateSpace(name: todoDragSpace)
            .onPreferenceChange(GroupFramePreferenceKey.self) { frames in
                dragController.setFrames(frames)
            }
        }
    }

    /// Today always shows Work and Personal as standing buckets so any todo can
    /// be dragged into a category even before one exists. Past and future days
    /// just render whatever groups they already have.
    private var displayGroups: [TodoGroup] {
        var groups = store.todoGroups(on: day)
        guard mode == .today else { return groups }
        for bucket in store.standingGroups {
            let key = TodoGroupName.key(for: bucket)
            let exists = groups.contains { $0.group.map { TodoGroupName.key(for: $0) } == key }
            if !exists {
                groups.append(TodoGroup(group: bucket, todos: []))
            }
        }
        return groups
    }
}

private struct TodoGroupBlock: View {
    @Environment(AppStore.self) private var store
    var group: TodoGroup
    var mode: TodoRow.Mode
    var showsHeader: Bool
    var dragController: TodoDragController?

    private var doneCount: Int { group.todos.filter(\.isDone).count }
    private var frameKey: String { group.group ?? ungroupedDragKey }
    private var isTargeted: Bool { dragController?.isTargeted(frameKey) ?? false }

    /// Built-in Work and Personal always stand; only custom groups delete.
    private func isDeletable(_ label: String) -> Bool {
        let key = TodoGroupName.key(for: label)
        return !AppStore.suggestedTodoGroups.contains { TodoGroupName.key(for: $0) == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader, let label = group.group {
                HStack(spacing: 7) {
                    Text(store.emoji(forGroup: label))
                        .font(.subheadline)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(doneCount)/\(group.todos.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .contextMenu {
                    if isDeletable(label) {
                        Button("Delete group", role: .destructive) {
                            store.deleteGroup(label)
                        }
                    }
                }
            }

            content
                .background(dropHighlight)
                .background(frameReporter)
                .animation(.easeOut(duration: 0.14), value: isTargeted)
        }
    }

    @ViewBuilder
    private var content: some View {
        if group.todos.isEmpty {
            emptyDropZone
        } else {
            VStack(spacing: 0) {
                ForEach(group.todos) { todo in
                    TodoRow(todo: todo, mode: mode, dragController: dragController)
                    if todo.id != group.todos.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .manasCard(padding: 0)
        }
    }

    private var emptyDropZone: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.caption)
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.manasAccent) : AnyShapeStyle(.tertiary))
            Text(isTargeted ? "Drop to add here" : "Drag todos here")
                .font(.caption)
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.manasAccent) : AnyShapeStyle(.tertiary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.manasAccent : Color.hairline,
                    style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [4, 3])
                )
        )
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.manasAccent.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.manasAccent, lineWidth: 1.5)
                )
        }
    }

    /// Publishes this bucket's rect so the drag controller can point-test it.
    private var frameReporter: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: GroupFramePreferenceKey.self,
                value: [frameKey: geometry.frame(in: .named(todoDragSpace))]
            )
        }
    }
}

private struct DayEmptyState: View {
    var day: Date

    private var copy: (icon: String, title: String, detail: String) {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return (
                "checklist",
                "Your day is open",
                "Add a todo above. Manas will compare it with what you actually do."
            )
        }
        if day < calendar.startOfDay(for: Date()) {
            return ("calendar.badge.checkmark", "Nothing was planned", "This day has no saved todos.")
        }
        return ("calendar.badge.plus", "Nothing planned yet", "Add a todo above to give this day a head start.")
    }

    var body: some View {
        let copy = copy
        VStack(spacing: 8) {
            Image(systemName: copy.icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(copy.title)
                .font(.headline)
            Text(copy.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}

/// One visual vocabulary for today, settled history, and future planning.
/// Only the behavior varies by mode; row alignment and controls stay stable.
struct TodoRow: View {
    enum Mode {
        case today
        case history
        case planned
    }

    @Environment(AppStore.self) private var store
    var todo: Todo
    var mode: Mode = .today
    var dragController: TodoDragController?
    @State private var isHovered = false

    private var isDragging: Bool { dragController?.isDragging(todo.id) ?? false }

    var body: some View {
        if let dragController, mode == .today {
            rowBody
                .overlay(alignment: .leading) { dragHandle(dragController) }
                .scaleEffect(isDragging ? 1.03 : 1)
                .shadow(
                    color: .black.opacity(isDragging ? 0.16 : 0),
                    radius: isDragging ? 10 : 0, x: 0, y: isDragging ? 5 : 0
                )
                .offset(isDragging ? dragController.translation : .zero)
                .zIndex(isDragging ? 1 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.74), value: isDragging)
        } else {
            rowBody
        }
    }

    /// The grip that starts a drag. Rendered only while hovering or dragging so
    /// it never steals a scroll gesture from a resting row.
    @ViewBuilder
    private func dragHandle(_ controller: TodoDragController) -> some View {
        if isHovered || isDragging {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 34)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture(controller))
                .help("Drag into a group")
                .accessibilityLabel("Drag \(todo.text) into a group")
        }
    }

    private func dragGesture(_ controller: TodoDragController) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(todoDragSpace))
            .onChanged { value in
                if !controller.isDragging(todo.id) {
                    controller.lift(id: todo.id, sourceKey: todo.group ?? ungroupedDragKey)
                }
                controller.move(translation: value.translation, location: value.location)
            }
            .onEnded { value in
                let drop = controller.resolveDrop(at: value.location)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                    if drop.changed {
                        store.setTodoGroup(todo.id, group: drop.label)
                    }
                    controller.reset()
                }
            }
    }

    private var rowBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 6) {
                Text(todo.text)
                    .font(.body)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone || mode == .history ? .secondary : .primary)
                    .textSelection(.enabled)
                if !todo.isDone, mode != .planned,
                   let verdict = todo.verdict, verdict.accepted != false {
                    verdictSubRow(verdict)
                }
            }
            Spacer(minLength: 8)
            if mode == .history, !todo.isDone {
                Button("Move to today") {
                    store.moveToToday(todo.id)
                }
                .buttonStyle(.ghost)
            }
            actionsMenu
                .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(isHovered ? 0.035 : 0))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Per-todo actions: move it between groups (dragging is the fast path) and
    /// delete it. New groups are named from the add field's picker.
    private var actionsMenu: some View {
        Menu {
            if mode != .history {
                Menu("Move to group") {
                    Button {
                        store.setTodoGroup(todo.id, group: nil)
                    } label: {
                        if todo.group == nil { Label("No group", systemImage: "checkmark") }
                        else { Text("No group") }
                    }
                    if !store.availableTodoGroups.isEmpty {
                        Divider()
                        ForEach(store.availableTodoGroups, id: \.self) { group in
                            Button {
                                store.setTodoGroup(todo.id, group: group)
                            } label: {
                                if todo.group == group { Label(group, systemImage: "checkmark") }
                                else { Text(group) }
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Delete", role: .destructive) {
                store.removeTodo(todo.id)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Todo actions")
        .accessibilityLabel("Actions for \(todo.text)")
    }

    @ViewBuilder
    private var checkbox: some View {
        if mode == .history {
            checkboxImage
                .accessibilityLabel(todo.isDone ? "Done" : "Not done")
        } else {
            Button {
                store.toggleDone(todo.id)
            } label: {
                checkboxImage
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
        }
    }

    private var checkboxImage: some View {
        Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(todo.isDone ? Color.manasAccent : Color(nsColor: .tertiaryLabelColor))
            .contentTransition(.symbolEffect(.replace))
    }

    /// The judge's read on a todo: a status chip and one line of evidence.
    /// Purely informational; the checkbox is the only control.
    private func verdictSubRow(_ verdict: Verdict) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Chip(
                text: verdict.status.label,
                systemImage: verdict.status.systemImage,
                tint: verdict.status.tint
            )
            Text(verdict.evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

#Preview("Date-scoped todo list") {
    VStack(spacing: 16) {
        AddTodoField()
        TodoListSection()
    }
    .environment(AppStore.previewJudged)
    .padding(24)
    .frame(width: 520)
    .background(Color.manasBackground)
}
