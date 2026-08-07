import AppKit
import SwiftUI
import XCTest

@testable import Manas

/// Layout checks for the sharing surfaces, plus an opt-in PNG dump so the
/// avatars and the share popover can be looked at without launching the app
/// over the user's own window.
@MainActor
final class SharedGroupLayoutTests: XCTestCase {
    func testASharedGroupRendersAsItsOwnBucketWithEveryoneInIt() {
        let store = AppStore.previewShared
        let groups = store.todoGroups(on: Date())
        let shared = try? XCTUnwrap(groups.first { $0.shareID != nil })

        XCTAssertEqual(shared?.group, "Manas")
        XCTAssertEqual(
            shared?.todos.map(\.text),
            [
                "Ship the usage strip",
                "Wire up the session parser",
                "Draft the release notes",
                "Check the appcast signature",
            ],
            "everyone's lines share the bucket, finished ones sunk to the bottom"
        )
        XCTAssertEqual(
            store.sharedGroups.first?.members(excluding: store.currentPhone).count, 2,
            "the header names the other people, not the user themselves"
        )
        XCTAssertEqual(store.emoji(for: shared!.destination), "🚀", "the badge travels with the share")
    }

    func testEveryRowOfASharedGroupKnowsItsAuthor() {
        let store = AppStore.previewShared
        let shared = store.todoGroups(on: Date()).first { $0.shareID != nil }!
        for todo in shared.todos {
            XCTAssertNotNil(store.author(of: todo), "\(todo.text) has no avatar to draw")
        }
        let theirs = shared.todos.first { $0.text == "Draft the release notes" }!
        XCTAssertEqual(store.memberLabel(store.author(of: theirs)!), "Ada Kane")
        XCTAssertNil(
            MemberBadge.initials(contactName: nil, displayName: nil),
            "a member nobody has named draws the unnamed glyph, never two digits of their number"
        )
        // A private group has one author by definition, so it draws no badges.
        let private_ = store.todoGroups(on: Date()).first { $0.group == "Launch" }!
        XCTAssertNil(store.author(of: private_.todos[0]))
    }

    func testTheAvatarPaletteSpreadsNeighbouringNumbersApart() {
        // Numbers inside one country differ by a handful of digits, which is
        // exactly the case a weak hash smears onto one color.
        let members = AppStore.previewShared.sharedGroups[0].members
        let slots = members.map {
            MemberBadge.paletteIndex(for: $0.phone, slots: Color.memberPalette.count)
        }
        XCTAssertEqual(Set(slots).count, members.count, "three people, three colors")
        XCTAssertTrue(slots.allSatisfy { (0..<Color.memberPalette.count).contains($0) })
    }

    func testSharedListAndPopoverLayOutWithoutClipping() {
        let store = AppStore.previewShared
        let list = fittingSize(of: TodoListSection(), store: store, width: 412)
        XCTAssertEqual(list.width, 412, accuracy: 1)
        XCTAssertGreaterThan(list.height, 300)

        let share = store.sharedGroups[0]
        let popover = fittingSize(
            of: ShareGroupPopover(label: share.name, shareID: share.id) {},
            store: store,
            width: 300
        )
        XCTAssertEqual(popover.width, 300, accuracy: 1)
        XCTAssertGreaterThan(
            popover.height, 260,
            "the invite fields, all three members, and the footer all fit"
        )
    }

    /// Optional diagnostic: MANAS_SHARE_DUMP=<dir> writes the shared day and
    /// the share popover for visual inspection.
    func testDumpSharedSnapshots() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MANAS_SHARE_DUMP"] else {
            throw XCTSkip("Set MANAS_SHARE_DUMP=<dir> to dump sharing snapshots.")
        }
        let store = AppStore.previewShared
        try dump(
            VStack(spacing: 16) { AddTodoField(); TodoListSection() }
                .padding(24)
                .frame(width: 520)
                .background(Color.manasBackground),
            store: store, name: "shared-group-list", to: outDir
        )
        let share = store.sharedGroups[0]
        try dump(
            ShareGroupPopover(label: share.name, shareID: share.id) {}
                .background(Color.manasBackground),
            store: store, name: "share-popover", to: outDir
        )
        try dump(
            ShareGroupPopover(label: "Launch", shareID: nil) {}
                .background(Color.manasBackground),
            store: store, name: "share-popover-first-invite", to: outDir
        )
    }

    private func fittingSize(
        of view: some View,
        store: AppStore,
        width: CGFloat = 472
    ) -> CGSize {
        let host = NSHostingView(rootView: AnyView(environment(view, store).frame(width: width)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func dump(_ view: some View, store: AppStore, name: String, to outDir: String) throws {
        let host = NSHostingView(rootView: AnyView(environment(view, store)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Could not create a bitmap for \(name).")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode \(name) as PNG.")
        }
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("SHARE_PNG: \(url.path) size: \(host.bounds.size)")
    }

    /// The sharing views read the sync session as well as the store, and the
    /// share popover only offers its invite fields to a signed-in number — so
    /// the layout has to be measured against one.
    private func environment(_ view: some View, _ store: AppStore) -> some View {
        view
            .environment(store)
            .environment(SyncController(
                auth: SignedInStubAuth(),
                stateURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("manas-share-test-\(UUID().uuidString).json")
            ))
    }
}

/// A session that is simply signed in, so the sharing UI renders its real
/// state without any network or keychain in the picture.
@MainActor
private final class SignedInStubAuth: SyncAuth {
    var isSignedIn: Bool { true }
    var phone: String? { "+\(AppStore.previewMyPhone)" }

    func requestCode(phone: String) async throws {}
    func verifyCode(phone: String, code: String) async throws {}
    func bearerToken() async throws -> String { "stub" }
    func deleteAccount() async throws {}
    func signOut() {}
}
