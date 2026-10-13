import Foundation

/// Read access to a lexicon laid out like the `.kbdl` format (ARCHITECTURE.md §3), implemented by the
/// memory-mapped file view and by the in-memory tables so both lexicons share `TrieSearch`.
/// Implementations only need to be memory-safe for indices inside the declared counts; `TrieSearch`
/// clamps every range it derives from stored fields.
protocol TrieNodeAccess {
    var wordCount: Int { get }
    var nodeCount: Int { get }
    var valueCount: Int { get }
    var bigramCount: Int { get }
    func nodeFirstChild(_ node: Int) -> Int
    func nodeUnit(_ node: Int) -> UInt16
    func nodeChildCount(_ node: Int) -> Int
    func nodeMaxZipf(_ node: Int) -> UInt8
    func nodeValueRef(_ node: Int) -> UInt32
    /// Word id stored at `index` of the values section.
    func value(at index: Int) -> Int
    func zipfByte(_ id: Int) -> UInt8
    /// `bigramIndex[id]` for id in 0...wordCount.
    func bigramStart(_ id: Int) -> Int
    func bigramEntry(_ index: Int) -> UInt32
}

extension TrieNodeAccess {
    /// Child node indices, clamped. Children always come after their parent (breadth-first layout),
    /// which also rules out cycles in a damaged file.
    @inline(__always)
    func children(of node: Int) -> Range<Int> {
        let count = nodeChildCount(node)
        guard count > 0 else { return 0..<0 }
        let first = nodeFirstChild(node)
        guard first > node, first < nodeCount else { return 0..<0 }
        return first..<min(first + count, nodeCount)
    }

    /// Indices into the values section of the words stored at `node`, clamped.
    @inline(__always)
    func values(of node: Int) -> Range<Int> {
        let ref = nodeValueRef(node)
        let count = Int(ref >> 24)
        let start = Int(ref & 0xFF_FFFF)
        guard count > 0, start < valueCount else { return 0..<0 }
        return start..<min(start + count, valueCount)
    }
}

/// Lookup-key helpers shared by the builder and the searches.
///
/// Fast path: every scalar below U+0300 is NFC-stable with combining class 0 and lower-cases to a
/// single unit (except U+0130 "İ"), and "’" is NFC-stable too. Text made only of those units is
/// therefore already NFC and its lookup key is a per-unit mapping, without Foundation. Anything
/// else goes through `TextUnits.lookupKey` (tests check both paths agree).
enum LexiconKey {
    /// Lower-case unit for units below 0x300; `noFastPath` where the mapping is not a single unit.
    private static let lowerTable: [UInt16] = (0..<0x300).map { value in
        guard let scalar = Unicode.Scalar(UInt32(value)) else { return noFastPath }
        let lower = Array(String(Character(scalar)).lowercased().utf16)
        return lower.count == 1 ? lower[0] : noFastPath
    }
    private static let noFastPath: UInt16 = 0xFFFF

    /// UTF-16 units of `TextUnits.lookupKey(text)`, or nil when the key contains non-BMP characters.
    static func units(_ text: String) -> [UInt16]? {
        var text = text
        return text.withUTF8(fastUnits) ?? slowUnits(text)
    }

    /// Lookup-key units of UTF-8 text made only of U+0000…U+02FF (1 or 2 bytes, except "İ") and "’"
    /// (E2 80 99), or nil for any other text.
    private static func fastUnits(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt16]? {
        let table = lowerTable
        var supported = true
        let result = [UInt16](unsafeUninitializedCapacity: bytes.count) { out, count in
            var i = 0, n = 0
            while i < bytes.count {
                let b0 = bytes[i]
                if b0 < 0x80 {
                    out[n] = table[Int(b0)]
                    i += 1
                } else if b0 >= 0xC2, b0 < 0xCC, i + 1 < bytes.count {
                    let lower = table[Int(b0 & 0x1F) << 6 | Int(bytes[i + 1] & 0x3F)]
                    if lower == noFastPath {
                        supported = false
                        break
                    }
                    out[n] = lower
                    i += 2
                } else if b0 == 0xE2, i + 2 < bytes.count, bytes[i + 1] == 0x80, bytes[i + 2] == 0x99 {
                    out[n] = 0x27
                    i += 3
                } else {
                    supported = false
                    break
                }
                n += 1
            }
            count = supported ? n : 0
        }
        return supported ? result : nil
    }

    static func slowUnits(_ text: String) -> [UInt16]? {
        let units = Array(TextUnits.lookupKey(text).utf16)
        return units.contains(where: isSurrogate) ? nil : units
    }

    /// The word in NFC (stored form of dictionary words).
    static func nfc(_ word: String) -> String {
        var word = word
        let isNFC = word.withUTF8 { bytes -> Bool in
            var i = 0
            while i < bytes.count {
                // Lead bytes ≥ 0xCC start scalars ≥ U+0300 (continuation bytes are < 0xC0).
                if bytes[i] >= 0xCC {
                    guard bytes[i] == 0xE2, i + 2 < bytes.count, bytes[i + 1] == 0x80, bytes[i + 2] == 0x99 else { return false }
                    i += 2
                }
                i += 1
            }
            return true
        }
        return isNFC ? word : word.precomposedStringWithCanonicalMapping
    }

    /// The single key unit of a tap candidate character (lower-cased, `’` → `'`), or nil if the
    /// character does not map to exactly one BMP unit.
    static func tapUnit(_ character: String) -> UInt16? {
        guard let units = units(character), units.count == 1 else { return nil }
        return units[0]
    }

    @inline(__always)
    static func isSurrogate(_ unit: UInt16) -> Bool {
        unit & 0xF800 == 0xD800
    }

    /// Dense copy of `Diacritics.baseOfUnit` for the Latin range used by the dictionaries.
    private static let denseBase: [UInt16] = {
        var table = (0..<UInt16(0x250)).map { $0 }
        for (variant, base) in Diacritics.baseOfUnit where variant < 0x250 { table[Int(variant)] = base }
        return table
    }()

    /// Base letter of a lower-case unit ("ë" → "e"), or the unit itself.
    static func base(_ unit: UInt16) -> UInt16 {
        unit < 0x250 ? denseBase[Int(unit)] : (Diacritics.baseOfUnit[unit] ?? unit)
    }
}

/// Trie algorithms shared by `BinaryLexicon` and `InMemoryLexicon`.
///
/// The traversals visit every node at most once in a well-formed trie; they stop after `nodeCount`
/// visits so a damaged file whose child ranges overlap cannot make them run for exponential time.
enum TrieSearch {
    /// Node reached by following `units` from the root, if any.
    static func findNode<T: TrieNodeAccess>(_ trie: T, units: [UInt16]) -> Int? {
        guard trie.nodeCount > 0 else { return nil }
        var node = 0
        for unit in units {
            let range = trie.children(of: node)
            var lo = range.lowerBound, hi = range.upperBound
            while lo < hi {
                let mid = (lo + hi) >> 1
                if trie.nodeUnit(mid) < unit { lo = mid + 1 } else { hi = mid }
            }
            guard lo < range.upperBound, trie.nodeUnit(lo) == unit else { return nil }
            node = lo
        }
        return node
    }

    static func ids<T: TrieNodeAccess>(_ trie: T, at node: Int) -> [Int] {
        trie.values(of: node).map { trie.value(at: $0) }.filter { $0 < trie.wordCount }
    }

    static func lookup<T: TrieNodeAccess>(_ trie: T, key: String) -> [Int] {
        guard let units = LexiconKey.units(key), let node = findNode(trie, units: units) else { return [] }
        return ids(trie, at: node)
    }

    /// Best-first search over the subtree of `prefix`. Entries are ordered by zipf byte (node bound or
    /// word value), nodes before words on ties, then by index; when a word is popped, every node that
    /// could still hold an equally frequent word has been expanded, so the result equals the `limit`
    /// smallest ids (= most frequent words) in the subtree.
    static func completions<T: TrieNodeAccess>(_ trie: T, prefix: String, limit: Int) -> [Int] {
        guard limit > 0, let units = LexiconKey.units(prefix), let start = findNode(trie, units: units) else { return [] }
        @inline(__always) func entry(_ priority: UInt8, isWord: Bool, _ index: Int) -> UInt64 {
            UInt64(255 - priority) << 48 | (isWord ? 1 << 47 : 0) | UInt64(index)
        }
        var heap = LexiconMinHeap()
        heap.push(entry(trie.nodeMaxZipf(start), isWord: false, start))
        var result: [Int] = []
        var budget = trie.nodeCount
        while let top = heap.pop() {
            let index = Int(top & 0x7FFF_FFFF_FFFF)
            if top & (1 << 47) != 0 {
                result.append(index)
                if result.count == limit { break }
                continue
            }
            budget -= 1
            if budget < 0 { break }
            for k in trie.values(of: index) {
                let id = trie.value(at: k)
                if id < trie.wordCount { heap.push(entry(trie.zipfByte(id), isWord: true, id)) }
            }
            for child in trie.children(of: index) {
                heap.push(entry(trie.nodeMaxZipf(child), isWord: false, child))
            }
        }
        return result
    }

    static func successors<T: TrieNodeAccess>(_ trie: T, of id: Int, limit: Int) -> [(id: Int, log2Prob: Double)] {
        guard limit > 0, id >= 0, id < trie.wordCount else { return [] }
        let start = min(trie.bigramStart(id), trie.bigramCount)
        let available = max(0, min(trie.bigramStart(id + 1), trie.bigramCount) - start)
        let end = start + min(available, limit)
        var result: [(id: Int, log2Prob: Double)] = []
        for k in start..<end {
            let entry = trie.bigramEntry(k)
            let next = Int(entry & 0xFF_FFFF)
            guard next < trie.wordCount else { continue }
            result.append((next, LexiconFormat.log2Prob(fromScore: UInt8(entry >> 24))))
        }
        return result
    }

    static func topWords<T: TrieNodeAccess>(_ trie: T, limit: Int) -> [Int] {
        Array(0..<max(0, min(limit, trie.wordCount)))
    }

    /// Weighted Damerau–Levenshtein (optimal string alignment) search over the trie.
    ///
    /// `row_j[i]` is the cost of aligning the first `i` taps with the first `j` letters of the path:
    ///   min(row_{j-1}[i-1] + sub(i, L_j),                         // tap i typed for letter j
    ///       row_{j-1}[i]   + ins(L_j),                            // letter j not typed
    ///       row_j[i-1]     + deletion,                            // tap i is extra
    ///       row_{j-2}[i-2] + transposition + sub(i, L_{j-1}) + sub(i-1, L_j))
    /// `sub(i, L)` is the cheapest candidate c of tap i with c == L (c.cost) or base(c) == base(L)
    /// (c.cost + diacritic), capped at `substitution`. The base rule covers both `FuzzyCostModel` cases
    /// (word letter has a diacritic the user did not type, or the user typed a diacritic the word lacks)
    /// and also two variants of one base ("perchè" for "perché"). `ins(L)` is `apostropheInsertion` for
    /// "'" and "-", else `insertion`. Words are emitted at terminal nodes with `row_j[n]`.
    /// A subtree is pruned when min(row_j) and min(row_{j-1}) + transposition both exceed the bound:
    /// every deeper row is at least the smaller of the two (all costs are ≥ 0). The bound tightens to the
    /// current `limit`-th best cost once enough matches were found.
    static func fuzzySearch<T: TrieNodeAccess>(_ trie: T, taps: [TapInput], costs model: FuzzyCostModel, maxCost: Double, limit: Int) -> [FuzzyMatch] {
        guard limit > 0, maxCost >= 0, trie.nodeCount > 0 else { return [] }
        let costs = FuzzyCostModel(substitution: max(0, model.substitution), insertion: max(0, model.insertion),
                                   deletion: max(0, model.deletion), transposition: max(0, model.transposition),
                                   diacritic: max(0, model.diacritic), apostropheInsertion: max(0, model.apostropheInsertion))
        let n = taps.count
        let width = n + 1
        let work = FuzzyWorkspace(taps: taps, costs: costs, initialDepth: n + 24)
        var results = LexiconMatchHeap(limit: limit)
        var bound = maxCost

        let row0 = work.rows
        row0[0] = 0
        for i in stride(from: 1, through: n, by: 1) { row0[i] = row0[i - 1] + costs.deletion }
        work.rowMins[0] = 0

        var nodes: [Int] = []
        var depths: [Int] = []
        for child in trie.children(of: 0).reversed() {
            nodes.append(child)
            depths.append(1)
        }

        var budget = trie.nodeCount
        while let node = nodes.popLast() {
            budget -= 1
            if budget < 0 { break }
            let j = depths.removeLast()
            work.ensureDepth(j)
            let unit = trie.nodeUnit(node)
            let sub = work.substitutionRow(for: unit, depth: j)
            let prev = work.rows + (j - 1) * width
            let cur = work.rows + j * width
            let ins = unit == 0x27 || unit == 0x2D ? costs.apostropheInsertion : costs.insertion
            cur[0] = prev[0] + ins
            var rowMin = cur[0]
            if n > 0 {
                if j >= 2 {
                    let prev2 = work.rows + (j - 2) * width
                    let subPrev = work.substitutionRow(depth: j - 1)
                    for i in 1...n {
                        var v = prev[i - 1] + sub[i]
                        let a = prev[i] + ins
                        if a < v { v = a }
                        let d = cur[i - 1] + costs.deletion
                        if d < v { v = d }
                        if i >= 2 {
                            let t = prev2[i - 2] + costs.transposition + subPrev[i] + sub[i - 1]
                            if t < v { v = t }
                        }
                        cur[i] = v
                        if v < rowMin { rowMin = v }
                    }
                } else {
                    for i in 1...n {
                        var v = prev[i - 1] + sub[i]
                        let a = prev[i] + ins
                        if a < v { v = a }
                        let d = cur[i - 1] + costs.deletion
                        if d < v { v = d }
                        cur[i] = v
                        if v < rowMin { rowMin = v }
                    }
                }
            }
            work.rowMins[j] = rowMin

            let cost = cur[n]
            if cost <= bound {
                let values = trie.values(of: node)
                if !values.isEmpty {
                    for k in values {
                        let id = trie.value(at: k)
                        if id < trie.wordCount { results.offer(cost: cost, id: id) }
                    }
                    if results.isFull { bound = min(maxCost, results.worstCost) }
                }
            }

            if rowMin <= bound || work.rowMins[j - 1] + costs.transposition <= bound {
                for child in trie.children(of: node).reversed() {
                    nodes.append(child)
                    depths.append(j + 1)
                }
            }
        }
        return results.sorted()
    }
}

/// Scratch memory for one fuzzy search: one DP row per trie depth and memoised substitution rows
/// (`sub(i, unit)` for all taps i, indexed 1...n) for units of the Latin range.
private final class FuzzyWorkspace {
    private static let memoUnits = 0x250
    private let width: Int
    private let taps: [[(unit: UInt16, base: UInt16, cost: Double)]]
    private let costs: FuzzyCostModel
    private(set) var capacity: Int
    private(set) var rows: UnsafeMutablePointer<Double>
    private(set) var rowMins: UnsafeMutablePointer<Double>
    /// Substitution rows for units outside the memo range, one per depth.
    private var scratch: UnsafeMutablePointer<Double>
    /// Per depth: the memoised unit whose substitution row applies, or -1 for the scratch row.
    private var rowRef: UnsafeMutablePointer<Int>
    private let memo: UnsafeMutablePointer<Double>
    private let memoFilled: UnsafeMutablePointer<Bool>

    init(taps input: [TapInput], costs: FuzzyCostModel, initialDepth: Int) {
        width = input.count + 1
        self.costs = costs
        taps = input.map { tap in
            var best: [UInt16: Double] = [:]
            for c in tap.candidates where !c.cost.isNaN {
                guard let unit = LexiconKey.tapUnit(c.character) else { continue }
                best[unit] = min(best[unit] ?? .infinity, max(0, c.cost))
            }
            return best.sorted { $0.key < $1.key }.map { (unit: $0.key, base: LexiconKey.base($0.key), cost: $0.value) }
        }
        capacity = max(initialDepth, 8)
        rows = .allocate(capacity: capacity * width)
        rowMins = .allocate(capacity: capacity)
        scratch = .allocate(capacity: capacity * width)
        rowRef = .allocate(capacity: capacity)
        memo = .allocate(capacity: Self.memoUnits * width)
        memoFilled = .allocate(capacity: Self.memoUnits)
        memoFilled.initialize(repeating: false, count: Self.memoUnits)
    }

    deinit {
        rows.deallocate()
        rowMins.deallocate()
        scratch.deallocate()
        rowRef.deallocate()
        memo.deallocate()
        memoFilled.deallocate()
    }

    /// Makes room for rows 0...depth (pointers obtained earlier become invalid).
    func ensureDepth(_ depth: Int) {
        guard depth >= capacity else { return }
        let newCapacity = max(depth + 1, capacity * 2)
        func grow<P>(_ old: UnsafeMutablePointer<P>, _ oldCount: Int, _ newCount: Int) -> UnsafeMutablePointer<P> {
            let new = UnsafeMutablePointer<P>.allocate(capacity: newCount)
            new.moveInitialize(from: old, count: oldCount)
            old.deallocate()
            return new
        }
        rows = grow(rows, capacity * width, newCapacity * width)
        rowMins = grow(rowMins, capacity, newCapacity)
        scratch = grow(scratch, capacity * width, newCapacity * width)
        rowRef = grow(rowRef, capacity, newCapacity)
        capacity = newCapacity
    }

    /// Computes (or reuses) the substitution row of `unit` and records it for `depth`.
    func substitutionRow(for unit: UInt16, depth: Int) -> UnsafeMutablePointer<Double> {
        if Int(unit) < Self.memoUnits {
            let row = memo + Int(unit) * width
            if !memoFilled[Int(unit)] {
                fill(row, unit: unit)
                memoFilled[Int(unit)] = true
            }
            rowRef[depth] = Int(unit)
            return row
        }
        let row = scratch + depth * width
        fill(row, unit: unit)
        rowRef[depth] = -1
        return row
    }

    /// The substitution row recorded for `depth`.
    func substitutionRow(depth: Int) -> UnsafeMutablePointer<Double> {
        let ref = rowRef[depth]
        return ref >= 0 ? memo + ref * width : scratch + depth * width
    }

    private func fill(_ row: UnsafeMutablePointer<Double>, unit: UInt16) {
        let base = LexiconKey.base(unit)
        row[0] = 0
        for i in 1..<width {
            var best = costs.substitution
            for c in taps[i - 1] {
                if c.unit == unit {
                    best = min(best, c.cost)
                } else if c.base == base {
                    best = min(best, c.cost + costs.diacritic)
                }
            }
            row[i] = best
        }
    }
}

/// Bounded max-heap of fuzzy matches keeping the `limit` best by (cost, id).
private struct LexiconMatchHeap {
    private var items: [FuzzyMatch] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var isFull: Bool { items.count >= limit }
    var worstCost: Double { items.first?.cost ?? .infinity }

    @inline(__always)
    private static func worse(_ a: FuzzyMatch, _ b: FuzzyMatch) -> Bool {
        a.cost != b.cost ? a.cost > b.cost : a.id > b.id
    }

    mutating func offer(cost: Double, id: Int) {
        let match = FuzzyMatch(id: id, cost: cost)
        if items.count < limit {
            items.append(match)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard Self.worse(items[i], items[parent]) else { break }
                items.swapAt(i, parent)
                i = parent
            }
        } else if Self.worse(items[0], match) {
            items[0] = match
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, Self.worse(items[l], items[m]) { m = l }
                if r < items.count, Self.worse(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
    }

    func sorted() -> [FuzzyMatch] {
        items.sorted { Self.worse($1, $0) }
    }
}

/// Min-heap of packed UInt64 entries (used by the best-first completion search).
struct LexiconMinHeap {
    private var items: [UInt64] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ value: UInt64) {
        items.append(value)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i] < items[parent] else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> UInt64? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l] < items[m] { m = l }
                if r < items.count, items[r] < items[m] { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
