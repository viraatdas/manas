import Testing
@testable import Manas

@Suite("Phone number input")
struct PhoneNumberInputTests {
    private let dialCodes = ["+1", "+44", "+91", "+61", "+971"]

    @Test("AutoFill removes the already-selected country code")
    func selectedCountryCodeIsNotDuplicated() {
        let parsed = PhoneNumberInput.parse(
            "+1 (415) 555-0137",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == "+1")
        #expect(parsed.nationalDigits == "4155550137")
    }

    @Test("AutoFill can infer a different country")
    func differentCountryIsInferred() {
        let parsed = PhoneNumberInput.parse(
            "+44 7911 123456",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == "+44")
        #expect(parsed.nationalDigits == "7911123456")
    }

    @Test("International access-code format is supported")
    func doubleZeroPrefixIsSupported() {
        let parsed = PhoneNumberInput.parse(
            "0044 7911 123456",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == "+44")
        #expect(parsed.nationalDigits == "7911123456")
    }

    @Test("The longest matching dial code wins")
    func longestDialCodeWins() {
        let parsed = PhoneNumberInput.parse(
            "+971 50 123 4567",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == "+971")
        #expect(parsed.nationalDigits == "501234567")
    }

    @Test("A local number beginning with the dial-code digit is untouched")
    func localLeadingDigitIsPreserved() {
        let parsed = PhoneNumberInput.parse(
            "123 456 7890",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == nil)
        #expect(parsed.nationalDigits == "1234567890")
    }

    @Test("Localized digits normalize to the backend's ASCII format")
    func localizedDigitsAreNormalized() {
        let parsed = PhoneNumberInput.parse(
            "+٩١ ٩٨٧٦٥ ٤٣٢١٠",
            selectedDialCode: "+1",
            knownDialCodes: dialCodes
        )

        #expect(parsed.internationalDialCode == "+91")
        #expect(parsed.nationalDigits == "9876543210")
    }
}
