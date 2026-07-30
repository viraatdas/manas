import Foundation

/// Normalizes phone-number text supplied by typing, paste, or iOS AutoFill.
///
/// The sign-in UI keeps the country dial code in a separate picker. AutoFill,
/// however, commonly supplies a complete international number. Treating that
/// value as national digits duplicates the dial code on submission, so an
/// explicit `+` or `00` prefix is detected and removed exactly once.
struct PhoneNumberInput: Equatable, Sendable {
    let nationalDigits: String
    let internationalDialCode: String?

    static func parse(
        _ rawValue: String,
        selectedDialCode: String,
        knownDialCodes: [String]
    ) -> PhoneNumberInput {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = asciiDigits(in: trimmed)
        let usesPlusPrefix = trimmed.hasPrefix("+") || trimmed.hasPrefix("＋")
        let usesInternationalAccessCode = !usesPlusPrefix && digits.hasPrefix("00")

        guard usesPlusPrefix || usesInternationalAccessCode else {
            return PhoneNumberInput(
                nationalDigits: digits,
                internationalDialCode: nil
            )
        }

        let internationalDigits = usesInternationalAccessCode
            ? String(digits.dropFirst(2))
            : digits
        let candidates = Set(knownDialCodes + [selectedDialCode])
            .map { (code: $0, digits: asciiDigits(in: $0)) }
            .filter { !$0.digits.isEmpty }
            .sorted { lhs, rhs in lhs.digits.count > rhs.digits.count }

        guard let match = candidates.first(where: {
            internationalDigits.hasPrefix($0.digits)
        }) else {
            // Preserve the value if the curated country list cannot identify
            // it. The UI can still let the user choose a country manually.
            return PhoneNumberInput(
                nationalDigits: internationalDigits,
                internationalDialCode: nil
            )
        }

        return PhoneNumberInput(
            nationalDigits: String(internationalDigits.dropFirst(match.digits.count)),
            internationalDialCode: match.code
        )
    }

    private static func asciiDigits(in value: String) -> String {
        value.compactMap { character in
            guard let number = character.wholeNumberValue, (0...9).contains(number) else {
                return nil
            }
            return String(number)
        }
        .joined()
    }
}
