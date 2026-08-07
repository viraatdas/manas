import Foundation

/// The country calling codes this app is willing to reason about.
///
/// Identity is E.164 digits — the country code included — because that is what
/// the server derives from the JWT. A number typed without one therefore has
/// to borrow a country code from somewhere, and two places need to: resolving
/// an invite against the number the inviter is signed in as, and defaulting
/// the macOS sign-in field, which has no country picker beside it.
///
/// Both uses only ever *validate* a code, never invent one, so a curated list
/// is the safe shape: a code that is missing here makes the app decline to
/// guess and ask for a `+` instead of writing an identity that reaches nobody.
/// The list mirrors the iOS sign-in picker's countries.
enum PhoneRegion {
    /// ISO 3166-1 alpha-2 region → E.164 calling code, digits only.
    static let dialCodesByRegion: [String: String] = [
        "US": "1", "CA": "1", "GB": "44", "IN": "91", "AU": "61", "DE": "49",
        "FR": "33", "JP": "81", "BR": "55", "MX": "52", "SG": "65", "AE": "971",
        "IE": "353", "NL": "31", "ES": "34", "IT": "39", "PT": "351", "CH": "41",
        "SE": "46", "NO": "47", "DK": "45", "FI": "358", "PL": "48", "AT": "43",
        "BE": "32", "GR": "30", "CZ": "420", "RO": "40", "NZ": "64", "ZA": "27",
        "NG": "234", "KE": "254", "EG": "20", "SA": "966", "IL": "972",
        "TR": "90", "KR": "82", "CN": "86", "HK": "852", "TW": "886",
        "TH": "66", "ID": "62", "MY": "60", "PH": "63", "VN": "84", "PK": "92",
        "BD": "880", "LK": "94", "AR": "54", "CL": "56", "CO": "57", "PE": "51",
        "UA": "380", "RU": "7",
    ]

    /// Every code above, for asking "is this run of digits a country code?".
    static let dialCodes: Set<String> = Set(dialCodesByRegion.values)

    static func dialCode(forRegion region: String?) -> String? {
        guard let region, !region.isEmpty else { return nil }
        return dialCodesByRegion[region.uppercased()]
    }

    /// The calling code of the device's own region, when it is one we know.
    /// Used only as the default for a sign-in field typed without a `+`.
    static var deviceDialCode: String? {
        dialCode(forRegion: Locale.current.region?.identifier)
    }
}
