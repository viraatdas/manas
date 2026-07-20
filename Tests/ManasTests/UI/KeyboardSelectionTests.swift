import XCTest
@testable import Manas

final class KeyboardSelectionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_752_000_000)

    private func todos(_ count: Int) -> [Todo] {
        (0..<count).map { Todo(text: "t\($0)", createdAt: date) }
    }

    func testTabWalksForwardAndWraps() {
        let list = todos(3)
        var selection: Todo.ID?
        selection = TodoKeyboardSelection.next(after: selection, delta: 1, in: list)
        XCTAssertEqual(selection, list[0].id, "first Tab selects the first todo")
        selection = TodoKeyboardSelection.next(after: selection, delta: 1, in: list)
        XCTAssertEqual(selection, list[1].id)
        selection = TodoKeyboardSelection.next(after: selection, delta: 1, in: list)
        XCTAssertEqual(selection, list[2].id)
        selection = TodoKeyboardSelection.next(after: selection, delta: 1, in: list)
        XCTAssertEqual(selection, list[0].id, "Tab wraps from the last row back to the first")
    }

    func testShiftTabWalksBackwardAndWraps() {
        let list = todos(3)
        var selection: Todo.ID?
        selection = TodoKeyboardSelection.next(after: selection, delta: -1, in: list)
        XCTAssertEqual(selection, list[2].id, "first Shift+Tab starts from the bottom")
        selection = TodoKeyboardSelection.next(after: selection, delta: -1, in: list)
        XCTAssertEqual(selection, list[1].id)
        selection = TodoKeyboardSelection.next(after: selection, delta: -1, in: list)
        XCTAssertEqual(selection, list[0].id)
        selection = TodoKeyboardSelection.next(after: selection, delta: -1, in: list)
        XCTAssertEqual(selection, list[2].id, "Shift+Tab wraps from the first row back to the last")
    }

    func testVanishedSelectionRestartsFromTheEnteringEnd() {
        let list = todos(2)
        let deleted = Todo(text: "deleted", createdAt: date)
        XCTAssertEqual(
            TodoKeyboardSelection.next(after: deleted.id, delta: 1, in: list), list[0].id,
            "a selection that no longer exists restarts at the top going forward"
        )
        XCTAssertEqual(
            TodoKeyboardSelection.next(after: deleted.id, delta: -1, in: list), list[1].id,
            "and at the bottom going backward"
        )
    }

    func testEmptyListHasNoSelection() {
        XCTAssertNil(TodoKeyboardSelection.next(after: nil, delta: 1, in: []))
    }
}
