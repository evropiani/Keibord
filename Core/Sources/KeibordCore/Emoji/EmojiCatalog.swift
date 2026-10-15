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
    private var keywords: [String: [String: [String]]] = [:]

    private struct FileFormat: Decodable {
        struct Category: Decodable { var id: String; var emojis: [String] }
        var categories: [Category]
        var variants: [String: [String]]?
    }

    public init(baseURL: URL) throws {
        self.baseURL = baseURL
        let data = try Data(contentsOf: baseURL.appendingPathComponent("emoji.json"))
        let file = try JSONDecoder().decode(FileFormat.self, from: data)
        categories = file.categories.map { EmojiCategory(id: $0.id, emojis: $0.emojis) }
        variantMap = file.variants ?? [:]
    }

    public func variants(of emoji: String) -> [String] { variantMap[emoji] ?? [] }

    private func keywordTable(_ code: String) -> [String: [String]] {
        if let t = keywords[code] { return t }
        let url = baseURL.appendingPathComponent("keywords-\(code).json")
        let table = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        keywords[code] = table
        return table
    }

    /// Emoji whose keywords match `query` (accent-insensitive prefix match on keyword words).
    public func search(_ query: String, languageCodes: [String], limit: Int = 40) -> [String] {
        let q = Diacritics.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var scores: [String: Int] = [:]
        var order: [String: Int] = [:]
        var position = 0
        for cat in categories { for e in cat.emojis { order[e] = position; position += 1 } }
        for code in languageCodes {
            for (emoji, words) in keywordTable(code) {
                var best = 0
                for (i, keyword) in words.enumerated() {
                    let k = Diacritics.fold(keyword)
                    if k == q { best = max(best, i == 0 ? 100 : 80) }
                    else if k.hasPrefix(q) { best = max(best, i == 0 ? 60 : 40) }
                    else if k.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { best = max(best, 20) }
                }
                if best > 0 { scores[emoji] = max(scores[emoji] ?? 0, best) }
            }
        }
        return scores.sorted {
            $0.value != $1.value ? $0.value > $1.value : (order[$0.key] ?? .max) < (order[$1.key] ?? .max)
        }.prefix(limit).map { $0.key }
    }

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
        let index = ["de": 0, "en": 1, "it": 2, "sq": 3][languageCode] ?? 1
        return titles[categoryID]?[index] ?? categoryID
    }
}
