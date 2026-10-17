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

    /// Edit costs, tuned on the evaluation set in `EngineQualityTests` (transpositions such as "freind"
    /// and missing letters are common slips; an extra letter is rarer and often a deliberate
    /// abbreviation or dialect spelling; a missing accent is the most common "error" of all).
    public var costModel = FuzzyCostModel(substitution: 10, insertion: 6.5, deletion: 8, transposition: 5, diacritic: 1.5)
    public let detector = LanguageDetector()

    /// Unknown-word baseline (log2 P) and the margin a correction must beat it by.
    public var unknownWordLog2Prob: Double = -30
    public var autocorrectMargin: Double = 6
    /// Extra margin (bits) by typed length: index = number of letters, longer words use 0. Short unknown
    /// strings are often slang or abbreviations ("thx", "joa", "nimma") one edit away from a frequent word.
    public var shortWordMargins: [Double] = [12, 12, 12, 11, 6, 5]
    /// Extra margin when a capitalised word in mid-sentence would become a lower-case word (names).
    public var properNounMargin: Double = 6
    /// Cost of a doubled / undoubled letter ("komen" → "kommen", "habben" → "haben").
    public var doubledLetterCost: Double = 3.5
    /// German "ss" → "ß" / "ae" → "ä" and British ↔ American spellings, per replacement.
    public var spellingRuleCost: Double = 2
    /// A case correction needs the capitalised forms to be this many bits more likely than the typed form.
    public var caseCorrectionMargin: Double = 3
    /// Minimum zipf of a case correction for words of up to three letters (short rare capitalised
    /// words are mostly names: "ty" ≠ "Ty", "np" ≠ "Np").
    public var shortCaseCorrectionMinZipf: Double = 4
    /// Edit cost up to which a correction counts as cheap (accents, close taps, apostrophes).
    public var cheapCorrectionCost: Double = 4
    /// Penalty for a capitalised form when the word was typed in lower case and a lower-case form of the
    /// same key exists (both carry the frequency of the key).
    public var casingTieBreak: Double = 0.5
    /// Completion cost per letter still missing, and its cap. Small: the bar should rank completions
    /// by frequency ("Entschuldi" → "Entschuldigung"), not by how short they are.
    public var completionCostPerLetter: Double = 0.25
    public var completionCostCap: Double = 2
    /// When the typed letters start a word, the correction must still beat that completion's score
    /// minus this many bits (pressing space after a prefix is unlikely, a typo is not): "Nachri" stays,
    /// not "Nach"; "color" → "colour" despite "Colorado".
    public var prefixStopPenalty: Double = 3
    /// Minimum zipf of a case correction for words of four or five letters ("brea" ≠ "Brea"). Longer
    /// capitalised forms are mostly nouns and need no minimum ("schwammerl" → "Schwammerl").
    public var caseCorrectionMinZipf: Double = 3

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

    struct Candidate {
        /// Display text (the typed casing applied to `form`).
        var text: String
        /// Dictionary form ("Haus", "don't").
        var form: String
        var score: Double
        var cost: Double
        var language: KeyboardLanguage?
        var kind: SuggestionKind
        /// Found through a German / English spelling rule ("weiss" → "weiß", "center" → "centre").
        var viaSpellingRule = false
        /// Some dictionary form behind `text` is capitalised (a noun or name, not just typed that way).
        var hasCapitalisedForm = false
    }

    /// Language prior in bits: +1 for the layout language plus the detector's log share, shifted so the
    /// most likely language gets +1 — exactly what a single enabled language gets. Enabling more
    /// languages then only makes the *other* languages need more evidence, instead of raising the bar
    /// for every correction (with four languages and no history every prior used to be 2 bits lower).
    private func prior(_ language: KeyboardLanguage, _ languages: [KeyboardLanguage]) -> Double {
        guard languages.count > 1 else { return 1 }
        func raw(_ l: KeyboardLanguage) -> Double {
            (l == languages.first ? 1.0 : 0.0) + detector.logShare(of: l, among: languages)
        }
        let best = languages.map(raw).max() ?? 0
        return raw(language) - best + 1
    }

    /// Successors of `previous` in one lexicon (bigrams are keyed by the first, most frequent form of a key).
    private func successors(_ lex: WordLexicon, previous: String, limit: Int) -> [(id: Int, log2Prob: Double)] {
        guard let id = lex.lookup(key: TextUnits.lookupKey(previous)).first else { return [] }
        return lex.successors(of: id, limit: limit)
    }

    /// log2 P(next | prev) table for one lexicon.
    private func successorTable(_ lex: WordLexicon, previous: String?) -> [Int: Double] {
        guard let previous = previous else { return [:] }
        var table: [Int: Double] = [:]
        for s in successors(lex, previous: previous, limit: 256) { table[s.id] = s.log2Prob }
        return table
    }

    /// The word before the current one, unless it ended the previous sentence (no bigram across ". ").
    private func previousWord(_ query: SuggestionQuery) -> String? {
        query.isSentenceStart ? nil : query.previousWords.last
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

    struct SpellingVariant {
        var key: String
        var cost: Double
        /// A German or English spelling rule (not a doubled letter).
        var isLanguageRule: Bool
    }

    /// Cheap rule-based respellings of the typed key that the edit-distance search prices too high, with
    /// their cost in bits:
    /// * any language: a doubled or undoubled letter ("komen" → "kommen", "habben" → "haben");
    /// * German: "ss" → "ß" ("Strasse") and "ae/oe/ue" → "ä/ö/ü" ("schoen"), `ruleCost` each;
    /// * English: the other variety's spelling ("color" → "colour" in en-GB, "colour" → "color" in
    ///   en-US; -or/-our, final -er/-re, -ize/-ise, -yze/-yse, final -og/-ogue, final -ense/-ence).
    static func spellingVariants(of key: String, language: KeyboardLanguage?, doubledLetterCost: Double, ruleCost: Double) -> [SpellingVariant] {
        let chars = Array(key)
        let n = chars.count
        guard n >= 2, n <= 30 else { return [] }
        var result: [SpellingVariant] = []
        var seen: Set<String> = [key]
        func add(_ variant: [Character], _ cost: Double, rule: Bool = false) {
            let s = String(variant)
            if seen.insert(s).inserted { result.append(SpellingVariant(key: s, cost: cost, isLanguageRule: rule)) }
        }
        for i in 0..<n where chars[i].isLetter {
            // A doubled final vowel is usually deliberate ("jaa", "nee"): no cheap undoubling.
            if i + 1 < n, chars[i + 1] == chars[i], !(i + 2 == n && "aeiouyäöüë".contains(chars[i])) {
                var v = chars
                v.remove(at: i)
                add(v, doubledLetterCost)
            }
            if (i == 0 || chars[i - 1] != chars[i]) && (i + 1 == n || chars[i + 1] != chars[i]) {
                var v = chars
                v.insert(chars[i], at: i)
                add(v, doubledLetterCost)
            }
        }
        /// Replaces `from` by `to` at every occurrence (each alone, and all together when there are several).
        func replacing(_ from: String, _ to: String, onlyAtEnd: Bool = false, unlessPrecededBy: Character? = nil) {
            let f = Array(from), t = Array(to)
            var matches: [Int] = []
            var i = 0
            while i + f.count <= n {
                if Array(chars[i..<(i + f.count)]) == f, !onlyAtEnd || i + f.count == n,
                   unlessPrecededBy == nil || i == 0 || chars[i - 1] != unlessPrecededBy {
                    matches.append(i)
                    i += f.count
                } else {
                    i += 1
                }
            }
            for m in matches {
                var v = chars
                v.replaceSubrange(m..<(m + f.count), with: t)
                add(v, ruleCost, rule: true)
            }
            if matches.count > 1 {
                var v = chars
                for m in matches.reversed() { v.replaceSubrange(m..<(m + f.count), with: t) }
                add(v, ruleCost * Double(matches.count), rule: true)
            }
        }
        switch language {
        case .deAT?:
            replacing("ss", "ß")
            replacing("ae", "ä")
            replacing("oe", "ö")
            replacing("ue", "ü", unlessPrecededBy: "q")
        case .enGB?:
            replacing("or", "our")
            replacing("er", "re", onlyAtEnd: true)
            replacing("ize", "ise")
            replacing("yze", "yse")
            replacing("og", "ogue", onlyAtEnd: true)
            replacing("ense", "ence", onlyAtEnd: true)
        case .enUS?:
            replacing("our", "or")
            replacing("re", "er", onlyAtEnd: true)
            replacing("ise", "ize")
            replacing("yse", "yze")
            replacing("ogue", "og", onlyAtEnd: true)
            replacing("ence", "ense", onlyAtEnd: true)
        default:
            break
        }
        return result
    }

    /// All correction / completion candidates for the current word, best first.
    func rankedCandidates(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> [Candidate] {
        let typed = query.currentWord
        let typedKey = TextUnits.lookupKey(typed)
        let chars = Array(typedKey)
        guard !chars.isEmpty, chars.count <= 30 else { return [] }
        let previous = previousWord(query)
        let typedHasUppercase = Casing.hasUppercase(typed)

        let taps: [TapInput]
        if let given = query.taps, given.count == chars.count {
            taps = given
        } else {
            taps = chars.map { TapInput.exact(String($0)) }
        }
        let maxCost = min(20, 6 + 2.5 * Double(chars.count))

        var variantsByLanguage: [KeyboardLanguage: [SpellingVariant]] = [:]
        func variants(_ language: KeyboardLanguage) -> [SpellingVariant] {
            // Only German and English have language rules; the generic variants are shared.
            let ruleLanguage: KeyboardLanguage = [.deAT, .enGB, .enUS].contains(language) ? language : .itIT
            if let cached = variantsByLanguage[ruleLanguage] { return cached }
            let list = Self.spellingVariants(of: typedKey, language: ruleLanguage == .itIT ? nil : ruleLanguage,
                                             doubledLetterCost: doubledLetterCost, ruleCost: spellingRuleCost)
            variantsByLanguage[ruleLanguage] = list
            return list
        }

        var candidates: [String: Candidate] = [:]
        func offer(_ c: Candidate) {
            guard !blocked.contains(TextUnits.lookupKey(c.form)) else { return }
            var c = c
            c.text = Casing.apply(typed: typed, to: c.form)
            c.hasCapitalisedForm = Casing.startsUppercase(c.form)
            if var existing = candidates[c.text] {
                // Several forms can show as the same text ("grüße" / "Grüße" typed "Grüsse").
                existing.hasCapitalisedForm = existing.hasCapitalisedForm || c.hasCapitalisedForm
                c.hasCapitalisedForm = existing.hasCapitalisedForm
                if existing.score >= c.score {
                    candidates[c.text] = existing
                    return
                }
            }
            candidates[c.text] = c
        }

        for language in languages {
            guard let lex = lexicon(for: language) else { continue }
            let p = prior(language, languages)
            let succ = successorTable(lex, previous: previous)
            /// Typed in lower case: a capitalised form loses a tie against the lower-case form of the same
            /// key (both have the corpus frequency of the key): "arbeizen" → "arbeiten", not "Arbeiten".
            var hasLowercaseForm: [String: Bool] = [:]
            func casingPenalty(_ word: String) -> Double {
                guard !typedHasUppercase, Casing.startsUppercase(word) else { return 0 }
                let key = TextUnits.lookupKey(word)
                if hasLowercaseForm[key] == nil {
                    hasLowercaseForm[key] = lex.lookup(key: key).contains { !Casing.hasUppercase(lex.word($0)) }
                }
                return hasLowercaseForm[key]! ? casingTieBreak : 0
            }
            func lm(_ id: Int, _ word: String) -> Double {
                languageModel(unigram: lex.log2Prob(id), bigram: userBigramLog2(previous, word) ?? succ[id])
            }
            for m in lex.fuzzySearch(taps: taps, costs: costModel, maxCost: maxCost, limit: 30) {
                let w = lex.word(m.id)
                offer(Candidate(text: w, form: w, score: lm(m.id, w) - m.cost - casingPenalty(w) + p, cost: m.cost, language: language, kind: .correction))
            }
            for variant in variants(language) {
                for id in lex.lookup(key: variant.key) {
                    let w = lex.word(id)
                    offer(Candidate(text: w, form: w, score: lm(id, w) - variant.cost - casingPenalty(w) + p, cost: variant.cost, language: language,
                                    kind: .correction, viaSpellingRule: variant.isLanguageRule))
                }
            }
            if chars.count >= 2 {
                for id in lex.completions(prefix: typedKey, limit: 8) {
                    let w = lex.word(id)
                    let missing = Double(TextUnits.lookupKey(w).count - chars.count)
                    guard missing > 0 else { continue }
                    let cost = min(completionCostCap, completionCostPerLetter * missing)
                    offer(Candidate(text: w, form: w, score: lm(id, w) - cost - casingPenalty(w) + p - 1, cost: cost, language: language, kind: .completion))
                }
            }
        }
        if let user = userLexicon {
            for m in user.fuzzySearch(taps: taps, costs: costModel, maxCost: maxCost, limit: 15) {
                let w = user.word(m.id)
                let lm = languageModel(unigram: user.log2Prob(m.id), bigram: userBigramLog2(previous, w))
                offer(Candidate(text: w, form: w, score: lm - m.cost + 1, cost: m.cost, language: nil, kind: .correction))
            }
            if chars.count >= 2 {
                for id in user.completions(prefix: typedKey, limit: 5) {
                    let w = user.word(id)
                    let missing = Double(TextUnits.lookupKey(w).count - chars.count)
                    guard missing > 0 else { continue }
                    let cost = min(completionCostCap, completionCostPerLetter * missing)
                    let lm = languageModel(unigram: user.log2Prob(id), bigram: userBigramLog2(previous, w))
                    offer(Candidate(text: w, form: w, score: lm - cost, cost: cost, language: nil, kind: .completion))
                }
            }
        }
        // Deterministic order: score, then edit cost, then text.
        return candidates.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.cost != $1.cost { return $0.cost < $1.cost }
            return $0.text < $1.text
        }
    }

    private func corrections(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> SuggestionResult {
        let typed = query.currentWord
        let typedKey = TextUnits.lookupKey(typed)
        guard !typedKey.isEmpty else { return .empty }
        let ranked = rankedCandidates(query, languages: languages)
        let typedIsKnown = isKnownWord(typed, languages: languages)

        var autocorrection: Suggestion?
        if query.autocorrectEnabled, query.field.autocorrectAllowed {
            autocorrection = decideAutocorrection(query, typedKey: typedKey, typedIsKnown: typedIsKnown, ranked: ranked, languages: languages)
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

    private func decideAutocorrection(_ query: SuggestionQuery, typedKey: String, typedIsKnown: Bool, ranked: [Candidate], languages: [KeyboardLanguage]) -> Suggestion? {
        let typed = query.currentWord
        if let phrase = shortcuts[typedKey] {
            return Suggestion(text: phrase, kind: .shortcut, isAutocorrect: true)
        }
        guard !typed.contains(where: { $0.isNumber }), !Casing.hasInnerCapitals(typed) else { return nil }
        let n = typedKey.count
        let best = ranked.first { $0.kind == .correction && TextUnits.lookupKey($0.text) != typedKey }
        if typedIsKnown {
            return caseCorrection(typed: typed, key: typedKey, languages: languages, best: best)
        }
        guard n >= 2, let correction = best else { return nil }
        // The typed letters start a much more likely word: the user is still typing it.
        if let completion = ranked.first(where: { $0.kind == .completion }), completion.score - prefixStopPenalty > correction.score { return nil }
        guard correction.cost <= 4 + 2 * Double(n) else { return nil }
        guard correction.score - unknownWordLog2Prob >= requiredMargin(query, typedLength: n, correction: correction) else { return nil }
        guard query.accentRestoration || Diacritics.fold(correction.text) != Diacritics.fold(typed) else { return nil }
        return Suggestion(text: correction.text, kind: .correction, isAutocorrect: true, language: correction.language)
    }

    /// Bits a correction must beat the unknown-word baseline by. Short unknown strings are often slang
    /// or abbreviations ("thx", "hdl") that are one edit away from some frequent word, and a capitalised
    /// word in mid-sentence whose correction is a lower-case word is usually a name ("Senad" ≠ "send").
    private func requiredMargin(_ query: SuggestionQuery, typedLength n: Int, correction: Candidate) -> Double {
        var margin = autocorrectMargin + (n < shortWordMargins.count ? shortWordMargins[n] : 0)
        let typed = query.currentWord
        if !query.isSentenceStart, Casing.startsUppercase(typed), !Casing.isAllCaps(typed), !correction.hasCapitalisedForm {
            margin += properNounMargin
        }
        return margin
    }

    /// "haus" → "Haus" when the capitalised dictionary forms of the key (German nouns, English "I") are
    /// far more likely than the forms typed as is, weighted by language prior.
    private func caseCorrection(typed: String, key: String, languages: [KeyboardLanguage], best: Candidate?) -> Suggestion? {
        guard !Casing.hasUppercase(typed) else { return nil }
        if supplementaryKnown.contains(key) { return nil }
        var keepMass = 0.0
        var capitalised: [(form: String, score: Double, zipf: Double, language: KeyboardLanguage?)] = []
        func add(_ form: String, _ score: Double, _ zipf: Double, _ language: KeyboardLanguage?) {
            if Casing.startsUppercase(form), !Casing.isAllCaps(form) {
                capitalised.append((form, score, zipf, language))
            } else {
                // The typed form itself, or an acronym ("LOL") that may well be typed in lower case.
                keepMass += pow(2, score)
            }
        }
        if let user = userLexicon {
            for id in user.lookup(key: key) {
                let w = user.word(id)
                if w == typed { return nil }
                add(w, user.log2Prob(id) + 1, user.zipf(id), nil)
            }
        }
        for language in languages {
            guard let lex = lexicon(for: language) else { continue }
            let p = prior(language, languages)
            for id in lex.lookup(key: key) {
                let w = lex.word(id)
                // A lower-case form in the layout language is decisive ("ned", "jo" are Austrian words).
                if language == languages.first, !Casing.hasUppercase(w) { return nil }
                add(w, lex.log2Prob(id) + p, lex.zipf(id), language)
            }
        }
        guard let top = capitalised.max(by: { $0.score < $1.score }), top.form != typed else { return nil }
        let minZipf = key.count <= 3 ? shortCaseCorrectionMinZipf : (key.count <= 5 ? caseCorrectionMinZipf : 0)
        guard top.zipf >= minZipf else { return nil }
        if keepMass > 0 {
            let capitalisedMass = capitalised.reduce(0) { $0 + pow(2, $1.score) }
            guard log2(capitalisedMass) - log2(keepMass) >= caseCorrectionMargin else { return nil }
        }
        // Known only as a capitalised name, but a spelling rule away from a lower-case word, or one cheap
        // edit away from a far more likely word: "weiss" → "weiß", not the surname "Weiss"; "center" →
        // "centre" in British English, not the proper noun "Center".
        if keepMass == 0, let best = best, best.cost <= cheapCorrectionCost,
           best.viaSpellingRule && !best.hasCapitalisedForm || best.score - (top.score + log2(0.4)) >= autocorrectMargin {
            return Suggestion(text: best.text, kind: .correction, isAutocorrect: true, language: best.language)
        }
        return Suggestion(text: top.form, kind: .correction, isAutocorrect: true, language: top.language)
    }

    private func predictions(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> [Suggestion] {
        let previous = previousWord(query)
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
                guard let lex = lexicon(for: language) else { continue }
                let p = prior(language, languages)
                for s in successors(lex, previous: previous, limit: 6) {
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
        // Bigram scores are quantised (1/32 bit), so ties are common: break them by text for a stable bar.
        return scored.sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.key < $1.key }.prefix(3).map {
            Suggestion(text: $0.key, kind: .prediction, language: $0.value.1)
        }
    }
}
