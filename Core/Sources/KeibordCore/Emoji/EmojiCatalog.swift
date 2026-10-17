import Foundation

public struct EmojiCategory: Hashable, Sendable {
    public var id: String
    public var emojis: [String]

    public init(id: String, emojis: [String]) {
        self.id = id
        self.emojis = emojis
    }

    /// SF Symbol for the category bar.
    public var symbolName: String {
        switch id {
        case "recents": return "clock"
        case "smileys_people": return "face.smiling"
        case "animals_nature": return "pawprint"
        case "food_drink": return "fork.knife"
        case "activity": return "soccerball"
        case "travel_places": return "car"
        case "objects": return "lightbulb"
        case "symbols": return "heart"
        case "flags": return "flag"
        default: return "circle"
        }
    }
}

/// Emoji grid data and keyword search (data from Unicode emoji-test.txt and CLDR annotations).
public final class EmojiCatalog {
    public let categories: [EmojiCategory]
    private let variantMap: [String: [String]]
    private let baseURL: URL
    /// Grid position of every emoji (ranking tie-break).
    private let position: [String: Int]
    private let lock = NSLock()
    private var indexes: [String: KeywordIndex] = [:]

    private struct FileFormat: Decodable {
        struct Category: Decodable { var id: String; var emojis: [String] }
        var categories: [Category]
        var variants: [String: [String]]?
    }

    /// Normalised keywords of one language, in grid order.
    private struct KeywordIndex {
        struct Entry {
            var emoji: String
            /// `EmojiCatalog.normalize`d keywords; the first is the CLDR name.
            var keywords: [[UInt8]]
        }
        var entries: [Entry]
    }

    public init(baseURL: URL) throws {
        self.baseURL = baseURL
        let data = try Data(contentsOf: baseURL.appendingPathComponent("emoji.json"))
        let file = try JSONDecoder().decode(FileFormat.self, from: data)
        categories = file.categories.map { EmojiCategory(id: $0.id, emojis: $0.emojis) }
        variantMap = file.variants ?? [:]
        var position: [String: Int] = [:]
        for emoji in categories.lazy.flatMap(\.emojis) where position[emoji] == nil {
            position[emoji] = position.count
        }
        self.position = position
    }

    /// Skin-tone variants of an emoji (empty when it has none).
    public func variants(of emoji: String) -> [String] { variantMap[emoji] ?? [] }

    private func keywordIndex(_ code: String) -> KeywordIndex {
        lock.lock()
        defer { lock.unlock() }
        if let index = indexes[code] { return index }
        let url = baseURL.appendingPathComponent("keywords-\(code).json")
        let table = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        let entries = table.map { emoji, words in
            KeywordIndex.Entry(emoji: emoji, keywords: words.map(EmojiCatalog.normalize).filter { !$0.isEmpty })
        }.sorted { a, b in
            let pa = position[a.emoji] ?? .max, pb = position[b.emoji] ?? .max
            return pa != pb ? pa < pb : a.emoji < b.emoji
        }
        let index = KeywordIndex(entries: entries)
        indexes[code] = index
        return index
    }

    /// Emoji whose keywords match `query` in any of the languages (accent- and case-insensitive; every
    /// word of the query must match the start of a keyword word, so "flagge österreich", "österreich"
    /// and "flagge öst" all find 🇦🇹). Ranking: a keyword equal to the query > the query as whole
    /// words of a keyword ("herz" in "rotes herz") > a keyword starting with the query > keyword
    /// words starting with the query words > query words spread over several keywords; the CLDR name
    /// counts a little more than other keywords (a little more again when it starts with the query)
    /// and widely used emoji get a small boost. Ties keep the grid order, so results are stable.
    public func search(_ query: String, languageCodes: [String], limit: Int = 40) -> [String] {
        let q = EmojiCatalog.normalize(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        let tokens = q.split(separator: EmojiCatalog.space).map(Array.init)
        var scores: [String: Int] = [:]
        var seen = Set<String>()
        for code in languageCodes where seen.insert(code).inserted {
            for entry in keywordIndex(code).entries {
                let score = EmojiCatalog.score(entry.keywords, query: q, tokens: tokens)
                if score > scores[entry.emoji] ?? 0 { scores[entry.emoji] = score }
            }
        }
        let ranked = scores.map { (emoji: $0.key, score: $0.value + EmojiCatalog.popularityBonus($0.key), rank: EmojiCatalog.popularityRank[$0.key] ?? .max) }
        return ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.rank != b.rank { return a.rank < b.rank }
            let pa = position[a.emoji] ?? .max, pb = position[b.emoji] ?? .max
            return pa != pb ? pa < pb : a.emoji < b.emoji
        }.prefix(limit).map(\.emoji)
    }

    // MARK: Matching

    private static let space = UInt8(ascii: " ")

    /// Lower-case, accent-free UTF-8 with every run of punctuation/whitespace turned into one space
    /// ("Flagge: Österreich" → "flagge osterreich", "d’accordo" → "d accordo"). Keeps "+", "#", "*".
    /// Same folding as `Diacritics.fold` (decomposed accents are dropped too), with an ASCII fast path:
    /// the keyword tables are normalised once when first searched.
    static func normalize(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        func put(_ byte: UInt8) {
            if pendingSpace {
                if !out.isEmpty { out.append(space) }
                pendingSpace = false
            }
            out.append(byte)
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let b = UInt8(scalar.value)
                switch b {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: "*"):
                    put(b)
                case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    put(b + 32)
                default:
                    pendingSpace = true
                }
                continue
            }
            let p = scalar.properties
            if p.generalCategory == .nonspacingMark || p.generalCategory == .enclosingMark || p.isVariationSelector { continue }
            guard p.isAlphabetic || p.numericType != nil else {
                pendingSpace = true
                continue
            }
            for lower in p.lowercaseMapping.unicodeScalars where lower.properties.generalCategory != .nonspacingMark {
                let c = Character(lower)
                for b in String(Diacritics.base(of: c)).utf8 { put(b) }
            }
        }
        return out
    }

    /// Best match of the query against one emoji's keywords (0 = no match).
    private static func score(_ keywords: [[UInt8]], query: [UInt8], tokens: [[UInt8]]) -> Int {
        var best = 0
        // A name that starts with the query ("cat face" for "cat") breaks ties between equal matches.
        let namePrefix = keywords.first.map { $0.count > query.count && $0.starts(with: query) } ?? false
        for (i, keyword) in keywords.enumerated() {
            let name = i == 0 ? 4 : 0
            if keyword == query { return 80 + name + (namePrefix ? 1 : 0) }
            var whole = true, prefixes = true
            for token in tokens {
                let m = wordMatch(keyword, token)
                whole = whole && m.whole
                prefixes = prefixes && m.prefix
                if !prefixes { break }
            }
            if whole { best = max(best, 60 + name) }
            else if keyword.starts(with: query) { best = max(best, 40 + name) }
            else if prefixes { best = max(best, 20 + name) }
        }
        if best == 0, tokens.count > 1,
           tokens.allSatisfy({ token in keywords.contains { wordMatch($0, token).prefix } }) {
            best = 10
        }
        return best > 0 && namePrefix ? best + 1 : best
    }

    /// Whether `token` starts a word of `text` (`prefix`) or is a whole word of it (`whole`).
    private static func wordMatch(_ text: [UInt8], _ token: [UInt8]) -> (prefix: Bool, whole: Bool) {
        let n = text.count, m = token.count
        guard m > 0, m <= n else { return (false, false) }
        var prefix = false
        var start = 0
        while start + m <= n {
            var j = 0
            while j < m, text[start + j] == token[j] { j += 1 }
            if j == m {
                prefix = true
                if start + m == n || text[start + m] == space { return (true, true) }
            }
            // Next word start.
            var k = start
            while k < n, text[k] != space { k += 1 }
            start = k + 1
        }
        return (prefix, false)
    }

    // MARK: Popularity

    /// Widely used emoji, most used first (after the Unicode emoji frequency ranking). Within the
    /// same kind of match they rank first: "herz" → ❤️ before 💌, "heart" → ❤️ before 🥰.
    static let popular: [String] = [
        "😂", "❤️", "🤣", "👍", "😭", "🙏", "😘", "🥰", "😍", "😊",
        "🎉", "😁", "💕", "🥺", "😅", "🔥", "☺️", "🤦", "♥️", "🤷",
        "🙄", "😆", "🤗", "😉", "🎂", "🤔", "👏", "🙂", "😳", "🥳",
        "😎", "👌", "💜", "😔", "💪", "✨", "💖", "👀", "😋", "😏",
        "😢", "👉", "💗", "😩", "💯", "🌹", "💞", "🎈", "💙", "😃",
        "😡", "💐", "😜", "🙈", "🤞", "😄", "🤤", "🙌", "🤪", "❣️",
        "😀", "💋", "💀", "👇", "💔", "😌", "💓", "🤩", "🙃", "😬",
        "😱", "😴", "🤭", "😐", "🌞", "😒", "😇", "🌸", "😈", "🎶",
        "✌️", "🎊", "🥵", "😞", "💚", "☀️", "🖤", "💰", "😚", "👑",
        "🎁", "💥", "🙋", "☹️", "😑", "🥴", "👈", "💩", "✅", "👋",
        "🤮", "😤", "🤢", "🌟", "❗", "😥", "🌈", "💛", "😝", "😫",
        "😲", "‼️", "🔴", "🌻", "🤯", "💃", "👊", "🤬", "🏃", "😕",
        "⚡", "☕", "🍀", "💦", "⭐", "🦋", "🤨", "🌺", "😹", "🤘",
        "🌷", "💝", "💤", "🤝", "🐰", "😓", "💘", "🍻", "😟", "😣",
    ]

    static let popularityRank: [String: Int] = {
        var ranks: [String: Int] = [:]
        for (i, e) in popular.enumerated() where ranks[e] == nil { ranks[e] = i }
        return ranks
    }()

    static func popularityBonus(_ emoji: String) -> Int {
        guard let rank = popularityRank[emoji] else { return 0 }
        switch rank {
        case ..<10: return 15
        case ..<30: return 10
        case ..<100: return 5
        default: return 2
        }
    }

    // MARK: Titles

    /// Localised category title; `languageCode` may carry a region ("sq-XK").
    public static func title(for categoryID: String, languageCode: String) -> String {
        let titles: [String: [String]] = [
            //                 de, en, it, sq
            "recents": ["Häufig benutzt", "Frequently Used", "Usate di frequente", "Të përdorura shpesh"],
            "smileys_people": ["Smileys & Personen", "Smileys & People", "Faccine e persone", "Fytyra dhe njerëz"],
            "animals_nature": ["Tiere & Natur", "Animals & Nature", "Animali e natura", "Kafshë dhe natyrë"],
            "food_drink": ["Essen & Trinken", "Food & Drink", "Cibo e bevande", "Ushqim dhe pije"],
            "activity": ["Aktivitäten", "Activity", "Attività", "Aktivitete"],
            "travel_places": ["Reisen & Orte", "Travel & Places", "Viaggi e luoghi", "Udhëtime dhe vende"],
            "objects": ["Objekte", "Objects", "Oggetti", "Objekte"],
            "symbols": ["Symbole", "Symbols", "Simboli", "Simbole"],
            "flags": ["Flaggen", "Flags", "Bandiere", "Flamuj"],
        ]
        let base = languageCode.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        let index = ["de": 0, "en": 1, "it": 2, "sq": 3][base] ?? 1
        return titles[categoryID]?[index] ?? categoryID
    }
}
