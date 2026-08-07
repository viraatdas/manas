import Contacts
import ContactsUI
import UIKit

/// The system contact picker, so sharing a group starts from a person instead
/// of from a typed number.
///
/// This presents `CNContactPickerViewController` through UIKit rather than
/// wrapping it in a `UIViewControllerRepresentable` inside a SwiftUI `.sheet`.
/// The picker is a *remote* view controller — it runs in another process — and
/// as a sheet's root it renders but never calls its delegate back, so tapping a
/// number appeared to do nothing. That is the bug this file exists to avoid;
/// presenting it the way UIKit expects is what makes the callback fire.
///
/// Presenting it also needs no Contacts permission and no
/// `NSContactsUsageDescription`: the picker hands back only the property the
/// user tapped. Reading `CNContactStore` ourselves would mean a prompt, a usage
/// string, and a new line on the App Store privacy label.
@MainActor
// The delegate protocol predates concurrency annotations, but every callback
// arrives on the main thread — UIKit presents and dismisses there.
final class ContactPickerPresenter: NSObject, @preconcurrency CNContactPickerDelegate {
    static let shared = ContactPickerPresenter()

    /// Held for the life of the presentation: `CNContactPickerViewController`
    /// keeps only a weak delegate, so nothing else retains this callback.
    private var onPick: ((_ phone: String, _ name: String?) -> Void)?

    func present(onPick: @escaping (_ phone: String, _ name: String?) -> Void) {
        guard let presenter = Self.topViewController() else { return }
        self.onPick = onPick

        let picker = CNContactPickerViewController()
        picker.delegate = self
        // Numbers only, and anyone without one is greyed out — a contact with
        // no number cannot be shared with, so it should not be tappable.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        // One number: tapping the person is unambiguous, so take it in one tap.
        // Several: fall through to their number list, because guessing between
        // a mobile and a work line is a coin flip.
        //
        // CNUI only honours this predicate if the delegate also implements
        // `contactPicker(_:didSelect:)` for a whole CNContact. Without that it
        // logs "The predicate will be ignored", selects the contact anyway, and
        // then has nowhere to deliver it — so every tap did nothing. Both
        // delegate methods below are load-bearing; neither is dead code.
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        presenter.present(picker, animated: true)
    }

    /// A contact tapped whole — only reachable for someone with exactly one
    /// number, per the selection predicate.
    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        guard let number = contact.phoneNumbers.first?.value.stringValue else {
            onPick = nil
            return
        }
        deliver(number: number, from: contact)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
        guard let number = (property.value as? CNPhoneNumber)?.stringValue else {
            onPick = nil
            return
        }
        deliver(number: number, from: property.contact)
    }

    private func deliver(number: String, from contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onPick
        onPick = nil
        callback?(number, name)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onPick = nil
    }

    /// The frontmost presented controller, so the picker opens above the share
    /// sheet rather than being swallowed by it.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
