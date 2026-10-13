import Foundation

/// Estimates which of the enabled languages the user is currently writing in.
///
/// Each *informative* committed word (known in some, but not all, of the candidate languages) first
/// decays the old evidence by `decay` and then adds one unit, split evenly among the languages that
/// know the word. Shares are smoothed (`smoothing` pseudo-counts per language), so without evidence
/// all languages are equally likely.
public final class LanguageDetector {
    /// Weight kept from older evidence per informative word (0.85 ⇒ half-life ≈ 4 words).
    public var decay: Double
    /// Pseudo-count added to every language when computing shares.
    public var smoothing: Double
    /// Lower bound of `logShare` in bits.
    public var floor: Double

    public private(set) var scores: [KeyboardLanguage: Double] = [:]
    /// Number of informative words observed since the last reset.
    public private(set) var observationCount = 0

    public init(decay: Double = 0.85, smoothing: Double = 0.5, floor: Double = -4) {
        self.decay = decay
        self.smoothing = smoothing
        self.floor = floor
    }

    /// Records a committed word that is known in `knownIn` (any order, may contain duplicates or
    /// languages outside `candidates`, which are ignored). Words known in none or all of the candidate
    /// languages carry no information and are ignored.
    public func observe(knownIn: [KeyboardLanguage], among candidates: [KeyboardLanguage]) {
        let candidates = Self.unique(candidates)
        let known = Self.unique(knownIn.filter { candidates.contains($0) })
        guard !known.isEmpty, known.count < candidates.count else { return }
        for language in scores.keys { scores[language]! *= decay }
        let unit = 1 / Double(known.count)
        for language in known { scores[language, default: 0] += unit }
        observationCount += 1
    }

    /// Seeds the estimate from long-term usage counts (`UserModel.languageUsage`) with a total weight of
    /// `weight` words. Ignored once real observations exist.
    public func seed(usage: [KeyboardLanguage: Int], weight: Double = 2) {
        guard observationCount == 0 else { return }
        let total = usage.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else {
            scores = [:]
            return
        }
        var seeded: [KeyboardLanguage: Double] = [:]
        for (language, count) in usage where count > 0 {
            seeded[language] = weight * Double(count) / Double(total)
        }
        scores = seeded
    }

    /// Share of `language` among `languages` (0…1, smoothed). 0 if `language` is not in the list.
    public func share(of language: KeyboardLanguage, among languages: [KeyboardLanguage]) -> Double {
        let languages = Self.unique(languages)
        guard languages.contains(language) else { return 0 }
        let total = languages.reduce(0) { $0 + (scores[$1] ?? 0) + smoothing }
        guard total > 0 else { return 1 / Double(languages.count) }
        return ((scores[language] ?? 0) + smoothing) / total
    }

    /// `log2(share)` floored at `floor` (the language prior contribution, in bits).
    public func logShare(of language: KeyboardLanguage, among languages: [KeyboardLanguage]) -> Double {
        let s = share(of: language, among: languages)
        return s > 0 ? max(floor, log2(s)) : floor
    }

    /// The language with the highest share (the earliest one on ties), `nil` for an empty list.
    public func mostLikely(among languages: [KeyboardLanguage]) -> KeyboardLanguage? {
        var best: (KeyboardLanguage, Double)?
        for language in Self.unique(languages) {
            let s = share(of: language, among: languages)
            if best == nil || s > best!.1 { best = (language, s) }
        }
        return best?.0
    }

    public func reset() {
        scores = [:]
        observationCount = 0
    }

    static func unique(_ languages: [KeyboardLanguage]) -> [KeyboardLanguage] {
        var seen = Set<KeyboardLanguage>()
        return languages.filter { seen.insert($0).inserted }
    }
}
