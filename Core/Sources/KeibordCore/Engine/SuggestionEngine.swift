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
    /// The word of the last correction query: what the user typed before the word was committed.
    private var lastTypedWord = ""
    /// Accented words committed per dictionary: typed with their accents / typed without them.
    private var accentHabit: [String: (typed: Double, omitted: Double)] = [:]

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
    /// A valid typed word becomes an accented word when that is this many bits more likely once the
    /// omitted accents are paid for (`accentOmissionCost`): "mire" (an English word) → "mirë", "uber" →
    /// "über", and "ne" → "në" once the user is known to leave out "ë".
    public var knownWordAccentMargin: Double = 2
    /// A word that is only known in some enabled languages is corrected into another enabled language
    /// when that correction is this many bits more likely ("teh" is a rare Albanian word: "the").
    public var crossLanguageMargin: Double = 8
    /// Maximum edit cost of such a cross-language correction (one slip, transposition or missing letter).
    public var crossLanguageMaxCost: Double = 8
    /// Bits taken from the lower-case twin of a German noun ("quatsch" / "Quatsch", "ende" / "Ende") when
    /// the noun is the dominant form, so that typing it in lower case is corrected.
    public var nounTwinDiscount: Double = 5
    /// Minimum zipf of such a dominant noun: below it ties are mostly curated interjections ("Baba"/"baba").
    public var nounTwinMinZipf: Double = 4
    /// Extra margin for replacing a word of the layout language by a word of another language ("ate" stays
    /// English on the English keyboard instead of becoming the Albanian "atë").
    public var layoutLanguageMargin: Double = 4
    /// Extra margin for restoring a valid word into the accented word of a language the user is not
    /// currently writing in ("ate" → "atë" needs Albanian context; "une" → "unë" is clear without).
    public var foreignAccentMargin: Double = 4
    /// A word belongs to the languages that know it at most this much (zipf) below its best frequency.
    public var nativeZipfGap: Double = 1.5

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
        if supplementaryKnown.contains(key) || Self.isBuiltInWord(key, languages: languages) { return true }
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
            // Frequency in bits plus the language prior (layout language, recent words).
            let z = lex.log2Prob(id) + prior(language, languages)
            if best == nil || z > best!.1 { best = (language, z) }
        }
        return best?.0 ?? detector.mostLikely(among: languages)
    }

    public func noteCommitted(word: String, language: KeyboardLanguage?) {
        let typed = lastTypedWord
        lastTypedWord = ""
        noteAccentHabit(typed: typed, final: word, language: language)
        let languages = lastLanguages
        guard languages.count > 1 else { return }
        detector.observe(knownIn: nativeLanguages(of: word, among: languages), among: languages)
    }

    /// The languages `word` most likely belongs to: those knowing it at most `nativeZipfGap` below its best
    /// frequency. "per" is Italian (English and German know it too, but rarely use it); "ok" is everybody's.
    func nativeLanguages(of word: String, among languages: [KeyboardLanguage]) -> [KeyboardLanguage] {
        let key = TextUnits.lookupKey(word)
        var known: [(language: KeyboardLanguage, zipf: Double)] = []
        for language in languages {
            guard let lex = lexicon(for: language), let z = lex.lookup(key: key).map({ lex.zipf($0) }).max() else { continue }
            known.append((language, z))
        }
        guard let best = known.map(\.zipf).max() else { return [] }
        return known.filter { $0.zipf >= best - nativeZipfGap }.map(\.language)
    }

    /// Learns whether the user types accents: an accented word committed after typing it without its
    /// accents ("eshte" → "është", also when picked from the bar) counts as omitted, typed as is counts as typed.
    private func noteAccentHabit(typed: String, final: String, language: KeyboardLanguage?) {
        let finalKey = TextUnits.lookupKey(final)
        let typedKey = TextUnits.lookupKey(typed)
        let folded = Diacritics.fold(finalKey)
        guard !typedKey.isEmpty, folded != finalKey, Diacritics.fold(typedKey) == folded,
              let language = language ?? lastLanguages.first else { return }
        var habit = accentHabit[language.dictionaryID] ?? (0, 0)
        if typedKey == finalKey {
            habit.typed += 1
        } else if Diacritics.fold(typedKey) == typedKey {
            habit.omitted += 1
        } else {
            return
        }
        // Recent behaviour matters most: keep the counts small.
        if habit.typed + habit.omitted > 40 {
            habit.typed *= 0.5
            habit.omitted *= 0.5
        }
        accentHabit[language.dictionaryID] = habit
    }

    /// Bits for each accent left out of an accented word of `language`: −log2 of the share of accented words
    /// the user types without their accents (learned, starting from `accentOmissionPrior`).
    func accentOmissionCost(_ language: KeyboardLanguage) -> Double {
        let prior = Self.accentOmissionPrior[language.dictionaryID] ?? (typed: 3, omitted: 1)
        let habit = accentHabit[language.dictionaryID] ?? (0, 0)
        let omitted = prior.omitted + habit.omitted
        return -log2(omitted / (omitted + prior.typed + habit.typed))
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
        lastTypedWord = word
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

    /// log2 P(next | prev) table for one lexicon, by lookup key: bigrams are stored for the most frequent
    /// form of a key only, but apply to every casing of it ("keine zeit" also supports "Zeit").
    private func successorTable(_ lex: WordLexicon, previous: String?) -> [String: Double] {
        guard let previous = previous else { return [:] }
        var table: [String: Double] = [:]
        for s in successors(lex, previous: previous, limit: 256) {
            let key = TextUnits.lookupKey(lex.word(s.id))
            if table[key] == nil { table[key] = s.log2Prob }
        }
        return table
    }

    /// The word before the current one, unless it ended the previous sentence (no bigram across ". ").
    private func previousWord(_ query: SuggestionQuery) -> String? {
        query.isSentenceStart ? nil : query.previousWords.last
    }

    /// Language-model context of one query: the previous word and its successor tables per language.
    struct Context {
        var previous: String?
        var successors: [KeyboardLanguage: [String: Double]] = [:]
    }

    func makeContext(_ query: SuggestionQuery, languages: [KeyboardLanguage]) -> Context {
        var context = Context(previous: previousWord(query))
        guard context.previous != nil else { return context }
        for language in languages {
            guard let lex = lexicon(for: language) else { continue }
            context.successors[language] = successorTable(lex, previous: context.previous)
        }
        return context
    }

    /// Language-model score (bits) of word `id` of `lex` after the context's previous word.
    private func languageScore(_ lex: WordLexicon, _ language: KeyboardLanguage, _ id: Int, _ context: Context) -> Double {
        let word = lex.word(id)
        let bigram = userBigramLog2(context.previous, word) ?? context.successors[language]?[TextUnits.lookupKey(word)]
        return languageModel(unigram: lex.log2Prob(id), bigram: bigram)
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
    func rankedCandidates(_ query: SuggestionQuery, languages: [KeyboardLanguage], context: Context? = nil) -> [Candidate] {
        let typed = query.currentWord
        let typedKey = TextUnits.lookupKey(typed)
        let chars = Array(typedKey)
        guard !chars.isEmpty, chars.count <= 30 else { return [] }
        let context = context ?? makeContext(query, languages: languages)
        let previous = context.previous
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
                languageScore(lex, language, id, context)
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
        let context = makeContext(query, languages: languages)
        let ranked = rankedCandidates(query, languages: languages, context: context)
        let typedIsKnown = isKnownWord(typed, languages: languages)

        var autocorrection: Suggestion?
        if query.autocorrectEnabled, query.field.autocorrectAllowed {
            autocorrection = decideAutocorrection(query, typedKey: typedKey, typedIsKnown: typedIsKnown, ranked: ranked,
                                                  languages: languages, context: context)
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

    private func decideAutocorrection(_ query: SuggestionQuery, typedKey: String, typedIsKnown: Bool, ranked: [Candidate],
                                      languages: [KeyboardLanguage], context: Context) -> Suggestion? {
        let typed = query.currentWord
        if let phrase = shortcuts[typedKey] {
            return Suggestion(text: phrase, kind: .shortcut, isAutocorrect: true)
        }
        guard !typed.contains(where: { $0.isNumber }), !Casing.hasInnerCapitals(typed) else { return nil }
        if typedIsKnown {
            return knownWordCorrection(query, typedKey: typedKey, ranked: ranked, languages: languages, context: context)
        }
        let n = typedKey.count
        guard n >= 2, let correction = ranked.first(where: { $0.kind == .correction && TextUnits.lookupKey($0.text) != typedKey }) else { return nil }
        // The typed letters start a much more likely word: the user is still typing it.
        if let completion = ranked.first(where: { $0.kind == .completion }), completion.score - prefixStopPenalty > correction.score { return nil }
        guard correction.cost <= 4 + 2 * Double(n) else { return nil }
        guard correction.score - unknownWordLog2Prob >= requiredMargin(query, typedKey: typedKey, correction: correction) else { return nil }
        guard query.accentRestoration || Diacritics.fold(correction.text) != Diacritics.fold(typed) else { return nil }
        return Suggestion(text: correction.text, kind: .correction, isAutocorrect: true, language: correction.language)
    }

    /// Bits a correction must beat the unknown-word baseline by. Short unknown strings are often slang
    /// or abbreviations ("thx", "hdl") that are one edit away from some frequent word, and a capitalised
    /// word in mid-sentence whose correction is a lower-case word is usually a name ("Senad" ≠ "send").
    /// Restoring accents or applying a spelling rule ("gruss" → "Gruß", "cka" → "çka") is no such guess.
    private func requiredMargin(_ query: SuggestionQuery, typedKey: String, correction: Candidate) -> Double {
        let n = typedKey.count
        var margin = autocorrectMargin
        let respelling = correction.viaSpellingRule || Diacritics.fold(TextUnits.lookupKey(correction.form)) == Diacritics.fold(typedKey)
        if n < shortWordMargins.count, !respelling { margin += shortWordMargins[n] }
        let typed = query.currentWord
        if !query.isSentenceStart, Casing.startsUppercase(typed), !Casing.isAllCaps(typed), !correction.hasCapitalisedForm {
            margin += properNounMargin
        }
        return margin
    }

    // MARK: Known words

    /// A typed word that some dictionary knows is only replaced by
    /// * its capitalised form when that is far more likely than the forms shown as typed ("haus" → "Haus",
    ///   "wien" → "Wien", "i" → "I", "quatsch" → "Quatsch"),
    /// * an accented word that is much more likely in context than every reading of the typed word, once
    ///   the omitted accents are paid for ("mire" is a rare English word, "mirë" a frequent Albanian one;
    ///   "uber" → "über"; "c'e" → "c'è"),
    /// * a correction into another enabled language that is far more likely than the rare word typed
    ///   ("teh" is an Albanian word, but with English enabled it is "the").
    /// The option with the highest score wins ("jane" → "janë" rather than the name "Jane").
    private func knownWordCorrection(_ query: SuggestionQuery, typedKey: String, ranked: [Candidate], languages: [KeyboardLanguage],
                                     context: Context) -> Suggestion? {
        let typed = query.currentWord
        // Contact names, text replacements and chat abbreviations are the user's own words.
        if supplementaryKnown.contains(typedKey) || Self.isBuiltInWord(typedKey, languages: languages) { return nil }
        if let elided = elisionCorrection(query, typedKey: typedKey, languages: languages, context: context) { return elided }

        let typedLower = !Casing.hasUppercase(typed)
        var keepMass = 0.0
        var layoutKeepMass = 0.0
        var decisiveLowercase = false
        var knownIn: Set<String> = []
        var capitalised: [(form: String, score: Double, zipf: Double, language: KeyboardLanguage?)] = []
        var userForms = 0
        if let user = userLexicon {
            for id in user.lookup(key: typedKey) {
                let w = user.word(id)
                if w == typed { return nil }
                userForms += 1
                let score = languageModel(unigram: user.log2Prob(id), bigram: userBigramLog2(context.previous, w)) + 1
                if typedLower, Casing.startsUppercase(w), !Casing.isAllCaps(w) {
                    capitalised.append((w, score, user.zipf(id), nil))
                } else {
                    keepMass += pow(2, score)
                }
            }
        }
        let verbContext = context.previous.map { Self.germanPronouns.contains(TextUnits.lookupKey($0)) } ?? false
        for language in languages {
            guard let lex = lexicon(for: language) else { continue }
            let ids = lex.lookup(key: typedKey)
            guard !ids.isEmpty else { continue }
            knownIn.insert(language.dictionaryID)
            let p = prior(language, languages)
            let nounTwin = typedLower && !verbContext && isDominantNoun(lex, language: language, ids: ids, key: typedKey)
            for id in ids {
                let w = lex.word(id)
                let score = languageScore(lex, language, id, context) + p
                if Casing.apply(typed: typed, to: w) == typed || (typedLower && Casing.isAllCaps(w)) {
                    // Shown as typed, or an acronym ("LOL") that may well be typed in lower case.
                    let lowercase = !Casing.hasUppercase(w)
                    // A lower-case form in the layout language is decisive ("ned", "jo" are Austrian words).
                    if lowercase, language == languages.first, !nounTwin { decisiveLowercase = true }
                    let mass = pow(2, lowercase && nounTwin ? score - nounTwinDiscount : score)
                    keepMass += mass
                    if language == languages.first { layoutKeepMass += mass }
                } else if typedLower, Casing.startsUppercase(w) {
                    capitalised.append((w, score, lex.zipf(id), language))
                }
            }
        }
        let keepScore = keepMass > 0 ? log2(keepMass) : -Double.infinity

        var options: [(suggestion: Suggestion, score: Double)] = []
        if !decisiveLowercase, let option = caseOption(typedKey: typedKey, keepScore: keepScore, capitalised: capitalised, ranked: ranked) {
            options.append(option)
        }
        // Words the user taught the keyboard are deliberate: only their casing is corrected.
        if userForms == 0 {
            // The layout language's reading of the word is the main one ("ate" on the English keyboard, not
            // "per" on the German one).
            let layout = layoutKeepMass >= keepMass / 2 && keepMass > 0 ? languages.first : nil
            // A capitalised word in mid-sentence is probably a name ("Dardan" ≠ "Daran").
            let name = !query.isSentenceStart && Casing.startsUppercase(typed) && !Casing.isAllCaps(typed)
            let keep = keepScore + (name ? properNounMargin : 0)
            if query.accentRestoration,
               let option = knownWordAccentOption(typedKey: typedKey, keepScore: keep, ranked: ranked, knownIn: knownIn,
                                                  languages: languages, layoutLanguage: layout) {
                options.append(option)
            }
            if keepMass > 0,
               let option = crossLanguageOption(typedKey: typedKey, keepScore: keep, knownIn: knownIn, ranked: ranked, layoutLanguage: layout) {
                options.append(option)
            }
        }
        return options.max(by: { $0.score < $1.score })?.suggestion
    }

    /// "haus" → "Haus" when the capitalised forms of the key (German nouns, English "I", names) are far more
    /// likely than the forms shown as typed.
    private func caseOption(typedKey: String, keepScore: Double, capitalised: [(form: String, score: Double, zipf: Double, language: KeyboardLanguage?)],
                            ranked: [Candidate]) -> (suggestion: Suggestion, score: Double)? {
        guard let top = capitalised.max(by: { $0.score < $1.score }) else { return nil }
        let n = typedKey.count
        let minZipf = n <= 3 ? shortCaseCorrectionMinZipf : (n <= 5 ? caseCorrectionMinZipf : 0)
        guard top.zipf >= minZipf else { return nil }
        let capitalisedScore = log2(capitalised.reduce(0) { $0 + pow(2, $1.score) })
        guard capitalisedScore - keepScore >= caseCorrectionMargin else { return nil }
        // Known only as a capitalised name, but a spelling rule away from a lower-case word, or one cheap
        // edit away from a far more likely word: "weiss" → "weiß", not the surname "Weiss"; "center" →
        // "centre" in British English, not the proper noun "Center".
        if keepScore == -Double.infinity,
           let best = ranked.first(where: { $0.kind == .correction && TextUnits.lookupKey($0.text) != typedKey }),
           best.cost <= cheapCorrectionCost,
           best.viaSpellingRule && !best.hasCapitalisedForm || best.score - top.score >= autocorrectMargin {
            return (Suggestion(text: best.text, kind: .correction, isAutocorrect: true, language: best.language), best.score)
        }
        return (Suggestion(text: top.form, kind: .correction, isAutocorrect: true, language: top.language), top.score)
    }

    /// A German key whose capitalised form is the noun people mean although a lower-case twin exists: the
    /// noun is listed first (the dictionary breaks frequency ties by the casing books use: "Quatsch",
    /// "Ende", "Schule") or it is one of `germanNouns`.
    private func isDominantNoun(_ lex: WordLexicon, language: KeyboardLanguage, ids: [Int], key: String) -> Bool {
        guard language == .deAT, let first = ids.first else { return false }
        let firstForm = lex.word(first)
        if Self.germanNouns.contains(key) { return true }
        guard Casing.startsUppercase(firstForm), !Casing.isAllCaps(firstForm), lex.zipf(first) >= nounTwinMinZipf else { return false }
        return ids.contains { !Casing.hasUppercase(lex.word($0)) && lex.zipf($0) >= lex.zipf(first) }
    }

    /// The accented reading of a valid typed word ("mire" → "mirë"), if it is `knownWordAccentMargin` bits
    /// more likely than the typed readings after paying `accentOmissionCost` per missing accent (plus
    /// `layoutLanguageMargin` to leave `layoutLanguage`, which knows the typed word, and `foreignAccentMargin`
    /// for a language that does not know the typed word and is not the one the user is writing in).
    private func knownWordAccentOption(typedKey: String, keepScore: Double, ranked: [Candidate], knownIn: Set<String>,
                                       languages: [KeyboardLanguage], layoutLanguage: KeyboardLanguage?) -> (suggestion: Suggestion, score: Double)? {
        // Someone typing some accents ("ketë", "nö") typed this word the way they meant it.
        let folded = Diacritics.fold(typedKey)
        guard folded == typedKey else { return nil }
        var best: (candidate: Candidate, score: Double)?
        for c in ranked where c.kind == .correction {
            guard let language = c.language else { continue }
            let key = TextUnits.lookupKey(c.form)
            guard key != typedKey, key.count == typedKey.count, Diacritics.fold(key) == folded else { continue }
            let accents = zip(key, typedKey).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
            var score = c.score + c.cost - Double(accents) * accentOmissionCost(language)
            if let layout = layoutLanguage, language.dictionaryID != layout.dictionaryID { score -= layoutLanguageMargin }
            if !knownIn.contains(language.dictionaryID), prior(language, languages) < 1 { score -= foreignAccentMargin }
            if best == nil || score > best!.score { best = (c, score) }
        }
        guard let found = best, found.score - keepScore >= knownWordAccentMargin else { return nil }
        return (Suggestion(text: found.candidate.text, kind: .correction, isAutocorrect: true, language: found.candidate.language), found.score)
    }

    /// The best correction, if it belongs to a language that does not know the typed word and beats every
    /// reading of the typed word by `crossLanguageMargin` ("teh" → "the").
    private func crossLanguageOption(typedKey: String, keepScore: Double, knownIn: Set<String>, ranked: [Candidate],
                                     layoutLanguage: KeyboardLanguage?) -> (suggestion: Suggestion, score: Double)? {
        guard let c = ranked.first(where: { $0.kind == .correction && TextUnits.lookupKey($0.form) != typedKey }),
              let language = c.language, !knownIn.contains(language.dictionaryID),
              c.cost <= crossLanguageMaxCost,
              Diacritics.fold(TextUnits.lookupKey(c.form)) != Diacritics.fold(typedKey),
              c.score - keepScore >= crossLanguageMargin + (layoutLanguage == nil ? 0 : layoutLanguageMargin) else { return nil }
        return (Suggestion(text: c.text, kind: .correction, isAutocorrect: true, language: language), c.score)
    }

    /// Italian: after an elided word ("c'", "dov'", "com'", "cos'") a bare "e" can only be the verb, so
    /// "c'e" → "c'è" (the input controller hands the engine the word after the apostrophe).
    private func elisionCorrection(_ query: SuggestionQuery, typedKey: String, languages: [KeyboardLanguage], context: Context) -> Suggestion? {
        guard query.accentRestoration, typedKey == "e", let previous = context.previous, let last = previous.last,
              TextUnits.apostrophes.contains(last), languages.contains(.itIT), let lex = lexicon(for: .itIT),
              !lex.lookup(key: TextUnits.lookupKey(previous)).isEmpty else { return nil }
        return Suggestion(text: Casing.apply(typed: query.currentWord, to: "è"), kind: .correction, isAutocorrect: true, language: .itIT)
    }

    // MARK: Word lists

    /// Chat abbreviations missing from the dictionaries, by dictionary: known words that are never corrected.
    static let builtInWords: [String: Set<String>] = {
        let chat: Set<String> = ["lol", "omg", "btw", "xd", "ok", "thx", "pls", "plz"]
        let english: Set<String> = ["etc", "idk", "tbh", "imo", "imho", "brb", "asap", "fyi", "lmk", "lmao", "rofl", "ngl", "smh", "tmrw",
                                    "irl", "ty", "np", "bday", "gf", "bf", "dm", "ttyl", "hbu", "wyd", "nvm"]
        return [
            "de-AT": chat.union(["usw", "bzw", "zb", "evtl", "ggf", "inkl", "exkl", "vgl", "bspw", "sog", "ca", "mfg", "lg", "glg", "hdl",
                                 "hdgdl", "vllt", "vlt", "sry", "ka", "kA", "wg", "bzgl", "zzgl", "usf"].map { $0.lowercased() }),
            "en-GB": chat.union(english),
            "en-US": chat.union(english),
            "sq": chat.union(["flm", "dmth", "psh", "nqs", "rrfsh"]),
            "it": chat.union(["cmq", "nn", "xke", "xké", "xche", "xché", "tvb", "tvtb", "qlc", "qlcs", "grz", "cvd", "tt"]),
        ]
    }()

    static func isBuiltInWord(_ key: String, languages: [KeyboardLanguage]) -> Bool {
        languages.contains { builtInWords[$0.dictionaryID]?.contains(key) ?? false }
    }

    /// German nouns whose lower-case twin comes first in the dictionary (very frequent keys lose a little
    /// frequency on their capitalised form) although people typing the key almost always mean the noun.
    static let germanNouns: Set<String> = ["zeit", "angst", "freund", "dank"]

    /// After a subject pronoun a German lower-case twin is the verb: "ich sorge", "wir essen".
    static let germanPronouns: Set<String> = ["ich", "i", "du", "er", "sie", "es", "wir", "ihr", "man"]

    /// Prior pseudo-counts of accented words typed with / without their accents, by dictionary: German
    /// layouts have umlaut keys (10 % left out); Albanian "ë" / "ç" and Italian accents are often skipped
    /// (33 %). The counts are small so that a user's habit takes over after a few words.
    static let accentOmissionPrior: [String: (typed: Double, omitted: Double)] = [
        "de-AT": (typed: 9, omitted: 1),
        "sq": (typed: 2, omitted: 1),
        "it": (typed: 2, omitted: 1),
        "en-GB": (typed: 3, omitted: 1),
        "en-US": (typed: 3, omitted: 1),
    ]

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
                    // Bigrams are stored under the most frequent form of a key: "keine" → "zeit" means "Zeit".
                    var w = lex.word(s.id)
                    if language == .deAT, Self.germanNouns.contains(TextUnits.lookupKey(w)) { w = Casing.capitalizingFirstLetter(w) }
                    offer(w, s.log2Prob + p, language)
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
