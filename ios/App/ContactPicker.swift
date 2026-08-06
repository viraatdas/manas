import Contacts
import ContactsUI
import SwiftUI

/// The system contact picker, wrapped so sharing a group starts from a person
/// instead of from a typed number.
///
/// This is `CNContactPickerViewController` on purpose rather than `CNContactStore`:
/// the picker runs out of process, hands back only the one property the user
/// tapped, and therefore needs no Contacts permission and no
/// `NSContactsUsageDescription`. Reading the address book ourselves would mean
/// a privacy prompt, a usage string, and a new line on the App Store privacy
/// label — to build a list the system already draws better.
struct ContactPicker: UIViewControllerRepresentable {
    /// Called with the number the user tapped and, when the contact has one,
    /// their name — which becomes the label under their avatar.
    var onPick: (_ phone: String, _ name: String?) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Numbers only, and grey out anyone who has none — a contact with no
        // number cannot be shared with, so it should not be tappable.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // Selecting the *contact* would silently take their first number, which
        // for anyone with a work and a mobile line is a coin flip. Forcing the
        // drill-down means the number shared with is the number chosen.
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        return picker
    }

    func updateUIViewController(_: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let parent: ContactPicker

        init(_ parent: ContactPicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            guard let number = (property.value as? CNPhoneNumber)?.stringValue else {
                parent.onCancel()
                return
            }
            let name = CNContactFormatter.string(from: property.contact, style: .fullName)
            parent.onPick(number, name?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
