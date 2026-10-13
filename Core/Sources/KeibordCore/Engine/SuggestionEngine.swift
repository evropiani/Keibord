import Foundation

/// Spelling correction, completion and next-word prediction across the enabled languages.
/// All scores are in bits (log2 probabilities); see ARCHITECTURE.md §5.
public final class SuggestionEngine: SuggestionProviding {
    private let lexiconProvider: (KeyboardLanguage) -> WordLexicon?
    private var lexiconCache: [KeyboardLanguage: WordLexicon] = [:]
    private var missingLexicons: Set<KeyboardLanguage> = []
    private var userLexicon: WordLexicon?
    private var blocked: Set<String> = []
    /// prev lookup key → [(next lookup key, count)], plus totals per prev key.
    private var userBigrams: [String: [(String, Int)]] = [:]
    private var userBigramTotals: [String: Int] = [:]
    private var shortcuts: [String: String] = [:]
    private var supplementaryKnown: Set<String> = []
    private var profile = PersonalInfo()
    private var lastLanguages: [KeyboardLanguage] = []

    public var costModel = FuzzyCostModel.standard
    public let detector = LanguageDetector()

    /// Unknown-word baseline (log2 P) and the margin a correction must beat it by.
    public var unknownWordLog2Prob: Double = -30
    public var autocorrectMargin: Double = 6

    public init(lexiconProvider: @escaping (KeyboardLanguage) -> WordLexicon?) {
        self.lexiconProvider = lexiconProvider
    }

    // MARK: Configuration

    public func setUserLexicon(_ lexicon: WordLexicon?) { userLexicon = lexicon }

    public func setUserModel(_ model: UserModel) {
        blocked = model.blocked
        var map: [String: [(String, Int)]] = [:]
        var totals: [String: Int] = [:]
        for (key, count) in model.bigrams where count > 0 {
            let parts = key.split(separator: UserModel.bigramSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let prev = String(parts[0]), next = String(parts[1])
            map[prev, default: []].append((next, count))
            totals[prev, default: 0] += count
        }
        for key in map.keys { map[key]?.sort { $0.1 > $1.1 } }
        userBigrams = map
        userBigramTotals = totals
        var usage: [KeyboardLanguage: Int] = [:]
        for (raw, count) in model.languageUsage {
            if let language = KeyboardLanguage(rawValue: raw) { usage[language] = count }
        }
        detector.seed(usage: usage)
    }

    public func setShortcuts(_ list: [TextShortcut]) {
        rebuildShortcuts(list, supplementary: nil)
    }

    private var keibordShortcuts: [TextShortcut] = []
    private var supplementaryEntries: [(input: String, text: String)] = []

    private func rebuildShortcuts(_ list: [TextShortcut]?, supplementary: [(input: String, text: String)]?) {
        if let list = list { keibordShortcuts = list }
        if let supplementary = supplementary { supplementaryEntries = supplementary }
        var map: [String: String] = [:]
        var known: Set<String> = []
        for entry in supplementaryEntries {
            let input = entry.input.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty, !entry.text.isEmpty else { continue }
            if input == entry.text {
                for word in TextUnits.words(in: input) { known.insert(TextUnits.lookupKey(word)) }
            } else {
                map[TextUnits.lookupKey(input)] = entry.text
            }
        }
        // Keibord's own shortcuts win over iOS text replacements.
        for s in keibordShortcuts where !s.shortcut.isEmpty && !s.phrase.isEmpty {
            map[TextUnits.lookupKey(s.shortcut.trimmingCharacters(in: .whitespaces))] = s.phrase
        }
        shortcuts = map
        supplementaryKnown = known
    }

    /// iOS `UILexicon` entries: text replacements (input ≠ text) and contact names (input == text).
    public func setSupplementaryLexicon(_ entries: [(input: String, text: String)]) {
        rebuildShortcuts(nil, supplementary: entries)
    }

    public func setProfile(_ info: PersonalInfo) { profile = info }

    public func lexicon(for language: KeyboardLanguage) -> WordLexicon? {
        if let cached = lexiconCache[language] { return cached }
        if missingLexicons.contains(language) { return nil }
        // Albanian variants share one dictionary: reuse an already loaded instance.
        if let sibling = lexiconCache.first(where: { $0.key.dictionaryID == language.dictionaryID })?.value {
            lexiconCache[language] = sibling
            return sibling
        }
        guard let lexicon = lexiconProvider(language) else {
            missingLexicons.insert(language)
            return nil
        }
        lexiconCache[language] = lexicon
        return lexicon
    }

    // MARK: SuggestionProviding

    public func isKnownWord(_ word: String, languages: [KeyboardLanguage]) -> Bool {
        let key = TextUnits.lookupKey(word)
        guard !key.isEmpty else { return false }
        if supplementaryKnown.contains(key) { return true }
        if let user = userLexicon, !user.lookup(key: key).isEmpty { return true }
        for language in languages {
            if let lex = lexicon(for: language), !lex.lookup(key: key).isEmpty { return true }
        }
        return false
    }

    public func likelyLanguage(of word: String, among languages: [KeyboardLanguage]) -> KeyboardLanguage? {
        let key = TextUnits.lookupKey(word)
        var best: (KeyboardLanguage, Double)?
        for language in languages {
            guard let lex = lexicon(for: language), let id = lex.lookup(key: key).first else { continue }
            let z = lex.zipf(id) + (language == languages.first ? 0.3 : 0)
            if best == nil || z > best!.1 { best = (language, z) }
        }
        return best?.0 ?? detector.mostLikely(among: languages)
    }

    public func noteCommitted(word: String, language: KeyboardLanguage?) {
        let languages = lastLanguages
        guard languages.count > 1 else { return }
        let key = TextUnits.lookupKey(word)
        let known = languages.filter { lexicon(for: $0).map { !$0.lookup(key: key).isEmpty } ?? false }
        detector.observe(knownIn: known, among: languages)
    }

    public func suggest(_ query: SuggestionQuery) -> SuggestionResult {
        var languages: [KeyboardLanguage] = []
        for l in query.languages where !languages.contains(l) { languages.append(l) }
        lastLanguages = languages
        let field = query.field

        if field.kind.isPersonalInfo {
            let items = AutofillProvider.suggestions(for: field.kind, currentWord: query.currentWord, previousWords: query.previousWords, info: profile)
            return SuggestionResult(suggestions: Array(items.prefix(3)))
        }
        guard field.kind.isProse, !field.isSecure else { return .empty }

        let word = query.currentWord
        if word.isEmpty {
            guard query.predictionsEnabled else { return .empty }
            return SuggestionResult(suggestions: predictions(query, languages: languages))
        }
        return corrections(query, languages: languages)
    }

    // MARK: Scoring

    private struct Candidate {
        var text: String
        var score: Double
        var cost: Double
        var language: KeyboardLanguage?
        var kind: SuggestionKind
    }

    private func prior(_ language: KeyboardLanguage, _ languages: [KeyboardLanguage]) -> Double {
        var p = language == languages.first ? 1.0 : 0.0
        if languages.count > 1 { p += detector.logShare(of: language, among: languages) }
        return p
    }

    /// log2 P(next | prev) table for one lexicon.
    private func successorTable(_ lex: WordLexicon, previous: String?) -> [Int: Double] {
        guard let previous = previous, let prevID = lex.lookup(key: TextUnits.lookupKey(previous)).first else { return [:] }
        var table: [Int: Double] = [:]
        for s in lex.successors(of: prevID, limit: 256) { table[s.id] = s.log2Prob }
        return table
    }

    private func userBigramLog2(_ previous: String?, _ word: String) -> Double? {
        guard let previous = previous else { return nil }
        let prevKey = TextUnits.lookupKey(previous)
        guard let total = userBigramTotals[prevKey], total > 0,
              let entry = userBigrams[prevKey]?.first(where: { $0.0 == TextUnits.lookupKey(word) }) else { return nil }
        return log2(Double(entry.1) / Double(total + 1))
    }

    private func languageModel(unigram: Double, bigram: Double?) -> Double {
        if let bigram = bigram {
            return log2(0.7 * pow(2, bigram) + 0.3 * pow(2, unigram))
        }
        return unigram + log2(0.4)
    }

    private func corrections(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> SuggestionResult {
        let typed = query.currentWord
        let typedKey = TextUnits.lookupKey(typed)
        let chars = Array(typedKey)
        guard !chars.isEmpty else { return .empty }
        let tooLong = chars.count > 30
        let previous = query.previousWords.last

        let taps: [TapInput]
        if let given = query.taps, given.count == chars.count {
            taps = given
        } else {
            taps = chars.map { TapInput.exact(String($0)) }
        }
        let maxCost = min(20, 6 + 2.5 * Double(chars.count))

        var candidates: [String: Candidate] = [:]
        func offer(_ c: Candidate) {
            guard !blocked.contains(TextUnits.lookupKey(c.text)) else { return }
            let display = Casing.apply(typed: typed, to: c.text)
            var c = c
            c.text = display
            if let existing = candidates[display], existing.score >= c.score { return }
            candidates[display] = c
        }

        if !tooLong {
            for language in languages {
                guard let lex = lexicon(for: language) else { continue }
                let p = prior(language, languages)
                let succ = successorTable(lex, previous: previous)
                for m in lex.fuzzySearch(taps: taps, costs: costModel, maxCost: maxCost, limit: 30) {
                    let w = lex.word(m.id)
                    let lm = languageModel(unigram: lex.log2Prob(m.id), bigram: userBigramLog2(previous, w) ?? succ[m.id])
                    offer(Candidate(text: w, score: lm - m.cost + p, cost: m.cost, language: language, kind: .correction))
                }
                if chars.count >= 2 {
                    for id in lex.completions(prefix: typedKey, limit: 8) {
                        let w = lex.word(id)
                        let missing = Double(TextUnits.lookupKey(w).count - chars.count)
                        guard missing > 0 else { continue }
                        let cost = min(4, 0.5 * missing)
                        let lm = languageModel(unigram: lex.log2Prob(id), bigram: userBigramLog2(previous, w) ?? succ[id])
                        offer(Candidate(text: w, score: lm - cost + p - 1, cost: cost, language: language, kind: .completion))
                    }
                }
            }
            if let user = userLexicon {
                for m in user.fuzzySearch(taps: taps, costs: costModel, maxCost: maxCost, limit: 15) {
                    let w = user.word(m.id)
                    let lm = languageModel(unigram: user.log2Prob(m.id), bigram: userBigramLog2(previous, w))
                    offer(Candidate(text: w, score: lm - m.cost + 1, cost: m.cost, language: nil, kind: .correction))
                }
                if chars.count >= 2 {
                    for id in user.completions(prefix: typedKey, limit: 5) {
                        let w = user.word(id)
                        let missing = Double(TextUnits.lookupKey(w).count - chars.count)
                        guard missing > 0 else { continue }
                        offer(Candidate(text: w, score: user.log2Prob(id) - min(4, 0.5 * missing), cost: min(4, 0.5 * missing), language: nil, kind: .completion))
                    }
                }
            }
        }

        let ranked = candidates.values.sorted { $0.score > $1.score }
        let typedIsKnown = isKnownWord(typed, languages: languages)

        // Autocorrection
        var autocorrection: Suggestion?
        if query.autocorrectEnabled, query.field.autocorrectAllowed {
            if let phrase = shortcuts[typedKey] {
                autocorrection = Suggestion(text: phrase, kind: .shortcut, isAutocorrect: true)
            } else if chars.count >= 1, !typed.contains(where: { $0.isNumber }), !Casing.hasInnerCapitals(typed) {
                if typedIsKnown {
                    autocorrection = caseCorrection(typed: typed, key: typedKey, languages: languages)
                } else if chars.count >= 2, let best = ranked.first(where: { $0.kind == .correction && TextUnits.lookupKey($0.text) != typedKey }) {
                    let allowedCost = 4 + 2 * Double(chars.count)
                    if best.cost <= allowedCost, best.score - unknownWordLog2Prob >= autocorrectMargin,
                       query.accentRestoration || Diacritics.fold(best.text) != Diacritics.fold(typed) {
                        autocorrection = Suggestion(text: best.text, kind: .correction, isAutocorrect: true, language: best.language)
                    }
                }
            }
        }

        // Bar layout
        var bar: [Suggestion] = []
        func add(_ s: Suggestion) {
            guard bar.count < 3, !bar.contains(where: { $0.text == s.text }) else { return }
            bar.append(s)
        }
        if let ac = autocorrection {
            add(Suggestion(text: typed, display: "\u{201C}\(typed)\u{201D}", kind: .typed))
            add(ac)
        } else if !typedIsKnown || ranked.first.map({ $0.text != typed }) ?? true {
            add(Suggestion(text: typed, display: typedIsKnown ? typed : "\u{201C}\(typed)\u{201D}", kind: .typed))
        }
        for c in ranked where bar.count < 3 {
            add(Suggestion(text: c.text, kind: c.kind, language: c.language))
        }
        // A known typed word that is also the best candidate goes first, unquoted.
        if autocorrection == nil, typedIsKnown, !bar.contains(where: { $0.text == typed }) {
            if bar.count == 3 { bar.removeLast() }
            bar.insert(Suggestion(text: typed, kind: .typed), at: 0)
        }
        return SuggestionResult(suggestions: bar, autocorrection: autocorrection)
    }

    /// "haus" → "Haus" when every dictionary form of the key is capitalised (German nouns, English "I").
    private func caseCorrection(typed: String, key: String, languages: [KeyboardLanguage]) -> Suggestion? {
        guard typed == typed.lowercased() else { return nil }
        if supplementaryKnown.contains(key) { return nil }
        if let user = userLexicon, user.lookup(key: key).contains(where: { user.word($0) == typed }) { return nil }
        var forms: [(String, Double, KeyboardLanguage)] = []
        for language in languages {
            guard let lex = lexicon(for: language) else { continue }
            for id in lex.lookup(key: key) { forms.append((lex.word(id), lex.zipf(id), language)) }
        }
        guard !forms.isEmpty, forms.allSatisfy({ Casing.startsUppercase($0.0) && !Casing.isAllCaps($0.0) || $0.0 == "I" }) else { return nil }
        guard let best = forms.max(by: { $0.1 < $1.1 }), best.0 != typed else { return nil }
        return Suggestion(text: best.0, kind: .correction, isAutocorrect: true, language: best.2)
    }

    private func predictions(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> [Suggestion] {
        let previous = query.previousWords.last
        var scored: [String: (Double, KeyboardLanguage?)] = [:]
        func offer(_ word: String, _ score: Double, _ language: KeyboardLanguage?) {
            guard !word.isEmpty, !blocked.contains(TextUnits.lookupKey(word)) else { return }
            let text = query.isSentenceStart ? Casing.capitalizingFirstLetter(word) : word
            if let existing = scored[text], existing.0 >= score { return }
            scored[text] = (score, language)
        }
        if let previous = previous {
            let prevKey = TextUnits.lookupKey(previous)
            if let entries = userBigrams[prevKey], let total = userBigramTotals[prevKey] {
                for (next, count) in entries.prefix(5) {
                    // Use the learned casing if known.
                    var form = next
                    if let user = userLexicon, let id = user.lookup(key: next).first { form = user.word(id) }
                    offer(form, log2(Double(count) / Double(total + 1)) + 2, nil)
                }
            }
            for language in languages {
                guard let lex = lexicon(for: language), let prevID = lex.lookup(key: prevKey).first else { continue }
                let p = prior(language, languages)
                for s in lex.successors(of: prevID, limit: 6) {
                    offer(lex.word(s.id), s.log2Prob + p, language)
                }
            }
        }
        if scored.count < 3, let language = languages.first, let lex = lexicon(for: language) {
            var rank = 0.0
            for id in lex.topWords(limit: 12) {
                let w = lex.word(id)
                guard w.count > 1 || w == "I" else { continue }
                offer(w, -20 - rank, language)
                rank += 0.1
            }
        }
        return scored.sorted { $0.value.0 > $1.value.0 }.prefix(3).map {
            Suggestion(text: $0.key, kind: .prediction, language: $0.value.1)
        }
    }
}
