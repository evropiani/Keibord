import Foundation

/// The user's own contact details, used for local AutoFill suggestions in matching fields.
public struct PersonalInfo: Codable, Equatable, Sendable {
    public var givenName: String = ""
    public var middleName: String = ""
    public var familyName: String = ""
    public var nickname: String = ""
    public var organization: String = ""
    public var jobTitle: String = ""
    public var emails: [String] = []
    public var phones: [String] = []
    public var usernames: [String] = []
    public var street1: String = ""
    public var street2: String = ""
    public var postalCode: String = ""
    public var city: String = ""
    public var region: String = ""
    public var country: String = ""
    public var website: String = ""

    public init() {}

    public var fullName: String {
        [givenName, middleName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var fullStreetAddress: String {
        var lines: [String] = []
        let street = [street1, street2].filter { !$0.isEmpty }.joined(separator: ", ")
        if !street.isEmpty { lines.append(street) }
        let cityLine = [postalCode, city].filter { !$0.isEmpty }.joined(separator: " ")
        if !cityLine.isEmpty { lines.append(cityLine) }
        if !country.isEmpty { lines.append(country) }
        return lines.joined(separator: ", ")
    }

    public var isEmpty: Bool { self == PersonalInfo() }

    private enum CodingKeys: String, CodingKey {
        case givenName, middleName, familyName, nickname, organization, jobTitle, emails, phones, usernames
        case street1, street2, postalCode, city, region, country, website
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        givenName = c.value(.givenName, default: "")
        middleName = c.value(.middleName, default: "")
        familyName = c.value(.familyName, default: "")
        nickname = c.value(.nickname, default: "")
        organization = c.value(.organization, default: "")
        jobTitle = c.value(.jobTitle, default: "")
        emails = c.value(.emails, default: [])
        phones = c.value(.phones, default: [])
        usernames = c.value(.usernames, default: [])
        street1 = c.value(.street1, default: "")
        street2 = c.value(.street2, default: "")
        postalCode = c.value(.postalCode, default: "")
        city = c.value(.city, default: "")
        region = c.value(.region, default: "")
        country = c.value(.country, default: "")
        website = c.value(.website, default: "")
    }
}

/// A text replacement: typing `shortcut` offers/autocorrects to `phrase` (like iOS Text Replacements).
public struct TextShortcut: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var shortcut: String
    public var phrase: String

    public init(id: UUID = UUID(), shortcut: String, phrase: String) {
        self.id = id
        self.shortcut = shortcut
        self.phrase = phrase
    }
}

/// Personal data written by the app and read by the keyboard (profile.json).
public struct PersonalProfile: Codable, Equatable, Sendable {
    public var info: PersonalInfo = PersonalInfo()
    public var shortcuts: [TextShortcut] = []

    public init(info: PersonalInfo = PersonalInfo(), shortcuts: [TextShortcut] = []) {
        self.info = info
        self.shortcuts = shortcuts
    }

    private enum CodingKeys: String, CodingKey { case info, shortcuts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = c.value(.info, default: PersonalInfo())
        shortcuts = c.value(.shortcuts, default: [])
    }
}
