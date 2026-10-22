# Keibord — Architecture & Implementation Spec

Keibord is a privacy-first iOS custom keyboard (keyboard extension + SwiftUI container app) that
runs fully on-device. It is sideloaded with a **free Apple developer account** (Sideloadly /
AltStore / SideStore), built **without a Mac** on GitHub Actions, and targets **iOS 17+** (the
owner runs iOS 27). There is **no networking code anywhere**.

This document is the contract between components. When code and this spec disagree, fix one of
them deliberately — do not silently diverge.

---

## 1. Repository layout

```
Core/                       Swift package "KeibordCore" (Foundation only, builds & tests on Linux)
  Package.swift
  Sources/KeibordCore/
    Foundation/             KeyboardLanguage, BaseLayout, QuoteStyle, ReturnKind, Diacritics, TextUnits   [foundation]
    Layout/                 LayoutModel (types) [foundation]; LayoutFactory, Alternates, LayoutGeometry, TouchResolver [C]
    Input/                  FieldContext, InputTypes [foundation]; InputController, TextContext, SmartPunctuation [D]
    Engine/                 EngineTypes [foundation]; SuggestionEngine, Casing, LanguageDetector, AutofillProvider [B]
    Dictionary/             WordLexicon protocol [foundation]; BinaryLexicon, InMemoryLexicon, TrieSearch, LexiconBuilder [A1]
    Settings/               KeibordSettings, Colors [foundation]
    Profile/                PersonalProfile [foundation]
    Learning/               UserModel types [foundation]; UserModelDelta, UserModel+Merge, LearningPolicy, TouchModel [E]
    Storage/                KeyboardRuntimeState, KeibordFile, KeibordJSON [foundation]
    Backup/                 BackupTypes [foundation]; BackupFile [E]
    Emoji/                  EmojiCatalog [E]
  Tests/KeibordCoreTests/   XCTest; Fixtures/ for small test data
Shared/                     iOS-only Swift compiled into BOTH app and keyboard targets [H]
App/                        SwiftUI container app (Sources/, Assets.xcassets, Keibord.entitlements) [I]
Keyboard/                   Keyboard extension (Sources/, KeibordKeyboard.entitlements) [G]
Resources/
  Dictionaries/             <id>.kbdl binary lexicons (de-AT, en-GB, en-US, sq, it) [A2]
  Emoji/                    emoji.json, keywords-<de|en|it|sq>.json [A2]
tools/                      Python build scripts (dictionaries, emoji, icon) [A2, F]
project.yml                 XcodeGen spec (project generated on CI) [F]
.github/workflows/          CI: Linux core tests, macOS unsigned IPA build, release on tag [F]
docs/                       This spec, install guide
```

Letters in brackets name the owning work package (section 12).

### Targets / identifiers

| Thing | Value |
|---|---|
| App bundle id | `com.keibord.app` (display name **Keibord**) |
| Keyboard bundle id | `com.keibord.app.keyboard` (display name **Keibord**) |
| App group (default) | `group.com.keibord.app` |
| Deployment target | iOS 17.0, iPhone only (`TARGETED_DEVICE_FAMILY = 1`) |
| Swift | language mode 5 (`SWIFT_VERSION = 5.0`), strict concurrency minimal |
| Version | `MARKETING_VERSION = 1.0.0`, build `1` |

The keyboard extension's Info.plist `NSExtension`:
`NSExtensionPointIdentifier = com.apple.keyboard-service`,
`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController`,
`NSExtensionAttributes = { IsASCIICapable = YES, PrefersRightToLeft = NO, PrimaryLanguage = de-AT, RequestsOpenAccess = YES }`.

Sideloading tools may rename the app group (AltStore/SideStore append the team id and list the
real ids in the Info.plist key `ALTAppGroups`). **Never hard-code the group id** — use
`AppGroup.identifier` (Shared/) which resolves it at runtime (section 9.1).

---

## 2. Foundation types (already written — read the code)

* `KeyboardLanguage` (`de-AT`, `en-GB`, `en-US`, `sq-AL`, `sq-XK`, `it-IT`): display names, short
  labels, `dictionaryID` (sq-AL and sq-XK share `sq`), default base layout (QWERTZ for German and
  Albanian, QWERTY for English/Italian), `extraLetterKeys` (German: ü / ö ä, Albanian: ç / ë),
  currency, decimal separator, quote style, localised return-key labels, space label.
* `Diacritics`: base ↔ variant letter tables (`ë`→`e`, `ç`→`c`, `ß`→`s`, …), `baseOfUnit` for UTF-16.
* `TextUnits`: word-character classification, `trailingWord(in:)`, `words(in:)`, `lookupKey(_:)`
  (NFC + lower-case + `’`→`'`).
* `LayoutModel`: `LayoutPage`, `LayoutVariant`, `KeyAction`, `KeyStyle`, `KeyWidth`, `KeySpec`,
  `KeyRow`, `KeyboardLayout`, `LayoutRequest`.
* `FieldContext` / `FieldKind` / `AutocapitalizationMode`.
* `EngineTypes`: `TapCandidate`, `TapInput`, `Suggestion`, `SuggestionKind`, `SuggestionQuery`,
  `SuggestionResult`, protocol `SuggestionProviding`.
* `InputTypes`: protocol `TextDocumentProxyLike`, `ShiftState`, `KeyEvent`, `LearningEvent`,
  protocol `LearningSink`.
* `WordLexicon` protocol, `FuzzyMatch`, `FuzzyCostModel`.
* `KeibordSettings`, `AppearanceSettings`, `RGBAColor`, `KeyColorScheme`, `TintedKey`, enums.
  Decoding is tolerant (`KeyedDecodingContainer.value(_:default:)`). **Every new Codable model must
  decode tolerantly the same way** so old files and backups always load.
* `PersonalInfo`, `TextShortcut`, `PersonalProfile`.
* `UserModel`, `LearnedWord`, `TouchStat`, `EmojiStat`.
* `KeyboardRuntimeState`, `KeibordFile`, `KeibordJSON` (ISO-8601 dates, sorted keys).
* `BackupPayload`, `BackupCipher`, `BackupError`, `ImportMode`.

All Core API used by the app/keyboard must be `public` (including initialisers — Swift memberwise
initialisers are internal).

---

## 3. Binary lexicon format `.kbdl` (version 1)

Little-endian. All section offsets are absolute byte offsets from the file start and 4-byte aligned.

```
Header (64 bytes)
  0  magic        4 bytes  "KBDL"
  4  version      UInt32   1
  8  wordCount    UInt32
 12  nodeCount    UInt32
 16  valueCount   UInt32   number of UInt32 entries in the values section
 20  bigramCount  UInt32
 24  blobOffset   UInt32   UTF-8 word blob
 28  blobSize     UInt32
 32  wordOffsets  UInt32   (wordCount + 1) × UInt32 byte offsets into the blob (word i = blob[o[i] ..< o[i+1]])
 36  zipfOffset   UInt32   wordCount × UInt8   zipf byte (see below)
 40  nodesOffset  UInt32   nodeCount × 12-byte nodes
 44  valuesOffset UInt32   valueCount × UInt32 word ids
 48  bigramIndex  UInt32   (wordCount + 1) × UInt32 start indices into bigram entries
 52  bigramOffset UInt32   bigramCount × UInt32 entries
 56  langID       8 bytes  ASCII dictionary id, NUL padded ("de-AT", "sq", …)

Node (12 bytes)
  0  firstChild   UInt32   index of the first child node (children are contiguous, sorted by `char` ascending); 0 = no children
  4  char         UInt16   UTF-16 code unit of this node's character (root: 0)
  6  childCount   UInt8
  7  maxZipf      UInt8    max zipf byte of any word in this node's subtree (incl. itself)
  8  valueRef     UInt32   high 8 bits = number of word ids stored at this node (0 = not terminal),
                           low 24 bits = start index into the values section
```

* **Words** are stored with their dictionary casing (`Haus`, `London`, `I`, `don't`). Word ids are
  assigned in order of descending frequency (id 0 = most frequent), so `topWords` is `0..<n`.
* **Trie keys** are `TextUnits.lookupKey(word)` (lower-case NFC, `'` apostrophe). Every key code unit
  is a single UTF-16 unit (BMP); words containing other characters are dropped by the builder.
  Several words can share a key (`essen`/`Essen`, `us`/`US`): the node stores all their ids,
  most frequent first. Root is node 0; nodes are laid out breadth-first.
* **zipf byte** = `round(zipf × 32)` clamped to 0…255 (zipf = log10 occurrences per billion words).
  Decode: `zipf = byte / 32`.
* **Bigrams**: for word id `w`, entries `bigramIndex[w] ..< bigramIndex[w+1]`, sorted by score
  descending. Entry = `nextWordId (low 24 bits) | score << 24`. `score = clamp(round(255 + 32 ×
  log2 P(next | prev)), 0, 255)`; decode `log2P = (score − 255) / 32`. Pairs with P < 2^-8 are dropped.
  Bigrams are keyed by word *id* of the most frequent casing of each side.

Writers: `tools/build_dictionaries.py` (real dictionaries) and `LexiconBuilder` (Swift, tests and
user lexicon serialisation). Reader: `BinaryLexicon` (memory-mapped via
`Data(contentsOf:options: .alwaysMapped)`; keep the `Data` alive, read with unaligned loads).
A Python round-trip validator and a Swift test that loads every bundled file guard the format.

### Dictionary sources (built offline by `tools/build_dictionaries.py`, outputs committed)

* Frequencies: OpenSubtitles 2018 word counts from `hermitdave/FrequencyWords`
  (`content/2018/<de|en|it|sq>/<lang>_full.txt`, lower-cased) → zipf via counts per billion.
* Spelling + casing: Hunspell dictionaries from `LibreOffice/dictionaries` (de_AT_frami, en_GB,
  en_US, it_IT, sq_AL) checked with the `hunspell` CLI (apt). For each lower-case corpus word, the
  valid forms among {lower, Capitalised, UPPER} are kept (German nouns become `Haus`, English `I`,
  `London`). Frequent words rejected by Hunspell but plausible (alphabetic, high rank) are kept.
* Bigrams: `orgtre/google-books-ngram-frequency` `ngrams/2grams_<english|german|italian>.csv`.
  Albanian has no bigram source (predictions come from learning + unigrams).
* Austrian supplement (`tools/data/de-AT-supplement.txt`): Jänner, Feber, heuer, Paradeiser,
  Erdäpfel, Marille, Topfen, Obers, Schlagobers, Sackerl, Semmel, Kipferl, Palatschinken, Fisolen,
  Karfiol, Kren, Ribisel, Kukuruz, Melanzani, Zuckerl, Stiege, Kasten, Spital, Matura, Trafik,
  Beisl, Heuriger, leiwand, Jause, Schwammerl, Knödel, Würstel, Pickerl, Kassa, Häferl, Vogerlsalat,
  Faschiertes, Rauchfangkehrer, Gehsteig, Mistkübel, Polster, Sessel, Servus, Baba, oida, …
* Size target per file ≤ 12 MB; word count ≤ 250 000 (German may use the full budget).
* `en-GB` / `en-US` share frequencies but are filtered by their own Hunspell, so `colour`/`color`
  are each only valid in their variant (and therefore autocorrected in the other).

---

## 4. Dictionary library (Core/Dictionary) — work package A1

* `public final class BinaryLexicon: WordLexicon` — `init(data: Data) throws`, `convenience init(url: URL) throws`
  (memory-mapped). Validates magic/version/bounds; throws `LexiconError`.
* `public final class InMemoryLexicon: WordLexicon` —
  `public init(languageID: String, entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)] = [])`.
  Builds the same trie structure in arrays (used for the user's learned words; must build 20 000
  words in < 50 ms).
* `public enum LexiconBuilder` — `static func build(languageID:entries:bigrams:) -> Data` producing a
  valid `.kbdl` (same algorithm as the Python writer).
* Shared trie algorithms (`TrieSearch`) generic over a node-access protocol so both lexicons use the
  same code:
  * `lookup(key:)` — walk the trie.
  * `completions(prefix:limit:)` — best-first search using `maxZipf` (priority queue), returns the
    `limit` most frequent words starting with the prefix (exact match included).
  * `fuzzySearch(taps:costs:maxCost:limit:)` — DFS over the trie carrying a weighted
    Damerau–Levenshtein DP row per depth (rows for previous two depths for transpositions); prune when
    `min(row) > maxCost`; at terminal nodes emit `row[last]`. Cost rules in `FuzzyCostModel` doc
    comment (diacritic handling via `Diacritics.baseOfUnit`). Trailing apostrophe/hyphen in the word
    costs `apostropheInsertion`. Return best cost per word id, sorted ascending, top `limit`.
  * Performance budget (Linux, release build, 200k-word German lexicon, 8-letter input,
    maxCost 18): fuzzySearch < 8 ms, completions < 1 ms, lookup < 0.05 ms.
* `successors(of:limit:)` and `topWords(limit:)` per format.

## 5. Suggestion engine (Core/Engine) — work package B

`public final class SuggestionEngine: SuggestionProviding`

```swift
public init(lexiconProvider: @escaping (KeyboardLanguage) -> WordLexicon?)
public func setUserLexicon(_ lexicon: WordLexicon?)               // learned words (InMemoryLexicon, languageID "user")
public func setUserModel(_ model: UserModel)                       // bigrams, blocked words, language usage
public func setShortcuts(_ shortcuts: [TextShortcut])              // Keibord shortcuts
public func setSupplementaryLexicon(_ entries: [(input: String, text: String)]) // iOS UILexicon (text replacements, contact names)
public var costModel: FuzzyCostModel
public func suggest(_ query: SuggestionQuery) -> SuggestionResult
public func noteCommitted(word: String, language: KeyboardLanguage?)
public func isKnownWord(_ word: String, languages: [KeyboardLanguage]) -> Bool
public func likelyLanguage(of word: String, among languages: [KeyboardLanguage]) -> KeyboardLanguage?
```

Probabilistic model, everything in **bits** (log2):

* `score(candidate) = LM(candidate) − editCost(typed → candidate) + languagePrior(lang)`.
* `LM`: if a bigram (prev, cand) exists (lexicon or user model) → `log2(0.7·P_bi + 0.3·P_uni)`,
  else `log2(P_uni) + log2(0.4)`. User-learned words: `P_uni` from count (`zipf ≈ 3 + log10(count)`,
  max 6). Blocked words are never returned.
* Taps: use `query.taps` when its count equals `currentWord.count`; otherwise synthesise taps
  with `TapInput.exact` for each character (the keyboard passes proximity alternatives when known).
* Candidate generation: union over the query languages of `fuzzySearch` (maxCost = 6 + 2.5·len,
  capped at 20) + `completions(prefix:)` (completion = prefix match, edit cost 0 plus
  `0.5 bits × missing letters` capped at 4) + user lexicon + shortcuts.
* Language prior: the first language in `query.languages` gets +1 bit; the `LanguageDetector`
  keeps an exponentially decayed score per language from recently committed words (a word known
  only in language L moves the estimate towards L) and contributes `log2(share)` (floored at −4).
* **Autocorrect decision** (only if `query.autocorrectEnabled && query.field.autocorrectAllowed`):
  * Never when the typed word contains digits, has inner capitals (`iPhone`), is 1 letter, was
    rejected before (user model / learned literal), or is a known word — with two exceptions:
    (a) **case correction**: every dictionary form of the typed key is capitalised (German nouns,
    English "I") → correct to that form unless the user typed capitals; (b) **accent restoration**
    is just a normal correction because "eshte" is not a word.
  * Otherwise pick the best candidate; autocorrect when its score exceeds the "typed word is an
    unknown word" baseline (`log2P = −30`, cost 0) by ≥ 6 bits and its edit cost ≤ 4 + 2·len.
* **Casing** (`Casing.apply(typed:to:)`): typed ALL CAPS (≥2 letters) → upper-case; typed
  Capitalised → capitalise the candidate's first letter; otherwise keep the dictionary form
  (`Haus`, `London`). At sentence start predictions are capitalised.
* **Bar layout** (`SuggestionResult.suggestions`, max 3):
  * With autocorrection: `[typed literal (display “typed” in quotes), autocorrection (isAutocorrect), next best]`.
  * Typing without autocorrection: `[typed literal, best, second]`; the literal is omitted when it equals the best.
  * No current word: predictions (bigrams of the previous word — user bigrams first — then
    frequent words), capitalised at sentence start.
  * Shortcut match (`currentWord` equals a shortcut's `shortcut`, case-insensitive): the phrase is
    the autocorrection (kind `.shortcut`).
* Personal-info fields: `AutofillProvider.suggestions(for: FieldKind, typedPrefix: String, info: PersonalInfo) -> [Suggestion]`
  (kind `.autofill`, filters by prefix, `appendsSpace = false`). Exposed as
  `engine.setProfile(_:)`; `suggest` returns autofill items for `.isPersonalInfo` fields and no
  word suggestions there.
* Performance: `suggest` < 15 ms for 3 languages on Linux debug-free release build.

## 6. Layouts (Core/Layout) — work package C

`public enum LayoutFactory { public static func layout(for request: LayoutRequest) -> KeyboardLayout }`

* **Letters** (`.letters`): base rows QWERTZ `qwertzuiop / asdfghjkl / yxcvbnm` or QWERTY
  `qwertyuiop / asdfghjkl / zxcvbnm`, plus `language.extraLetterKeys` appended to rows 0 and 1
  (German QWERTZ: `qwertzuiopü / asdfghjklöä / yxcvbnm`; Albanian QWERTZ: `qwertzuiopç / asdfghjklë
  / yxcvbnm`). `unitCount = max(len(row0), len(row1))`. Row 2: `shift (1.3u·k)`, spacer(fill), 7
  letters, spacer(fill), `backspace (1.3u·k)`. Bottom row: `numbers "123"`, `emoji`, optional
  `language` (when `showLanguageKey`), optional `globe` (when `showGlobeKey`), `space (fill)`, `return`.
  Bottom-row widths (`LayoutFactory.BottomRowWidths`) are specified for a 10-unit row (123: 1.25,
  emoji: 1.25, language: 1.15, globe: 1.15, return: 2.4 minus 0.2 per character key in the row) and
  scaled by `unitCount / 10`. When the optional keys would squeeze the space bar below 4u (3.5u with
  character keys, `.com` 1.6u), function keys shrink towards 1u and return towards 1.5u; if that is not
  enough the emoji key is dropped (only when the globe key is shown). Characters already on the page
  (`@`, `.` on "123") are not repeated.
  Variants: `.email` → `…, space, "@" (1u), "." (1u), return`; `.url` → `…, "." , "/", ".com"
  (id `dotcom`, fill, alternates `Alternates.topLevelDomains(for:)`), return` (no space);
  `.webSearch` → `…, space, ".", return`.
  Optional number row (`showNumberRow`) on top: `1…0` with alternates.
* **Numbers** (`.numbers`): `1 2 3 4 5 6 7 8 9 0` / `- / : ; ( ) <currency> & @ "` /
  `symbols "#+=" (1.3u), spacer, . , ? ! ' (1.4u each), spacer, backspace` / bottom row with
  `letters "ABC"` instead of 123.
* **Symbols** (`.symbols`): `[ ] { } # % ^ * + =` / `_ \ | ~ < > + three other currencies + •` /
  `numbers "123", spacer, . , ? ! ', spacer, backspace` / bottom row with "ABC".
* **Number pads** (`.numberPad`, `.decimalPad`): 3 columns (`unitCount = 3`): `1 2 3 / 4 5 6 / 7 8 9 /
  [decimalSeparator or spacer] 0 backspace`; add globe on the last row's left when `showGlobeKey`
  and no decimal key… (keep it simple: decimal pad bottom-left = separator, number pad bottom-left =
  globe if needed else spacer).
* **Alternates** (`Alternates.swift`), per language, lower-case, first entry = most likely:
  German `a: ä à á â æ ã å ā`, `o: ö ô ò ó œ ø ō õ`, `u: ü û ù ú ū`, `s: ß ś š`, `e: é è ê ë ė`,
  `c: ç ć č`, `n: ñ ń`, `z: ž ź ż`, `y: ÿ`, `i: î ï í ì į ī`.
  Albanian `e: ë é è ê`, `c: ç ć č`, plus the generic set. Italian `a: à á â ä æ ã å ā`,
  `e: è é ê ë ē`, `i: ì í î ï ī`, `o: ò ó ô ö õ œ ø ō`, `u: ù ú û ü ū`. English: generic Latin set.
  Symbols: `- → – — •`, `/ → \`, `$/€/£ → $ € £ ¥ ₩ ₽ ¢`, `& → §`, `" → „ “ ” « »`, `' → ‚ ‘ ’ \``,
  `. → …`, `? → ¿`, `! → ¡`, `% → ‰`, `0 → °`, digits → superscripts/fractions (`1 → ¹ ½ ⅓ ¼`, …).
* **Touch-model key** (`KeyboardLayout.touchModelKey`): `"<base><unitCount>.<page>.<variant>"`,
  e.g. `qwertz11.letters.standard`.
* `public struct KeyboardMetrics` — row pitch, key height, gaps, insets; presets
  `static func standard(height: KeyHeightOption, landscape: Bool) -> KeyboardMetrics`
  (portrait standard: rowPitch 54, keyHeight 43 → gaps 11, horizontal gap 6, side inset 3, top inset 4,
  bottom inset 4; compact pitch 50, tall 59; landscape: rowPitch 40 (37/43), keyHeight pitch − 8, top
  inset 3, bottom inset 2). The keyboard lays the key area out inside the view's safe area, so in
  landscape the rounded corners and the sensor housing stay free.
  `func keyboardHeight(rows: Int) -> CGFloat` (excluding the suggestion bar).
* `public enum LayoutGeometry { static func frames(for: KeyboardLayout, width: CGFloat, metrics: KeyboardMetrics) -> [KeyFrame] }`
  — `public struct KeyFrame { key: KeySpec; rect: CGRect; row: Int; index: Int }`. Unit width =
  `(width − 2·sideInset − (unitCount − 1)·hGap) / unitCount`; a `units(u)` key is `u·unit + (u−1)·hGap`
  wide; remaining width goes to `.fill` keys equally, otherwise the row is centred.
* `public struct TouchResolver` — built from frames + learned offsets
  (`[keyID: (dx, dy)]`, normalised, clamped to ±0.25). `func resolve(_ point: CGPoint) -> (frameIndex: Int, tap: TapInput)?`:
  the hit key is the one whose (offset-adjusted) centre is nearest in key-size-normalised distance
  among keys whose expanded rect (half the gap on each side; top row extends up, bottom row down)
  is closest; for letter keys `tap.candidates` lists all letter keys within normalised distance
  1.6 with cost `= 2.5 · (d² − d_hit²) · log2(e)` (bits), each with its `dx/dy` relative to that key.
  `func syntheticTap(for character: String) -> TapInput` returns the key and its neighbours with
  distance-based costs (used when the controller has text but no taps).

## 7. Input controller (Core/Input) — work package D

`public final class InputController` — owns all text-editing logic; UI-agnostic and deterministic.

```swift
public init(document: TextDocumentProxyLike, engine: SuggestionProviding, settings: KeibordSettings, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 })
public weak var delegate: InputControllerDelegate?        // controllerStateDidChange(_:)
public var learningSink: LearningSink?
public var settings: KeibordSettings                       // update when the app changes settings
public private(set) var field: FieldContext
public private(set) var language: KeyboardLanguage
public private(set) var shiftState: ShiftState
public private(set) var page: LayoutPage
public private(set) var suggestions: [Suggestion]
public private(set) var autocorrection: Suggestion?
public func configure(field: FieldContext)                 // on every field change / textDidChange of type
public func setLanguage(_ language: KeyboardLanguage)      // emits .switchedLanguage
public func handle(_ event: KeyEvent)
public func documentDidChange()                            // UIInputViewController.textDidChange: re-sync (cursor moved / app changed text)
public func refreshSuggestions()
public var currentWord: String { get }
```

Behaviour (each rule needs a unit test with an in-memory `TextDocumentProxyLike`):
* **Characters**: letters inserted upper-case when `shiftState.isUppercase` (except `ß` stays `ß`);
  one-shot shift turns off after a letter. Append the tap to the current word's tap list (cleared
  whenever the word boundary changes or the document changes unexpectedly).
* **Space / punctuation commit**: if `autocorrection != nil` for the current word, replace the word
  (one `deleteBackward()` per Character) with the correction, then insert the separator. Remember
  `UndoInfo(original, correction, separator)`. Emit `.committedWord`.
* **Backspace right after an autocorrection** (no other event in between): delete separator +
  correction, re-insert the original word, emit `.rejectedCorrection`, and do not autocorrect this
  word again on the next space (insert a plain space).
* **Suggestion tap**: replace the current word with `suggestion.text` (+ space if `appendsSpace`),
  set the *auto-space* flag. Typed-literal tap commits the literal and emits `.rejectedCorrection` if
  an autocorrection was pending. Predictions insert at the cursor (add a leading space if the
  previous character is a word character).
* **Smart punctuation spacing**: if the auto-space flag is set and the user types one of
  `TextUnits.spaceSwallowingPunctuation`, delete the space, insert the punctuation, then a space
  again (auto-space stays set for `.,!?:;`).
* **Double-space period**: space typed when the previous character is a space that *we* inserted
  by the previous event and the character before it is a word character → replace with ". " (if
  `settings.doubleSpacePeriod`).
* **Smart quotes** (`settings.smartQuotes && field.smartQuotesAllowed`): `"` → open quote when the
  previous character is start/whitespace/opening bracket, else close quote; `'` → apostrophe when
  after a word character, else single open quote; style from `settings.quoteStyle(for: language)`.
* **Auto-capitalisation** (`settings.autoCapitalization` and field mode): `.sentences` → shift on at
  document start, after `. ! ? …` + space, and after a newline; `.words` → after whitespace;
  `.allCharacters` → shift stays on. Manual shift overrides until the next letter. Caps lock
  (`.shiftDoubleTap`, only if `settings.capsLock`) persists until shift is tapped.
  `setShiftHeld(_:)`: while the shift key is held, letters stay capitalised; releasing it after
  typing turns shift off (a tap without typing keeps its state).
* **Pages**: after inserting a space or `'` while on numbers/symbols, return to letters (iOS
  behaviour). `.switchPage` changes page.
* **Backspace**: deletes one character; `.backspaceRepeat(wordMode: true)` deletes back to the
  previous word boundary (whitespace run + word).
* **Return**: commits the current word (with autocorrect), inserts "\n".
* **insertText** (emoji/autofill/.com): commit word without autocorrect if `commitsWord`, insert.
* **moveCursor(n)**: `adjustTextPosition(byCharacterOffset: n)`, clears composing state.
* **Suggestions**: after every event, build a `SuggestionQuery` (current word, taps, two previous
  words from `TextUnits.words(in: contextBefore)`, sentence-start flag, languages =
  `settings.multilingualTyping ? [language] + others : [language]`, field, toggles) and call the engine
  (skip and clear when `settings.predictiveText` is false and the field is prose — but still compute
  the autocorrection).
* Learning events are only emitted when `settings.learningEnabled && field.learningAllowed`
  (emoji usage is always recorded).

## 8. Learning, backup, emoji (Core/Learning, Core/Backup, Core/Emoji) — work package E

* `public struct UserModelDelta` — increments produced by the keyboard between flushes:
  `mutating func record(_ event: LearningEvent, day: Int, now: Double)`; fields mirror `UserModel`
  (word counts + lastUsedDay + language, bigram increments, touch sums, emoji counts, language usage,
  words to mark as rejected/literal). `var isEmpty`.
* `extension UserModel`: `mutating func apply(_ delta: UserModelDelta)` (additive; never resurrects
  blocked words), `mutating func prune(maxWords: Int = 30_000, maxBigrams: Int = 80_000, maxTouch …)`
  (drop lowest `count`, oldest first), `func merged(with other: UserModel) -> UserModel` (import merge:
  sum counts, max lastUsed, union blocked, sum touch), `func knownWords(minCount: Int = 2) -> [(String, Double)]`
  (entries for `InMemoryLexicon`: zipf = min(6, 3 + log10(count)); manual words always included),
  `var emojiRecents: [String]` (most recent first, max 32), `func touchOffsets(for touchModelKey: String, minSamples: Int = 12) -> [String: (dx: Double, dy: Double)]`.
* `LearningPolicy`: what is learned from `.committedWord` — skip words with digits, single letters,
  > 40 chars, URLs/emails; a typed word that was autocorrected away is not learned; a
  `.rejectedCorrection` learns the typed word with +2 (immediately known); touch offsets are
  recorded only when the final word has the same length as the taps and was not autocorrected.
* `public enum BackupFile`:
  `static func encode(_ payload: BackupPayload, password: String?, cipher: BackupCipher?, iterations: Int = 210_000) throws -> Data`,
  `static func decode(_ data: Data, password: String?, cipher: BackupCipher?) throws -> BackupPayload`,
  `static func isEncrypted(_ data: Data) -> Bool`,
  `static func apply(_ payload: BackupPayload, mode: ImportMode, to current: (settings: KeibordSettings, profile: PersonalProfile, model: UserModel)) -> (KeibordSettings, PersonalProfile, UserModel)`.
  Envelope JSON: `{"format":"keibord-backup","version":1,"encrypted":false,"payload":{…}}` or
  `{"format":"keibord-backup","version":1,"encrypted":true,"kdf":{"name":"PBKDF2-SHA256","iterations":N,"salt":"<b64>"},"cipher":"AES-GCM-256","box":"<b64 combined>"}`.
* `public final class EmojiCatalog` — `init(baseURL: URL) throws` reading `emoji.json` and lazily
  `keywords-<code>.json`; `categories: [EmojiCategory]` (`id`, `emojis`), `variants(of:) -> [String]`
  (skin tones), `search(_ query: String, languageCodes: [String], limit: Int) -> [String]` (prefix
  match on keyword words, ranked: exact keyword > prefix of first keyword > other prefix; accent-folded).
  Category ids: `smileys_people, animals_nature, food_drink, activity, travel_places, objects, symbols, flags`.
  Localised category titles for de/en/it/sq via `EmojiCatalog.title(for:languageCode:)`.

Emoji data files (written by `tools/build_emoji.py` from Unicode `emoji-test.txt` 17.0 and CLDR
`annotations` + `annotationsDerived`):
* `emoji.json`: `{"version":"17.0","categories":[{"id":"smileys_people","emojis":["😀",…]},…],"variants":{"👍":["👍🏻","👍🏼","👍🏽","👍🏾","👍🏿"],…}}`
  (fully-qualified only, no `component` group, skin-tone variants only under `variants`).
* `keywords-<de|en|it|sq>.json`: `{"😀":["grinsendes gesicht","gesicht","grinsen"],…}` — lower-cased,
  the CLDR TTS name first.

## 9. iOS shared layer (Shared/) — work package H

Compiled into both targets (no framework). UIKit/CryptoKit/Security/CommonCrypto allowed.

1. **`AppGroup`**: resolves the group id in this order: (a) Info.plist `ALTAppGroups` array (first
   entry containing "keibord", else first); (b) `com.apple.security.application-groups` parsed from
   `embedded.mobileprovision` in the current bundle (the XML plist between `<?xml` and `</plist>`);
   (c) `group.com.keibord.app`. Accept the first id for which
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` is non-nil and the
   `Keibord/` directory inside it is creatable. `static var containerURL: URL?`,
   `static var isAvailable: Bool`, `static var resolvedIdentifier: String?`, `static var diagnostics: String`.
   The extension's bundle is `.appex`; use `Bundle.main` in both processes.
2. **`KeibordStore`** (singleton per process): root = `<group>/Keibord/` or, if unavailable, the
   process's own Application Support (`isShared = false`). Generic coordinated JSON read/write
   (`NSFileCoordinator`, atomic writes, `.completeUntilFirstUserAuthentication` protection).
   API: `loadSettings() -> KeibordSettings`, `saveSettings(_:)`, `loadProfile()`, `saveProfile(_:)`,
   `loadUserModel()`, `saveUserModel(_:)` (app edits), `flush(_ delta: UserModelDelta)` (coordinated
   read → apply → prune → write; used by the keyboard), `updateUserModel(_ transform: (inout UserModel) -> Void)`,
   `loadState()`, `saveState(_:)`, `modificationDate(of: KeibordFile) -> Date?`,
   `resetAll()`. Darwin notification `com.keibord.settingsChanged` posted after app-side saves
   (`KeibordStore.postSettingsChanged()`, `observeSettingsChanged(_ handler:)`).
3. **`Keychain`**: generic-password get/set/delete with optional access group
   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
4. **`DeviceSecret`**: 32 random bytes; stored in Keychain under service `com.keibord.device-secret`
   with access group = resolved app group id; if the keychain call fails, fall back to
   `KeibordFile.deviceKey` in the store directory. Both processes resolve it the same way.
5. **`CardVault`** (cards.json; never exported): 
   ```swift
   struct StoredCard: Codable, Identifiable { id: UUID; nickname: String; holderName: String; last4: String; brand: CardBrand; expMonth: Int; expYear: Int; requiresCVV: Bool; salt: Data; sealedNumber: Data; failedAttempts: Int; createdAt: Date }
   struct UnlockedCard { card: StoredCard; number: String; cvv: String? }
   enum CardVaultError: Error { invalidNumber, wrongCVV, lockedOut, cryptoFailure, storageUnavailable }
   final class CardVault { static let shared; func cards() -> [StoredCard]; func add(nickname:holderName:number:expMonth:expYear:requiresCVV:cvv:) throws -> StoredCard; func update(_:) throws; func delete(id:) ; func unlock(id: UUID, cvv: String?) throws -> UnlockedCard; func resetAttempts(id:) }
   ```
   Key = HKDF-SHA256(ikm: DeviceSecret, salt: card.salt, info: "keibord.card.v1|" + (cvv ?? "")),
   number sealed with AES-GCM. The CVV itself is **never stored**; a wrong CVV fails AES-GCM
   authentication. 5 failed attempts → `lockedOut` until reset in the app. `CardBrand.detect(number)`
   (visa, mastercard, amex, maestro, discover, jcb, dinersClub, unionPay, unknown) and Luhn validation.
6. **`PasswordBackupCipher: BackupCipher`** — PBKDF2-SHA256 via `CCKeyDerivationPBKDF`, AES-GCM via CryptoKit.
7. **Colour bridging**: `RGBAColor.uiColor`, `RGBAColor(uiColor:)`, SwiftUI `Color(rgba:)`.
8. **`KeibordVersion`**: marketing version/build from `Bundle.main`.

## 10. Keyboard extension (Keyboard/) — work package G

UIKit (no SwiftUI in the extension — memory). Principal class `KeyboardViewController: UIInputViewController`.

* **Lifecycle**: `viewDidLoad` → load settings/profile/user model from `KeibordStore`, create
  `SuggestionEngine` (lexicons loaded lazily per language from the extension bundle
  `Dictionaries/<id>.kbdl` and cached), `InputController`, views. `viewWillAppear` → reload changed
  files (modification dates), `configure(field:)` from `textDocumentProxy`, write
  `KeyboardRuntimeState` (hasFullAccess, lastActive, language, version, group id). `textWillChange`
  / `textDidChange` → `controller.documentDidChange()` and re-derive the field context (the focused
  field can change). `viewWillDisappear` → flush learning delta. Flush also every 25 committed words.
  Request `requestSupplementaryLexicon` once and pass entries to the engine. Observe the Darwin
  notification to reload settings.
* **Field mapping** (`FieldContextMapper`): `UITextDocumentProxy.textContentType` → `FieldKind`
  (`.emailAddress`→email, `.URL`→url, `.username`→username, `.telephoneNumber`→phone,
  `.oneTimeCode`→oneTimeCode, `.name`→fullName, `.givenName`, `.middleName`, `.familyName`,
  `.nickname`, `.organizationName`→organization, `.jobTitle`, `.fullStreetAddress`,
  `.streetAddressLine1`, `.streetAddressLine2`, `.postalCode`, `.addressCity`→city,
  `.addressState`→region, `.countryName`→country, `.creditCardNumber`, and the iOS 17 card types
  `.creditCardExpiration`, `.creditCardExpirationMonth`, `.creditCardExpirationYear`,
  `.creditCardSecurityCode`, `.creditCardName`, `.creditCardGivenName`, `.creditCardFamilyName`,
  `.creditCardType`); fallback from `keyboardType` (`.emailAddress`→email, `.URL`→url,
  `.webSearch`→webSearch, `.numberPad`/`.asciiCapableNumberPad`→number, `.decimalPad`→decimal,
  `.phonePad`→phone). Also `autocapitalizationType`, `autocorrectionType`, `smartQuotesType`,
  `returnKeyType`, `enablesReturnKeyAutomatically`, `isSecureTextEntry`, `keyboardAppearance`.
* **Height**: suggestion bar 44 pt + `metrics.keyboardHeight(rows:)`; set via a height constraint on
  `view` (priority 999); recompute on rotation (`viewWillTransition`) and on layout changes.
* **KeyboardView** (single view handling all touches; `isMultipleTouchEnabled = true`): lays out
  `KeyView`s from `LayoutGeometry.frames`, resolves touches through `TouchResolver` (with the
  learned offsets when `settings.adaptiveTouch`). Letter keys commit on touch-up; a new touch
  commits any pending letter touch first (rollover). Sliding to another key before the long-press
  fires moves the selection. Long-press (0.42 s) on a key with alternates opens the alternates
  callout (slide to choose, release to insert). Key popup preview for character keys when
  `settings.keyPopups` (balloon above the key, clamped inside the view — the system clips anything
  above the keyboard). Backspace: delete on touch-down, repeat after 0.5 s every 0.09 s, switch to
  word mode after 1.2 s. Shift: tap / double-tap within 0.3 s → caps lock; its release (also cancelled) → `.shiftReleased`. Space: tap inserts; long
  press (0.4 s, when `settings.spacebarCursor`) → trackpad mode (key labels fade), horizontal drag of
  ~9 pt per character → `.moveCursor`. Language key: tap → next language, long-press → list.
  Globe: `handleInputModeList(from:with:)` via `addTarget` for all touch events. Emoji key → emoji panel.
* **KeyView**: rounded rect (`settings.appearance.keyCornerRadius`), optional 1-pt bottom shadow,
  label (system font: letters 23 pt × labelScale, function keys 16 pt) or SF Symbol icons
  (`shift`, `shift.fill`, `capslock.fill`, `delete.left`, `globe`, `face.smiling`, `return`).
  Colours from `appearance.colors(dark:)` where dark = theme `.dark`, or `.system` and
  (`keyboardAppearance == .dark` or `traitCollection.userInterfaceStyle == .dark`). Tinted keys
  override key colour/label colour for matching `KeySpec.id`. Return key uses `accent` when
  `returnKind.isProminent`; disabled look when `enablesReturnKeyAutomatically` and the document is empty.
* **SuggestionBarView**: 3 equal slots with hairline separators; the autocorrect slot is
  highlighted (rounded light background); the literal is shown in quotes. Autofill/card chips
  replace word suggestions in matching fields. In one-time-code fields (when
  `settings.oneTimeCodeHint`) show an action chip "Codes from Messages → iOS keyboard" that calls
  `advanceToNextInputMode()`. Without Full Access show a one-line hint (tap → instructions).
* **EmojiPanelView**: replaces the key area. Horizontal paging `UICollectionView` with sections per
  category (recents first), category bar at the bottom (`ABC` button, SF Symbol category icons:
  `clock`, `face.smiling`, `pawprint`, `fork.knife`, `basketball`, `car`, `lightbulb`,
  `music.note`/`heart`, `flag`), backspace on the right. Long-press an emoji with variants → skin-tone
  picker. Search field at the top: tapping it shows the letters layout with the search query
  above it (keys go to the query, not the document), results row of matching emojis.
* **CardUnlockView**: appears when a card chip is tapped for a card with `requiresCVV`: title
  ("CVV for Visa •••• 1234"), dots, own numeric keypad, cancel. On success insert the value for the
  focused field kind (number → digits only, expiration → "MM/YY", month → "MM", year → "YY" or
  "YYYY" if the field had ≥4 chars of placeholder… keep "MM/YY"/"MM"/"YYYY"/"YY" heuristics simple,
  security code → the CVV just typed, holder name → holderName). An unlocked card stays unlocked in
  memory for 3 minutes.
* **Feedback**: haptics via `UIImpactFeedbackGenerator` (light/medium/heavy per setting; only
  with Full Access), key clicks via `UIDevice.current.playInputClick()` (the input view adopts
  `UIInputViewAudioFeedback`).
* **Memory**: no SwiftUI, no large caches; lexicons are memory-mapped; emoji catalog loaded on first
  use of the panel.

## 11. Container app (App/) — work package I

SwiftUI, `NavigationStack` + `List`. Tabs: **Keyboard** (home), **Settings**, **Data**.
* **Home / Setup**: logo, status cards (keyboard heartbeat from `state.json` → "active"/"not yet
  used"; Full Access; app group shared container OK), step-by-step setup (Settings → General →
  Keyboard → Keyboards → Add New Keyboard → Keibord → Allow Full Access) with an "Open Settings"
  button (`UIApplication.openSettingsURLString`), a test text field.
* **Languages**: enable/disable + reorder (`EditButton`), per-language layout (QWERTZ/QWERTY), quote
  style, multilingual typing toggle.
* **Typing**: all typing toggles of `KeibordSettings`.
* **Appearance**: theme mode, key height, corner radius slider, shadows, label scale, uppercase
  labels, number row, space language label, custom colours (ColorPicker per scheme entry, reset to
  iOS default), **tinted keys editor**: an interactive SwiftUI keyboard preview (built from
  `LayoutFactory` + `LayoutGeometry` exactly like the keyboard) — tap keys to select one or many,
  pick a colour, apply/remove; list of tinted keys with swatches. Live preview everywhere.
* **Dictionary**: learned words (search, sort by count/recent, swipe to delete, add word), blocked
  words (add/remove), statistics (word count, bigram count, touch samples). Edits go through
  `KeibordStore.updateUserModel`.
* **Shortcuts**: list/add/edit/delete `TextShortcut`.
* **AutoFill**: personal info form (multiple emails/phones/usernames), cards list (`CardVault`):
  add card (nickname, holder, number with Luhn check & brand detection, expiry, "Require CVV to
  unlock" with CVV entry used only to derive the key), delete, reset failed attempts. Explain that
  passwords/one-time codes are handled by iOS.
* **Data**: export (`.fileExporter`, JSON document `Keibord-Backup-YYYY-MM-DD.json`, options: include
  personal info, password-protect), import (`.fileImporter`, password prompt if encrypted, merge or
  replace), reset learned data, reset everything. Diagnostics section.
* App UI language: English.

## 12. Work packages & ownership

| Pkg | Scope | Owns |
|---|---|---|
| A1 | Lexicon library | `Core/Sources/KeibordCore/Dictionary/*` (except WordLexicon.swift), tests `LexiconTests*.swift` |
| A2 | Data pipeline | `tools/build_dictionaries.py`, `tools/build_emoji.py`, `tools/data/*`, `Resources/Dictionaries/*`, `Resources/Emoji/*` |
| B | Suggestion engine | `Core/Sources/KeibordCore/Engine/*` (except EngineTypes.swift), tests `Engine*Tests.swift` |
| C | Layouts & geometry | `Core/Sources/KeibordCore/Layout/*` (except LayoutModel.swift), tests `Layout*Tests.swift` |
| D | Input controller | `Core/Sources/KeibordCore/Input/*` (except FieldContext/InputTypes), tests `Input*Tests.swift` |
| E | Learning/backup/emoji | `Core/Sources/KeibordCore/{Learning,Backup,Emoji}/*` (except UserModel.swift/BackupTypes.swift), tests |
| F | Infra | `project.yml`, `.github/workflows/*`, `App/Assets.xcassets`, `*.entitlements`, `tools/make_icon.py`, `README.md`, `docs/INSTALL.md` |
| H | iOS shared | `Shared/*` |
| G | Keyboard UI | `Keyboard/Sources/*` |
| I | App UI | `App/Sources/*` |

Foundation files may only be changed with care (they are shared contracts); additive changes
(new cases with defaults, new helpers) are fine.

## 13. Build & test

* Core: `swift test --package-path Core` (Linux & macOS).
* iOS: CI generates the project with XcodeGen and builds unsigned (`CODE_SIGNING_ALLOWED=NO`), then
  ad-hoc signs the `.appex` and the app with their entitlements (`codesign -f -s - --entitlements`)
  so sideloading tools pick up the app group, zips `Payload/Keibord.app` into `Keibord.ipa`.
  Tags `v*` publish a GitHub release with the IPA.
