import XCTest
@testable import KeibordCore

/// Emoji catalog and keyword search with the real data in Resources/Emoji.
final class EmojiTests: XCTestCase {
    private static let directory = LexiconTestData.repositoryRoot.appendingPathComponent("Resources/Emoji")
    private static let all = ["de", "en", "it", "sq"]
    private static var shared: EmojiCatalog?

    private func catalog() throws -> EmojiCatalog {
        if let c = Self.shared { return c }
        guard FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("emoji.json").path) else {
            throw XCTSkip("no emoji data")
        }
        let c = try EmojiCatalog(baseURL: Self.directory)
        Self.shared = c
        return c
    }

    private func search(_ query: String, _ codes: [String] = EmojiTests.all, limit: Int = 40) throws -> [String] {
        try catalog().search(query, languageCodes: codes, limit: limit)
    }

    func testCategoriesAndPopularList() throws {
        let c = try catalog()
        XCTAssertEqual(c.categories.map(\.id), ["smileys_people", "animals_nature", "food_drink", "activity", "travel_places", "objects", "symbols", "flags"])
        let all = c.categories.flatMap(\.emojis)
        XCTAssertGreaterThan(all.count, 1800)
        XCTAssertEqual(Set(all).count, all.count, "no emoji appears twice in the grid")
        let known = Set(all)
        for emoji in EmojiCatalog.popular { XCTAssertTrue(known.contains(emoji), "popular \(emoji) (\(emoji.unicodeScalars.map { String($0.value, radix: 16) })) is in the grid") }
        XCTAssertEqual(Set(EmojiCatalog.popular).count, EmojiCatalog.popular.count)
    }

    func testSearchesInAllFourLanguages() throws {
        let first: [(String, String)] = [
            ("herz", "❤️"), ("heart", "❤️"), ("cuore", "❤️"), ("zemër", "❤️"), ("zemer", "❤️"), ("Herz", "❤️"),
            ("lachen", "😂"), ("ridere", "😂"), ("qesh", "😂"),
            ("katze", "🐈"), ("cat", "🐈"), ("gatto", "🐈"), ("mace", "🐈"),
            ("flagge österreich", "🇦🇹"), ("Flagge Österreich", "🇦🇹"), ("österreich", "🇦🇹"), ("osterreich", "🇦🇹"),
            ("austria", "🇦🇹"), ("flag austria", "🇦🇹"), ("flagge öst", "🇦🇹"), ("österreich flagge", "🇦🇹"),
            ("kosovo", "🇽🇰"), ("flamur kosovë", "🇽🇰"), ("kosove", "🇽🇰"),
            ("albania", "🇦🇱"), ("albanien", "🇦🇱"), ("shqipëri", "🇦🇱"), ("shqiperi", "🇦🇱"),
            ("italien", "🇮🇹"), ("daumen hoch", "👍"), ("thumbs up", "👍"), ("+1", "👍"), ("pizza", "🍕"), ("t-shirt", "👕"),
        ]
        for (query, expected) in first {
            XCTAssertEqual(try search(query, limit: 5).first, expected, query)
        }
        let contains: [(String, [String], Int)] = [
            ("herz", ["♥️", "💕", "💖"], 10), ("smile", ["😀", "😊", "🙂"], 15), ("lachen", ["🤣", "😀"], 10),
            ("cat", ["🐱", "😺"], 6), ("katze", ["🐱"], 6), ("gatto", ["😺"], 10), ("qesh", ["😀"], 6), ("kuss", ["😘", "💋"], 5),
            ("accordo", ["👍"], 3), ("d’accordo", ["👍"], 3), ("bier", ["🍺", "🍻"], 2), ("sonne", ["☀️"], 3),
            ("grün", ["💚"], 10), ("grun", ["💚"], 10), ("flagge", ["🇦🇹", "🇽🇰", "🇦🇱", "🇩🇪"], 400),
        ]
        for (query, expected, within) in contains {
            let results = try search(query, limit: within)
            for e in expected { XCTAssertTrue(results.contains(e), "\(query) → \(e) in \(results)") }
        }
        // Each language alone finds its own words.
        XCTAssertEqual(try search("herz", ["de"]).first, "❤️")
        XCTAssertEqual(try search("zemër", ["sq"]).first, "❤️")
        XCTAssertEqual(try search("cuore", ["it"]).first, "❤️")
        XCTAssertFalse(try search("herz", ["en"]).contains("❤️"), "only English keywords (\"herzegovina\")")
        XCTAssertTrue(try search("xyzzyq").isEmpty)
    }

    func testInflectedFormsFallBackToTheirStem() throws {
        // Definite/plural forms that are no keyword prefix: the last letters are dropped only when
        // nothing matches.
        XCTAssertEqual(try search("kosova", limit: 5), ["🇽🇰"])
        XCTAssertEqual(try search("Kosova", ["sq"], limit: 5), ["🇽🇰"])
        XCTAssertEqual(try search("shqipëria", limit: 5), ["🇦🇱"])
        XCTAssertEqual(try search("flagge kosova", limit: 5), ["🇽🇰"])
        XCTAssertTrue(try search("smiles", ["en"], limit: 10).contains("😊"))
        XCTAssertEqual(try search("smiles", ["en"]), try search("smile", ["en"]))
        // Queries with matches are never shortened; short words keep all their letters.
        XCTAssertEqual(try search("katzen", limit: 5).first, "🐱")
        XCTAssertTrue(try search("wien").isEmpty, "4 letters: no fallback to \"wie\"")
        XCTAssertTrue(try search("xyzzyq").isEmpty, "at most two letters are dropped")
        XCTAssertTrue(try search("Пётр").isEmpty)
        XCTAssertTrue(try search("日本語の").isEmpty, "multi-byte characters are dropped whole")
    }

    func testKeywordIndexStaysSmall() throws {
        let c = try EmojiCatalog(baseURL: Self.directory)
        XCTAssertEqual(c.keywordIndexBytes, 0, "built on first search")
        _ = c.search("herz", languageCodes: Self.all)
        print("[emoji] packed keyword index: \(c.keywordIndexBytes / 1024) KiB for 4 languages")
        // ~140 KB per language (the earlier one-array-per-keyword index took ~1 MB per language).
        XCTAssertGreaterThan(c.keywordIndexBytes, 200_000)
        XCTAssertLessThan(c.keywordIndexBytes, 1_000_000)
    }

    func testRankingIsStableAndLimited() throws {
        let c = try catalog()
        let known = Set(c.categories.flatMap(\.emojis))
        for query in ["herz", "smile", "katze", "flagge", "a", "ö", "zemer", "gesicht"] {
            let results = try search(query, limit: 60)
            XCTAssertEqual(Set(results).count, results.count, query)
            XCTAssertTrue(results.allSatisfy(known.contains), query)
            XCTAssertLessThanOrEqual(results.count, 60)
            XCTAssertEqual(try search(query, ["sq", "it", "en", "de", "en"], limit: 60), results, "language order does not matter")
            XCTAssertEqual(try search(query, limit: 60), results, "repeatable")
            XCTAssertEqual(try search(query, limit: 7), Array(results.prefix(7)), "a smaller limit is a prefix")
        }
        XCTAssertTrue(try search("herz", limit: 0).isEmpty)
        XCTAssertTrue(try search("herz", limit: -3).isEmpty)
        for query in ["", "   ", " - ", ":", "’"] { XCTAssertTrue(try search(query).isEmpty, query.debugDescription) }
    }

    func testAccentAndCaseFolding() throws {
        let zemer = try search("zemër")
        XCTAssertFalse(zemer.isEmpty)
        XCTAssertEqual(try search("ZEMËR"), zemer)
        XCTAssertEqual(try search("zeme\u{308}r"), zemer, "decomposed input")
        XCTAssertEqual(try search("  zemer  "), zemer)
        XCTAssertEqual(try search("Österreich"), try search("osterreich"))
        XCTAssertEqual(EmojiCatalog.normalize("Flagge: Österreich"), Array("flagge osterreich".utf8))
        XCTAssertEqual(EmojiCatalog.normalize("d’accordo"), Array("d accordo".utf8))
        XCTAssertEqual(EmojiCatalog.normalize("  T-Shirt!! "), Array("t shirt".utf8))
        XCTAssertEqual(EmojiCatalog.normalize("ÇFARË +1 #"), Array("cfare +1 #".utf8))
        XCTAssertEqual(EmojiCatalog.normalize("Straße"), Array(Diacritics.fold("Straße").utf8))
    }

    func testSkinToneVariants() throws {
        let c = try catalog()
        let thumbs = c.variants(of: "👍")
        XCTAssertEqual(thumbs.count, 5)
        let tones: [UInt32] = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
        for (variant, tone) in zip(thumbs, tones) {
            XCTAssertEqual(variant.unicodeScalars.first?.value, 0x1F44D, "a variant is the base emoji plus a modifier")
            XCTAssertTrue(variant.unicodeScalars.contains { $0.value == tone })
        }
        XCTAssertEqual(c.variants(of: "😀"), [])
        XCTAssertEqual(c.variants(of: "nope"), [])
        XCTAssertEqual(c.variants(of: "🧑‍🤝‍🧑").count, 25)
        let grid = Set(c.categories.flatMap(\.emojis))
        let withTone = grid.filter { $0.unicodeScalars.contains { tones.contains($0.value) } }
        XCTAssertTrue(withTone.isEmpty, "skin-tone variants are only offered as variants")
    }

    func testMissingAndDamagedKeywordFiles() throws {
        _ = try catalog()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keibord-emoji-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try EmojiCatalog(baseURL: dir), "emoji.json is required")
        try FileManager.default.copyItem(at: Self.directory.appendingPathComponent("emoji.json"), to: dir.appendingPathComponent("emoji.json"))
        try FileManager.default.copyItem(at: Self.directory.appendingPathComponent("keywords-en.json"), to: dir.appendingPathComponent("keywords-en.json"))
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("keywords-it.json"))
        let partial = try EmojiCatalog(baseURL: dir)
        XCTAssertEqual(partial.categories.count, 8)
        XCTAssertEqual(partial.search("heart", languageCodes: ["de", "en", "it"]).first, "❤️")
        XCTAssertTrue(partial.search("herz", languageCodes: ["de"]).isEmpty)
        XCTAssertTrue(partial.search("cuore", languageCodes: ["it", "fr"]).isEmpty)
    }

    func testCategoryTitles() {
        XCTAssertEqual(EmojiCatalog.title(for: "flags", languageCode: "de"), "Flaggen")
        XCTAssertEqual(EmojiCatalog.title(for: "flags", languageCode: "en"), "Flags")
        XCTAssertEqual(EmojiCatalog.title(for: "flags", languageCode: "it"), "Bandiere")
        XCTAssertEqual(EmojiCatalog.title(for: "flags", languageCode: "sq"), "Flamuj")
        XCTAssertEqual(EmojiCatalog.title(for: "food_drink", languageCode: "sq-XK"), "Ushqim dhe pije")
        XCTAssertEqual(EmojiCatalog.title(for: "recents", languageCode: "de_AT"), "Häufig benutzt")
        XCTAssertEqual(EmojiCatalog.title(for: "objects", languageCode: "fr"), "Objects")
        XCTAssertEqual(EmojiCatalog.title(for: "unknown", languageCode: "de"), "unknown")
        for id in ["recents", "smileys_people", "animals_nature", "food_drink", "activity", "travel_places", "objects", "symbols", "flags"] {
            XCTAssertNotEqual(EmojiCatalog.title(for: id, languageCode: "de"), id)
            XCTAssertNotEqual(EmojiCategory(id: id, emojis: []).symbolName, "circle", id)
        }
    }

    func testSearchIsFastEnoughForEveryKeystroke() throws {
        let c = try catalog()
        _ = c.search("warm", languageCodes: Self.all)
        let queries = ["h", "he", "her", "herz", "z", "ze", "zem", "zemër", "flagge ö", "katze", "smile", "cuore", "qesh", "a"]
        let start = Date()
        for q in queries { _ = c.search(q, languageCodes: Self.all, limit: 40) }
        let perQuery = Date().timeIntervalSince(start) / Double(queries.count)
        print("[emoji] \(String(format: "%.2f", perQuery * 1000)) ms per search (4 languages)")
        // The old search folded every keyword on each call (~80 ms per search in release).
        #if DEBUG
        XCTAssertLessThan(perQuery, 0.4)
        #else
        XCTAssertLessThan(perQuery, 0.015)
        #endif
    }
}
