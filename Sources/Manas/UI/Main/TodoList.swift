import AppKit
import SwiftUI

/// Pure wrap-around selection math for Tab / Shift+Tab keyboard navigation,
/// kept free of view state so it is unit-testable. A nil or vanished current
/// selection restarts from the end the walk enters on.
enum TodoKeyboardSelection {
    static func next(after current: Todo.ID?, delta: Int, in ordered: [Todo]) -> Todo.ID? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(where: { $0.id == current }) else {
            return (delta >= 0 ? ordered.first : ordered.last)?.id
        }
        let count = ordered.count
        return ordered[((index + delta) % count + count) % count].id
    }
}

/// Sentinel key for the leading unlabeled cluster in the drag machinery.
private let ungroupedDragKey = "__ungrouped__"
private let todoDragSpace = "today-todos"

/// Drives the custom press-to-lift drag: which todo is lifted, how far it has
/// moved, and which bucket it is hovering over. Buckets register their frames
/// so a plain point test tells us the drop target as the row follows the cursor.
@MainActor
@Observable
final class TodoDragController {
    /// The lifted todo, rendered as a floating card that follows the cursor
    /// while its slot in the list collapses so the rest makes room.
    var dragging: Todo?
    var translation: CGSize = .zero
    /// Where the row sat when lifted, in the list's coordinate space.
    var startFrame: CGRect = .zero
    /// The bucket key currently under the cursor (nil-cluster uses the sentinel).
    var targetKey: String?
    /// The row's own bucket, so a drop back onto it is a no-op.
    var sourceKey: String?
    /// While the card hovers over its own bucket, the real row it will land
    /// next to and whether it drops into that row's bottom half. Observed so
    /// the list reflows a preview as the card moves. Held sticky (only updated
    /// when the cursor is over another real row) so hovering the card's own
    /// gap doesn't snap the preview back to the origin.
    var reorderAnchorID: Todo.ID?
    var reorderAfter = false
    @ObservationIgnored private var bucketFrames: [String: CGRect] = [:]
    @ObservationIgnored private var rowFrames: [String: CGRect] = [:]
    /// The row the cursor is currently over, so a haptic fires once per row
    /// the dragged card passes, not continuously.
    @ObservationIgnored private var hoveredRowKey: String?

    var isActive: Bool { dragging != nil }
    var draggingID: Todo.ID? { dragging?.id }
    func isDragging(_ id: Todo.ID) -> Bool { dragging?.id == id }
    func isTargeted(_ key: String) -> Bool { isActive && targetKey == key && targetKey != sourceKey }

    /// The floating card's center, in list space, as it tracks the cursor.
    var floatingCenter: CGPoint {
        CGPoint(x: startFrame.midX + translation.width, y: startFrame.midY + translation.height)
    }

    func setBucketFrames(_ frames: [String: CGRect]) { bucketFrames = frames }
    func setRowFrames(_ frames: [String: CGRect]) { rowFrames = frames }

    func lift(_ todo: Todo, sourceKey: String) {
        dragging = todo
        self.sourceKey = sourceKey
        targetKey = sourceKey
        translation = .zero
        startFrame = rowFrames[todo.id.uuidString] ?? .zero
        hoveredRowKey = todo.id.uuidString
        reorderAnchorID = nil
        reorderAfter = false
        // A firm tap as the card leaves the list and starts following the cursor.
        Haptics.bump()
    }

    func move(translation: CGSize, location: CGPoint) {
        self.translation = translation
        let newTarget = bucketFrames.first { $0.value.contains(location) }?.key ?? sourceKey
        let rowUnder = rowFrames.first { $0.value.contains(location) }?.key
        // A firm tap each time the card passes over a new row or crosses into a
        // different bucket, so the whole drag ticks past like a physical stack.
        if rowUnder != hoveredRowKey || newTarget != targetKey {
            Haptics.bump()
        }
        hoveredRowKey = rowUnder
        targetKey = newTarget
        // Within its own bucket, resolve the real row the card is landing next
        // to (ignoring its own gap) and which half of that row the cursor is in.
        if newTarget == sourceKey,
           let rowKey = rowUnder, rowKey != dragging?.id.uuidString,
           let frame = rowFrames[rowKey], let anchorID = UUID(uuidString: rowKey) {
            reorderAnchorID = anchorID
            reorderAfter = location.y > frame.midY
        }
    }

    /// While a card hovers over its own bucket, returns that bucket's todos
    /// reordered to preview where the card will land; otherwise the list
    /// unchanged. Mirrors the commit in `AppStore.moveTodo`, so what the drag
    /// shows is exactly what the drop writes.
    func previewReorder(_ todos: [Todo], inGroup groupKey: String) -> [Todo] {
        guard let dragging, targetKey == sourceKey, sourceKey == groupKey,
              let anchorID = reorderAnchorID, anchorID != dragging.id
        else { return todos }
        var rest = todos.filter { $0.id != dragging.id }
        guard rest.count != todos.count, // the dragged card lives in this group
              let anchorIndex = rest.firstIndex(where: { $0.id == anchorID })
        else { return todos }
        rest.insert(dragging, at: reorderAfter ? anchorIndex + 1 : anchorIndex)
        return rest
    }

    /// The group to drop into; `changed == false` means it landed on its own
    /// bucket, and a nil label means the ungrouped cluster.
    func resolveDrop(at location: CGPoint) -> (changed: Bool, label: String?) {
        let key = bucketFrames.first { $0.value.contains(location) }?.key ?? sourceKey
        guard let key, key != sourceKey else { return (false, nil) }
        return (true, key == ungroupedDragKey ? nil : key)
    }

    func reset() {
        dragging = nil
        translation = .zero
        startFrame = .zero
        targetKey = nil
        sourceKey = nil
        hoveredRowKey = nil
        reorderAnchorID = nil
        reorderAfter = false
    }
}

private struct GroupFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct RowFramePreferenceKey: PreferenceKey {
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

    /// Today's field is the app's compose bar and dresses up to say so; the
    /// add fields on future days stay quiet so the feed reads calm.
    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isFocused: Bool { focusedField != nil }

    var body: some View {
        HStack(spacing: isToday ? 10 : 9) {
            plusIcon
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
        .padding(.horizontal, isToday ? 12 : 14)
        .padding(.vertical, isToday ? 13 : 11)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: Color.manasAccent.opacity(glowOpacity), radius: isFocused ? 9 : 5, x: 0, y: 2)
        .animation(.easeOut(duration: 0.15), value: focusedField)
        .onReceive(NotificationCenter.default.publisher(for: .manasFocusTodayField)) { _ in
            guard isToday else { return }
            focusedField = .todo
        }
    }

    /// Today gets a filled accent badge that reads as a compose button; other
    /// days keep the plain glyph.
    @ViewBuilder
    private var plusIcon: some View {
        if isToday {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.manasAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(isFocused ? 1.06 : 1)
        } else {
            Image(systemName: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isFocused ? Color.manasAccent : .secondary)
        }
    }

    private var borderColor: Color {
        if isToday { return Color.manasAccent.opacity(isFocused ? 0.9 : 0.4) }
        return isFocused ? Color.manasAccent.opacity(0.7) : Color.hairline
    }

    private var borderWidth: CGFloat {
        if isToday { return isFocused ? 1.5 : 1 }
        return isFocused ? 1 : 0.5
    }

    /// A soft accent halo that marks today's bar as the place to type; it
    /// deepens slightly on focus and stays off on quiet days.
    private var glowOpacity: Double {
        guard isToday else { return 0 }
        return isFocused ? 0.22 : 0.1
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
        case 0: "What's the plan for today?"
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
    @State private var selectedTodoID: Todo.ID?
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
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
                            dragController: mode == .today ? dragController : nil,
                            selectedTodoID: mode == .today ? selectedTodoID : nil
                        )
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: dragController.draggingID)
                .coordinateSpace(name: todoDragSpace)
                .onPreferenceChange(GroupFramePreferenceKey.self) { dragController.setBucketFrames($0) }
                .onPreferenceChange(RowFramePreferenceKey.self) { dragController.setRowFrames($0) }
                .overlay(alignment: .topLeading) { floatingCard }
            }
        }
        .onAppear { installKeyMonitorIfNeeded() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Keyboard selection (Tab / Shift+Tab)

    /// Today's section owns a window-level key monitor: Tab and Shift+Tab walk
    /// the selection down and up the visible rows (wrapping at the ends),
    /// Space toggles the selected todo, and Escape clears the selection.
    private func installKeyMonitorIfNeeded() {
        guard mode == .today, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { handleKeyDown(event) }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed. Popovers (NSPanel windows)
    /// and command-modified keys pass through untouched; Tab while typing
    /// blurs the field and starts walking the list, but Space and Escape
    /// never steal from an active text field.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, !(window is NSPanel) else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let isEditingText = window.firstResponder is NSTextView
        let ordered = displayGroups.flatMap(\.todos)

        switch event.keyCode {
        case 48: // Tab
            guard !ordered.isEmpty else { return false }
            if isEditingText { window.makeFirstResponder(nil) }
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            withAnimation(.easeOut(duration: 0.12)) {
                selectedTodoID = TodoKeyboardSelection.next(after: selectedTodoID, delta: delta, in: ordered)
            }
            // A light tap as the selection lands on each row.
            Haptics.tap()
            return true
        case 49: // Space
            guard !isEditingText, let selectedTodoID,
                  ordered.contains(where: { $0.id == selectedTodoID }) else { return false }
            store.toggleDone(selectedTodoID)
            return true
        case 53: // Escape
            guard !isEditingText, selectedTodoID != nil else { return false }
            selectedTodoID = nil
            return true
        default:
            return false
        }
    }

    /// The lifted card, rendered once at the list level so it travels smoothly
    /// over every bucket while its original slot holds a placeholder.
    @ViewBuilder
    private var floatingCard: some View {
        if mode == .today, let todo = dragController.dragging, dragController.startFrame.width > 0 {
            FloatingTodoCard(todo: todo)
                .frame(width: dragController.startFrame.width, height: dragController.startFrame.height)
                .position(dragController.floatingCenter)
                .allowsHitTesting(false)
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
    var selectedTodoID: Todo.ID?

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
                .padding(.horizontal, 14)
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

    /// The order to render: normally the group's todos, but while a card is
    /// being dragged within this bucket, a live preview with the card slotted
    /// into its prospective landing spot so the other rows reflow to make room.
    private var displayTodos: [Todo] {
        dragController?.previewReorder(group.todos, inGroup: frameKey) ?? group.todos
    }

    @ViewBuilder
    private var content: some View {
        if group.todos.isEmpty {
            emptyDropZone
        } else {
            let rows = displayTodos
            VStack(spacing: 0) {
                ForEach(rows) { todo in
                    TodoRow(
                        todo: todo,
                        mode: mode,
                        dragController: dragController,
                        isSelected: todo.id == selectedTodoID
                    )
                    if todo.id != rows.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: rows.map(\.id))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// The lifted card that travels with the cursor while dragging. Rendered once
/// at the list level and elevated with a shadow so it reads as picked up.
private struct FloatingTodoCard: View {
    var todo: Todo

    var body: some View {
        TodoRow(todo: todo, mode: .today, isFloating: true)
            .background(Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.manasAccent.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 10)
            .scaleEffect(1.03)
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
        VStack(spacing: 6) {
            Image(systemName: copy.icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(copy.title)
                .font(.subheadline.weight(.semibold))
            Text(copy.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
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
    /// True when Tab / Shift+Tab navigation is resting on this row.
    var isSelected = false
    /// True for the copy rendered in the floating overlay: no gestures, no
    /// frame reporting, just the visual card.
    var isFloating = false
    @State private var isHovered = false
    @State private var swipeOffset: CGFloat = 0
    @State private var isEditing = false
    @State private var editText = ""
    @State private var swipePastThreshold = false
    @State private var isPickingDate = false
    @State private var pickedDate = Date()
    @FocusState private var isEditFocused: Bool

    private var isDragging: Bool { dragController?.isDragging(todo.id) ?? false }
    private var canMove: Bool { dragController != nil && mode == .today && !isFloating }
    private var canSwipe: Bool { !isFloating && mode != .history && !isEditing }
    /// Past days are frozen history; today and future todos can be renamed.
    private var canEdit: Bool { !isFloating && mode != .history }
    private static let deleteWidth: CGFloat = 82

    var body: some View {
        if isFloating {
            rowBody
        } else {
            ZStack {
                swipeContainer
                    .opacity(isDragging ? 0 : 1)
                if isDragging {
                    dragPlaceholder
                }
            }
            .overlay { if isSelected { selectionRing } }
            .background(frameReporter)
        }
    }

    /// The keyboard-navigation highlight: an accent ring inset inside the row
    /// so Tab visibly rests here without recoloring the content.
    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.manasAccent.opacity(0.7), lineWidth: 1.5)
            .padding(2)
            .allowsHitTesting(false)
    }

    // MARK: - Swipe to delete

    private var swipeContainer: some View {
        ZStack(alignment: .trailing) {
            deleteReveal
            rowBody
                .background(Color.surfaceRaised)
                .offset(x: -swipeOffset)
                .overlay {
                    // While open, a tap anywhere on the card closes it instead
                    // of toggling the checkbox.
                    if swipeOffset > 1 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeSwipe() }
                    }
                }
                .gesture(canSwipe ? swipeGesture : nil)
        }
        .clipped()
    }

    private var deleteReveal: some View {
        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                store.removeTodo(todo.id)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "trash.fill")
                Text("Delete").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: Self.deleteWidth)
            .frame(maxHeight: .infinity)
            .background(Color.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(swipeOffset > 1 ? 1 : 0)
        .accessibilityLabel("Delete \(todo.text)")
    }

    /// Swipe left to reveal the Delete button on the trailing edge.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                swipeOffset = min(max(0, -value.translation.width), Self.deleteWidth)
                // Tap once as the swipe passes the point where releasing will
                // open Delete, so the trigger is felt without looking.
                let past = swipeOffset > Self.deleteWidth / 2
                if past != swipePastThreshold {
                    swipePastThreshold = past
                    Haptics.bump()
                }
            }
            .onEnded { value in
                swipePastThreshold = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    swipeOffset = -value.translation.width > Self.deleteWidth / 2 ? Self.deleteWidth : 0
                }
            }
    }

    private func closeSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { swipeOffset = 0 }
    }

    // MARK: - Move (drag into a group)

    /// The grip that lifts the card. It always occupies its slot in the
    /// trailing control cluster (same 24pt frame as the actions button) so
    /// nothing shifts; it just fades in on hover.
    private var moveHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(
                isDragging || isFloating ? AnyShapeStyle(Color.manasAccent) : AnyShapeStyle(.secondary)
            )
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .opacity(isHovered || isDragging || isFloating ? 1 : 0)
            .highPriorityGesture(isFloating ? nil : moveGesture)
            .help("Drag into a group")
            .accessibilityLabel("Drag \(todo.text) into a group")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(todoDragSpace))
            .onChanged { value in
                guard let controller = dragController else { return }
                if !controller.isDragging(todo.id) {
                    controller.lift(todo, sourceKey: todo.group ?? ungroupedDragKey)
                }
                controller.move(translation: value.translation, location: value.location)
            }
            .onEnded { value in
                guard let controller = dragController else { return }
                let drop = controller.resolveDrop(at: value.location)
                let reorderAnchor = controller.reorderAnchorID
                let didReorder = !drop.changed && reorderAnchor != nil && reorderAnchor != todo.id
                if drop.changed || didReorder {
                    // A firm confirm tap when the card actually lands somewhere
                    // new — a different group, or a new slot in this one.
                    Haptics.bump()
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    if drop.changed {
                        store.setTodoGroup(todo.id, group: drop.label)
                    } else if let reorderAnchor, didReorder {
                        store.moveTodo(todo.id, relativeTo: reorderAnchor, after: controller.reorderAfter)
                    }
                    controller.reset()
                }
            }
    }

    /// The empty slot left behind while the card floats, so the list clearly
    /// shows where it came from.
    private var dragPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.manasAccent.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.manasAccent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    private var frameReporter: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: [todo.id.uuidString: geometry.frame(in: .named(todoDragSpace))]
            )
        }
    }

    private var rowBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            checkbox
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    editField
                } else {
                    Text(todo.text)
                        .font(.body)
                        .strikethrough(todo.isDone)
                        .foregroundStyle(todo.isDone || mode == .history ? .secondary : .primary)
                }
                if !todo.isDone, mode != .planned,
                   let verdict = todo.verdict, verdict.accepted != false {
                    verdictSubRow(verdict)
                }
                // Waste-of-time items are auto-added already checked off, so
                // their evidence (which leads with when it happened) would
                // otherwise be hidden. Surface it as a quiet time line.
                if todo.isDone, isWasteOfTime, let verdict = todo.verdict {
                    wasteTimeSubRow(verdict)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Double-click the text area to rename in place. A large content
            // shape makes the whole column (not just the glyphs) clickable.
            .contentShape(Rectangle())
            .modifier(DoubleClickEdit(enabled: canEdit && !isEditing, action: beginEditing))
            if mode == .history, !todo.isDone {
                Button("Move to today") {
                    store.moveToToday(todo.id)
                }
                .buttonStyle(.ghost)
            }
            if !isEditing {
                HStack(spacing: 2) {
                    if canMove || isFloating {
                        moveHandle
                    }
                    actionsMenu
                        .opacity(isHovered ? 1 : 0.35)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(isHovered ? 0.035 : 0))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: - Inline edit

    /// The in-place rename field: Return (or clicking away) saves, Escape
    /// cancels. It replaces the todo text exactly where it sat so the row
    /// doesn't jump.
    private var editField: some View {
        TextField("Todo", text: $editText)
            .textFieldStyle(.plain)
            .font(.body)
            .focused($isEditFocused)
            .onSubmit(commitEditing)
            .onExitCommand(perform: cancelEditing)
            .onChange(of: isEditFocused) { _, focused in
                // Clicking another row or the background ends the edit as a save.
                if !focused, isEditing { commitEditing() }
            }
            .accessibilityLabel("Edit todo")
    }

    private func beginEditing() {
        guard canEdit else { return }
        editText = todo.text
        isEditing = true
        // Focus on the next runloop tick so the field exists first.
        DispatchQueue.main.async { isEditFocused = true }
    }

    private func commitEditing() {
        guard isEditing else { return }
        store.editTodoText(todo.id, to: editText)
        isEditing = false
    }

    private func cancelEditing() {
        isEditing = false
    }

    /// Per-todo actions: rename (also reachable by double-click), move to
    /// another day, and delete. Grouping is done by dragging, so it stays off
    /// the menu.
    private var actionsMenu: some View {
        Menu {
            if canEdit {
                Button("Edit", action: beginEditing)
            }
            if !todo.isDone {
                moveMenu
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
        .popover(isPresented: $isPickingDate, arrowEdge: .bottom) { datePickerPopover }
    }

    // MARK: - Move to another day

    /// Quick day presets plus a calendar for anything else. The current day is
    /// omitted so the menu never offers a no-op move.
    @ViewBuilder
    private var moveMenu: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let day = calendar.startOfDay(for: todo.day)
        Menu("Move to") {
            if !calendar.isDate(day, inSameDayAs: today) {
                Button("Today") { reschedule(to: today) }
            }
            if !calendar.isDate(day, inSameDayAs: tomorrow) {
                Button("Tomorrow") { reschedule(to: tomorrow) }
            }
            Button("Next week") { reschedule(to: nextWeek) }
            Divider()
            Button("Pick a date…") {
                pickedDate = day
                // Presenting the popover while the menu is still dismissing
                // races the two AppKit transitions and the popover can fail to
                // appear or flicker shut. Let the menu close first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPickingDate = true
                }
            }
        }
    }

    /// The calendar popover behind "Pick a date…". Kept compact with a live
    /// header, the app's accent on both the calendar and the confirm button,
    /// and a sized frame so the month grid never clips.
    private var datePickerPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move to")
                    .font(.headline)
                Text(pickedDate, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(Color.manasAccent)
            }
            DatePicker("", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Color.manasAccent)
            Divider()
            HStack {
                Button("Cancel") { isPickingDate = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move here") {
                    reschedule(to: pickedDate)
                    isPickingDate = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.manasAccent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func reschedule(to day: Date) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            store.rescheduleTodo(todo.id, to: day)
        }
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

    /// True when this todo lives in the built-in time-sink bucket.
    private var isWasteOfTime: Bool {
        guard let group = todo.group else { return false }
        return TodoGroupName.key(for: group) == TodoGroupName.key(for: TodoGroupName.wasteOfTime)
    }

    /// The when-it-happened line under an auto-added time sink: a clock and the
    /// judge's evidence, which is written to lead with the approximate time.
    private func wasteTimeSubRow(_ verdict: Verdict) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verdict.evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Attaches a double-click handler that begins inline editing. A
/// high-priority two-count TapGesture wins over the row's swipe DragGesture,
/// which otherwise claims the click sequence and eats the double-tap.
private struct DoubleClickEdit: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture(count: 2).onEnded(action))
        } else {
            content
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
