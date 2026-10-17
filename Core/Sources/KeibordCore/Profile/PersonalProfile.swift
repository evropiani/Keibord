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
        emails = c.lossyArray(.emails, default: [])
        phones = c.lossyArray(.phones, default: [])
        usernames = c.lossyArray(.usernames, default: [])
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

    private enum CodingKeys: String, CodingKey { case id, shortcut, phrase }

    /// A missing or invalid id (hand-written or older files) gets a fresh one instead of failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.optionalValue(.id, as: UUID.self) ?? UUID()
        shortcut = c.value(.shortcut, default: "")
        phrase = c.value(.phrase, default: "")
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
        // One damaged entry must not drop all shortcuts; entries without a shortcut are useless.
        shortcuts = c.lossyArray(.shortcuts, default: [TextShortcut]()).filter {
            !$0.shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Import merge: keeps this profile's details and fills empty fields from `other`; adds the
    /// shortcuts of `other` whose shortcut (case-insensitive) is not defined yet. Ids that would
    /// collide (the same shortcut renamed on one device) are replaced so lists stay identifiable.
    public func merged(with other: PersonalProfile) -> PersonalProfile {
        var result = self
        result.info = info.filled(from: other.info)
        var known = Set(shortcuts.map { TextShortcut.matchKey($0.shortcut) })
        var ids = Set(shortcuts.map(\.id))
        for var s in other.shortcuts {
            let key = TextShortcut.matchKey(s.shortcut)
            guard !key.isEmpty, known.insert(key).inserted else { continue }
            if !ids.insert(s.id).inserted {
                s.id = UUID()
                ids.insert(s.id)
            }
            result.shortcuts.append(s)
        }
        return result
    }
}

extension TextShortcut {
    /// Shortcuts are matched case-insensitively and ignoring surrounding whitespace.
    static func matchKey(_ shortcut: String) -> String {
        shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public extension PersonalInfo {
    /// These details with every empty field taken from `other`; list fields (e-mails, phones,
    /// user names) are combined without duplicates.
    func filled(from other: PersonalInfo) -> PersonalInfo {
        func pick(_ mine: String, _ theirs: String) -> String {
            mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theirs : mine
        }
        func union(_ mine: [String], _ theirs: [String]) -> [String] {
            var seen = Set(mine.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            var result = mine
            for value in theirs {
                let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty, seen.insert(key).inserted { result.append(value) }
            }
            return result
        }
        var r = self
        r.givenName = pick(givenName, other.givenName)
        r.middleName = pick(middleName, other.middleName)
        r.familyName = pick(familyName, other.familyName)
        r.nickname = pick(nickname, other.nickname)
        r.organization = pick(organization, other.organization)
        r.jobTitle = pick(jobTitle, other.jobTitle)
        r.emails = union(emails, other.emails)
        r.phones = union(phones, other.phones)
        r.usernames = union(usernames, other.usernames)
        // An address is only taken over as a whole so lines of two different addresses never mix.
        let myAddress = [street1, street2, postalCode, city, region, country]
        if myAddress.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            r.street1 = other.street1
            r.street2 = other.street2
            r.postalCode = other.postalCode
            r.city = other.city
            r.region = other.region
            r.country = other.country
        }
        r.website = pick(website, other.website)
        return r
    }
}
