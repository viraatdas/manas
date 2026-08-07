import Contacts
import ContactsUI
import SwiftUI

/// "Choose from Contacts" for the share popover.
///
/// `CNContactPicker` is the out-of-process picker, the same choice the phone
/// makes: it hands back only the property the user clicked, so it needs no
/// Contacts permission, no `NSContactsUsageDescription`, and adds nothing to
/// what the app has to declare it collects. Reading `CNContactStore` directly
/// would trip TCC for a list the system already draws.
///
/// It is AppKit-only and shows relative to a view, so the button carries a
/// zero-size anchor to hang the popover off.
struct ContactPickerButton: View {
    var onPick: (_ phone: String, _ name: String?) -> Void

    @State private var anchor = ContactPickerAnchor()

    var body: some View {
        Button {
            anchor.show(onPick: onPick)
        } label: {
            Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
        }
        .buttonStyle(.ghost)
        .controlSize(.small)
        // Sized to the button, not zero. An NSPopover positioned against an
        // empty rect in an empty view has nowhere to attach and never appears,
        // which is exactly how this shipped broken the first time.
        .background(ContactPickerAnchorView(anchor: anchor))
    }
}

/// Owns the picker and the view it hangs from. `CNContactPicker` keeps no
/// strong reference to its delegate, so this holds both for the popover's life.
@MainActor
final class ContactPickerAnchor: ObservableObject {
    fileprivate weak var view: NSView?
    private var picker: CNContactPicker?
    private var delegate: Delegate?

    func show(onPick: @escaping (String, String?) -> Void) {
        // A view that has not been placed in a window yet cannot anchor a
        // popover either, so both conditions are checked rather than assumed.
        guard let view, view.window != nil, !view.bounds.isEmpty else { return }
        let picker = CNContactPicker()
        let delegate = Delegate { [weak self] phone, name in
            onPick(phone, name)
            self?.picker = nil
            self?.delegate = nil
        }
        picker.delegate = delegate
        // Numbers only — a contact with none cannot be shared with, and
        // clicking a specific number is what says which one to share to.
        picker.displayedKeys = [CNContactPhoneNumbersKey]
        self.picker = picker
        self.delegate = delegate
        picker.showRelative(to: view.bounds, of: view, preferredEdge: .maxY)
    }

    fileprivate final class Delegate: NSObject, CNContactPickerDelegate {
        private let onPick: (String, String?) -> Void

        init(onPick: @escaping (String, String?) -> Void) { self.onPick = onPick }

        /// The only callback that fires here: AppKit sends `didSelectContact`
        /// solely when `displayedKeys` is empty, and this picker sets it to the
        /// phone numbers, so the user always clicks a specific number. That is
        /// the behaviour we want anyway — guessing between someone's mobile and
        /// their work line is a coin flip.
        func contactPicker(_ picker: CNContactPicker, didSelect value: CNContactProperty) {
            guard let number = (value.value as? CNPhoneNumber)?.stringValue else { return }
            onPick(number, CNContactFormatter.string(from: value.contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct ContactPickerAnchorView: NSViewRepresentable {
    let anchor: ContactPickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
