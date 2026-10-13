import Foundation

/// Writes `.kbdl` lexicons (ARCHITECTURE.md §3). Used by tests and to serialise user lexicons; the
/// bundled dictionaries are produced by `tools/build_dictionaries.py` with the same algorithm.
public enum LexiconBuilder {
    /// Builds a lexicon file.
    /// * Words are stored in NFC with their casing. Words whose lookup key is empty or contains non-BMP
    ///   characters are dropped; identical words are merged (max zipf). NaN frequencies count as 0.
    /// * Word ids follow descending zipf, ties in code point order.
    /// * Should a key have more than 255 casings or a node more than 255 children, the least frequent
    ///   words causing the overflow are dropped (never happens with real dictionaries).
    /// * Bigrams are attached to the most frequent casing of each side; pairs with an unknown word or
    ///   P < 2^-8 are dropped; duplicates keep the highest probability.
    public static func build(languageID: String, entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)] = []) -> Data {
        serialize(LexiconTables(languageID: languageID, entries: entries, bigrams: bigrams))
    }

    static func serialize(_ t: LexiconTables) -> Data {
        @inline(__always) func align4(_ x: Int) -> Int { (x + 3) & ~3 }
        let wordCount = t.words.count
        var blob: [UInt8] = []
        var wordOffsets: [UInt32] = [0]
        wordOffsets.reserveCapacity(wordCount + 1)
        for word in t.words {
            blob.append(contentsOf: word.utf8)
            wordOffsets.append(UInt32(blob.count))
        }
        let blobOffset = LexiconFormat.headerSize
        let wordOffsetsOffset = align4(blobOffset + blob.count)
        let zipfOffset = wordOffsetsOffset + (wordCount + 1) * 4
        let nodesOffset = align4(zipfOffset + wordCount)
        let valuesOffset = nodesOffset + t.nodes.count * LexiconFormat.nodeSize
        let bigramIndexOffset = valuesOffset + t.values.count * 4
        let bigramsOffset = bigramIndexOffset + (wordCount + 1) * 4
        let total = bigramsOffset + t.bigramEntries.count * 4

        var bytes = [UInt8](repeating: 0, count: total)
        bytes.withUnsafeMutableBytes { out in
            func put32(_ value: UInt32, _ offset: Int) { out.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self) }
            func put32(_ value: Int, _ offset: Int) { put32(UInt32(value), offset) }
            for (i, b) in LexiconFormat.magic.enumerated() { out[i] = b }
            put32(LexiconFormat.version, 4)
            put32(wordCount, 8)
            put32(t.nodes.count, 12)
            put32(t.values.count, 16)
            put32(t.bigramEntries.count, 20)
            put32(blobOffset, 24)
            put32(blob.count, 28)
            put32(wordOffsetsOffset, 32)
            put32(zipfOffset, 36)
            put32(nodesOffset, 40)
            put32(valuesOffset, 44)
            put32(bigramIndexOffset, 48)
            put32(bigramsOffset, 52)
            for (i, b) in t.languageID.utf8.prefix(LexiconFormat.languageIDSize).enumerated() {
                out[56 + i] = b < 0x80 ? b : UInt8(ascii: "?")
            }

            for (i, b) in blob.enumerated() { out[blobOffset + i] = b }
            for (i, o) in wordOffsets.enumerated() { put32(o, wordOffsetsOffset + i * 4) }
            for (i, z) in t.zipf.enumerated() { out[zipfOffset + i] = z }
            for (i, node) in t.nodes.enumerated() {
                let o = nodesOffset + i * LexiconFormat.nodeSize
                put32(node.firstChild, o)
                out.storeBytes(of: node.unit.littleEndian, toByteOffset: o + 4, as: UInt16.self)
                out[o + 6] = node.childCount
                out[o + 7] = node.maxZipf
                put32(node.valueRef, o + 8)
            }
            for (i, v) in t.values.enumerated() { put32(v, valuesOffset + i * 4) }
            for (i, v) in t.bigramIndex.enumerated() { put32(v, bigramIndexOffset + i * 4) }
            for (i, v) in t.bigramEntries.enumerated() { put32(v, bigramsOffset + i * 4) }
        }
        return Data(bytes)
    }
}

/// A word known to be in NFC, hashed and compared by its UTF-8 bytes (much faster than `String`'s
/// canonical-equivalence hashing for non-ASCII text, and equivalent for NFC strings).
private struct NFCWord: Hashable {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    static func == (a: NFCWord, b: NFCWord) -> Bool {
        a.string.utf8.count == b.string.utf8.count && a.string.utf8.elementsEqual(b.string.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var string = string
        string.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// One trie node with the fields of the 12-byte `.kbdl` node record.
struct LexiconNode: Hashable, Sendable {
    var firstChild: UInt32
    var unit: UInt16
    var childCount: UInt8
    var maxZipf: UInt8
    /// High 8 bits: number of word ids at this node; low 24 bits: start index into `values`.
    var valueRef: UInt32
}

/// All sections of a lexicon as Swift arrays. Built by `LexiconBuilder` (then serialised) and used
/// directly by `InMemoryLexicon`.
struct LexiconTables: TrieNodeAccess, Sendable {
    let languageID: String
    private(set) var words: [String] = []
    private(set) var zipf: [UInt8] = []
    private(set) var nodes: [LexiconNode] = []
    private(set) var values: [UInt32] = []
    private(set) var bigramIndex: [UInt32] = []
    private(set) var bigramEntries: [UInt32] = []

    init(languageID: String, entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)]) {
        self.languageID = languageID

        // Normalise, drop unusable words, merge duplicates (max zipf).
        // Keys are concatenated in `keyUnits`; items refer to them by range.
        var keyUnits: [UInt16] = []
        var items: [(word: String, zipf: Double, key: Range<Int>)] = []
        items.reserveCapacity(entries.count)
        var indexOfWord: [NFCWord: Int] = [:]
        indexOfWord.reserveCapacity(entries.count)
        for entry in entries {
            let word = NFCWord(LexiconKey.nfc(entry.word))
            let zipf = entry.zipf.isNaN ? 0 : entry.zipf
            if let i = indexOfWord[word] {
                items[i].zipf = max(items[i].zipf, zipf)
                continue
            }
            guard let key = LexiconKey.units(word.string), !key.isEmpty else { continue }
            indexOfWord[word] = items.count
            items.append((word.string, zipf, keyUnits.count..<(keyUnits.count + key.count)))
            keyUnits.append(contentsOf: key)
        }

        // Word ids: most frequent first, ties in code point (UTF-8 byte) order.
        items.sort { a, b in
            a.zipf != b.zipf ? a.zipf > b.zipf : a.word.utf8.lexicographicallyPrecedes(b.word.utf8)
        }
        if items.count > LexiconFormat.maxWordCount { items.removeLast(items.count - LexiconFormat.maxWordCount) }

        // Dropping the overflowing words cannot create a new overflow, so this normally runs twice at most.
        var dropped = layoutTrie(keyUnits: keyUnits, keys: items.map(\.key))
        while !dropped.isEmpty {
            var keep = [Bool](repeating: true, count: items.count)
            for id in dropped { keep[id] = false }
            items = items.indices.filter { keep[$0] }.map { items[$0] }
            dropped = layoutTrie(keyUnits: keyUnits, keys: items.map(\.key))
        }
        words = items.map(\.word)
        zipf = items.map { LexiconFormat.zipfByte($0.zipf) }
        computeMaxZipf()
        buildBigrams(bigrams)
    }

    /// Lays out the trie breadth-first for the keys `keyUnits[keys[id]]` and fills `nodes` and `values`.
    /// Returns the ids that exceed the format limits (more than 255 words per key or children per node:
    /// the least frequent are reported); the layout must then be redone without them.
    ///
    /// Works like an MSD radix sort: each node owns a contiguous range of `members` (the ids whose key
    /// starts with the node's path), sorted by (unit at the node's depth, id), so ids ending at the node
    /// come first (most frequent first) and every child's range is in id order again.
    private mutating func layoutTrie(keyUnits: [UInt16], keys: [Range<Int>]) -> [Int] {
        let count = keys.count
        var nodes = [LexiconNode(firstChild: 0, unit: 0, childCount: 0, maxZipf: 0, valueRef: 0)]
        nodes.reserveCapacity(count * 4)
        // Member range of each node; a node's depth follows from its breadth-first level.
        var spans: [(lo: UInt32, hi: UInt32)] = [(0, UInt32(count))]
        spans.reserveCapacity(count * 4)
        var values: [UInt32] = []
        values.reserveCapacity(count)
        var dropped: [Int] = []
        // members: word ids, reordered per node. sorted: (code << 32 | id) of the current node's members,
        // where code = 0 when the key ends at this depth, else unit + 1.
        let members = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: max(count, 1))
        let sorted = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: max(count, 1))
        defer {
            members.deallocate()
            sorted.deallocate()
        }
        for id in 0..<count { members[id] = UInt32(id) }

        keyUnits.withUnsafeBufferPointer { flat in
            keys.withUnsafeBufferPointer { keys in
                var depth = 0
                var levelEnd = 1
                var p = 0
                while p < nodes.count {
                    if p == levelEnd {
                        depth += 1
                        levelEnd = nodes.count
                    }
                    let lo = Int(spans[p].lo), n = Int(spans[p].hi) - lo
                    for k in 0..<n {
                        let id = Int(members[lo + k])
                        let key = keys[id]
                        let code: UInt64 = key.count == depth ? 0 : UInt64(flat[key.lowerBound + depth]) + 1
                        sorted[k] = code << 32 | UInt64(id)
                    }
                    if n > 1 {
                        var run = UnsafeMutableBufferPointer(rebasing: sorted[0..<n])
                        run.sort()
                        for k in 0..<n { members[lo + k] = UInt32(truncatingIfNeeded: sorted[k]) }
                    }

                    var k = 0
                    while k < n, sorted[k] >> 32 == 0 { k += 1 }
                    if k > 0 {
                        let stored = min(k, LexiconFormat.maxWordsPerKey)
                        nodes[p].valueRef = UInt32(stored) << 24 | UInt32(values.count)
                        values.append(contentsOf: members[lo..<(lo + stored)])
                        if stored < k { dropped.append(contentsOf: members[(lo + stored)..<(lo + k)].map(Int.init)) }
                    }

                    // Children: runs of equal codes, in unit order.
                    let firstChild = nodes.count
                    while k < n {
                        let code = sorted[k] >> 32
                        let start = k
                        k += 1
                        while k < n, sorted[k] >> 32 == code { k += 1 }
                        nodes.append(LexiconNode(firstChild: 0, unit: UInt16(code - 1), childCount: 0, maxZipf: 0, valueRef: 0))
                        spans.append((UInt32(lo + start), UInt32(lo + k)))
                    }
                    let childCount = nodes.count - firstChild
                    if childCount > LexiconFormat.maxChildren {
                        // Keep the children holding the most frequent words (each range starts with its smallest id).
                        let ranked = (firstChild..<nodes.count).map { (node: nodes[$0], span: spans[$0]) }
                            .sorted { members[Int($0.span.lo)] < members[Int($1.span.lo)] }
                        nodes.removeLast(childCount)
                        spans.removeLast(childCount)
                        for c in ranked.dropFirst(LexiconFormat.maxChildren) {
                            dropped.append(contentsOf: members[Int(c.span.lo)..<Int(c.span.hi)].map(Int.init))
                        }
                        for c in ranked.prefix(LexiconFormat.maxChildren).sorted(by: { $0.node.unit < $1.node.unit }) {
                            nodes.append(c.node)
                            spans.append(c.span)
                        }
                    }
                    if nodes.count > firstChild {
                        nodes[p].firstChild = UInt32(firstChild)
                        nodes[p].childCount = UInt8(nodes.count - firstChild)
                    }
                    p += 1
                }
            }
        }
        self.nodes = nodes
        self.values = values
        return dropped
    }

    private mutating func computeMaxZipf() {
        // Children follow their parent, so a reverse pass sees every subtree before its root.
        for p in stride(from: nodes.count - 1, through: 0, by: -1) {
            var m: UInt8 = 0
            for k in values(of: p) { m = max(m, zipf[Int(values[k])]) }
            for c in children(of: p) { m = max(m, nodes[c].maxZipf) }
            nodes[p].maxZipf = m
        }
    }

    private mutating func buildBigrams(_ bigrams: [(previous: String, next: String, log2Prob: Double)]) {
        func canonicalID(_ word: String) -> Int? {
            guard let units = LexiconKey.units(word), let node = TrieSearch.findNode(self, units: units) else { return nil }
            return TrieSearch.ids(self, at: node).first
        }
        var best: [UInt64: UInt8] = [:]
        for b in bigrams {
            guard let score = LexiconFormat.bigramScore(log2Prob: b.log2Prob),
                  let prev = canonicalID(b.previous), let next = canonicalID(b.next) else { continue }
            let pair = UInt64(prev) << 32 | UInt64(next)
            best[pair] = max(best[pair] ?? 0, score)
        }
        let sorted = best.map { (prev: Int($0.key >> 32), next: UInt32($0.key & 0xFFFF_FFFF), score: $0.value) }
            .sorted { a, b in
                if a.prev != b.prev { return a.prev < b.prev }
                if a.score != b.score { return a.score > b.score }
                return a.next < b.next
            }
        bigramEntries = sorted.map { $0.next | UInt32($0.score) << 24 }
        bigramIndex = [UInt32](repeating: 0, count: words.count + 1)
        var k = 0
        for id in 0...words.count {
            while k < sorted.count, sorted[k].prev < id { k += 1 }
            bigramIndex[id] = UInt32(k)
        }
    }

    // MARK: TrieNodeAccess

    var wordCount: Int { words.count }
    var nodeCount: Int { nodes.count }
    var valueCount: Int { values.count }
    var bigramCount: Int { bigramEntries.count }
    func nodeFirstChild(_ node: Int) -> Int { Int(nodes[node].firstChild) }
    func nodeUnit(_ node: Int) -> UInt16 { nodes[node].unit }
    func nodeChildCount(_ node: Int) -> Int { Int(nodes[node].childCount) }
    func nodeMaxZipf(_ node: Int) -> UInt8 { nodes[node].maxZipf }
    func nodeValueRef(_ node: Int) -> UInt32 { nodes[node].valueRef }
    func value(at index: Int) -> Int { Int(values[index]) }
    func zipfByte(_ id: Int) -> UInt8 { zipf[id] }
    func bigramStart(_ id: Int) -> Int { Int(bigramIndex[id]) }
    func bigramEntry(_ index: Int) -> UInt32 { bigramEntries[index] }
}
