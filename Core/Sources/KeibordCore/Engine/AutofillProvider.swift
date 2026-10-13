import Foundation

/// Suggestions from the user's own `PersonalInfo` for personal-information fields (email, phone,
/// names, address, …). Matching is case- and accent-insensitive; every suggestion has kind `.autofill`
/// and `appendsSpace == false`, and its `display` is always the complete value.
public enum AutofillProvider {
    /// Profile values offered in a field of `kind`, in profile order, without empty values or duplicates.
    public static func values(for kind: FieldKind, info: PersonalInfo) -> [String] {
        let raw: [String]
        switch kind {
        case .email: raw = info.emails
        case .phone: raw = info.phones
        case .username: raw = info.usernames + info.emails
        case .url: raw = [info.website]
        case .fullName: raw = [info.fullName]
        case .givenName: raw = [info.givenName]
        case .middleName: raw = [info.middleName]
        case .familyName: raw = [info.familyName]
        case .nickname: raw = [info.nickname]
        case .organization: raw = [info.organization]
        case .jobTitle: raw = [info.jobTitle]
        case .fullStreetAddress: raw = [info.fullStreetAddress, info.street1]
        case .streetLine1: raw = [info.street1]
        case .streetLine2: raw = [info.street2]
        case .postalCode: raw = [info.postalCode]
        case .city: raw = [info.city]
        case .region: raw = [info.region]
        case .country: raw = [info.country]
        default: raw = []
        }
        var seen = Set<String>()
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Values whose beginning matches `typedPrefix` (the whole text typed into the field so far).
    /// The suggestion text is the complete value. Values identical to the typed text are left out.
    public static func suggestions(for kind: FieldKind, typedPrefix: String, info: PersonalInfo) -> [Suggestion] {
        let prefix = fold(typedPrefix)
        return values(for: kind, info: info).compactMap { value in
            guard value != typedPrefix, fold(value).hasPrefix(prefix) else { return nil }
            return makeSuggestion(text: value, value: value)
        }
    }

    /// Variant used by the suggestion engine, which only knows the word before the cursor and up to two
    /// words before it (oldest first). The suggestion's `text` replaces `currentWord`, so when earlier
    /// words of a value were already typed ("senad@ha", "Senad Ha") it is the rest of the value starting
    /// at the word being typed ("hamza.at", "Hamza"). Phone numbers also match ignoring spaces and
    /// punctuation ("0660123" → "0660 123").
    public static func suggestions(for kind: FieldKind, currentWord: String, previousWords: [String], info: PersonalInfo) -> [Suggestion] {
        let current = fold(currentWord)
        let previous = previousWords.map(fold)
        var result: [Suggestion] = []
        for value in values(for: kind, info: info) {
            guard let text = completion(of: value, current: current, previous: previous, isPhone: kind == .phone),
                  text != currentWord else { continue }
            result.append(makeSuggestion(text: text, value: value))
        }
        return result
    }

    // MARK: - Helpers

    private static func completion(of value: String, current: String, previous: [String], isPhone: Bool) -> String? {
        let words = wordRanges(in: value)
        if previous.isEmpty {
            if fold(value).hasPrefix(current) { return value }
            if let first = words.first, first.folded.hasPrefix(current) {
                // The value starts with a non-word character the user already typed ("+43 …").
                return String(value[first.range.lowerBound...])
            }
            if isPhone, !current.isEmpty, let first = words.first {
                let typedDigits = digits(current)
                if !typedDigits.isEmpty, digits(value).hasPrefix(typedDigits) {
                    return String(value[first.range.lowerBound...])
                }
            }
            return nil
        }
        let p = previous.count
        guard words.count > p else { return nil }
        for i in p..<words.count where words[i].folded.hasPrefix(current) {
            if (0..<p).allSatisfy({ words[i - p + $0].folded == previous[$0] }) {
                return String(value[words[i].range.lowerBound...])
            }
        }
        return nil
    }

    private static func makeSuggestion(text: String, value: String) -> Suggestion {
        Suggestion(text: text, display: value, kind: .autofill, appendsSpace: false)
    }

    private static func fold(_ s: String) -> String {
        Diacritics.fold(TextUnits.lookupKey(s))
    }

    private static func digits(_ s: String) -> String {
        String(s.filter { $0.isASCII && $0.isNumber })
    }

    /// Words of `value` as `TextUnits.words(in:)` splits them, with their ranges.
    private static func wordRanges(in value: String) -> [(folded: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = value.startIndex
        while index < value.endIndex {
            let c = value[index]
            let next = value.index(after: index)
            let isInner = TextUnits.apostrophes.contains(c) && start != nil && next < value.endIndex
                && TextUnits.isWordCharacter(value[next])
            if TextUnits.isWordCharacter(c) || isInner {
                if start == nil { start = index }
            } else if let s = start {
                result.append((fold(String(value[s..<index])), s..<index))
                start = nil
            }
            index = next
        }
        if let s = start { result.append((fold(String(value[s...])), s..<value.endIndex)) }
        return result
    }
}
