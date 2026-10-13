import Foundation

/// Writes `.kbdl` lexicons (ARCHITECTURE.md §3). Used by tests and to serialise user lexicons; the
/// bundled dictionaries are produced by `tools/build_dictionaries.py` with the same algorithm.
public enum LexiconBuilder {
    /// Builds a lexicon file.
    /// * Words are stored in NFC with their casing. Words whose lookup key is empty or contains non-BMP
    ///   characters are dropped; identical words are merged (max zipf).
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
        var _t = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) { let n = DispatchTime.now().uptimeNanoseconds; print("  [phase] \(name): \(Double(n - _t) / 1e6) ms"); _t = n }

        // Normalise, drop unusable words, merge duplicates.
        var items: [(word: String, zipf: Double, key: [UInt16])] = []
        items.reserveCapacity(entries.count)
        var indexOfWord: [String: Int] = [:]
        indexOfWord.reserveCapacity(entries.count)
        for entry in entries {
            let word = LexiconKey.nfc(entry.word)
            let zipf = entry.zipf.isNaN ? 0 : entry.zipf
            if let i = indexOfWord[word] {
                items[i].zipf = max(items[i].zipf, zipf)
                continue
            }
            guard let key = LexiconKey.units(word), !key.isEmpty else { continue }
            indexOfWord[word] = items.count
            items.append((word, zipf, key))
        }

        lap("normalise")
        // Word ids: most frequent first, ties in code point (UTF-8 byte) order.
        items.sort { a, b in
            a.zipf != b.zipf ? a.zipf > b.zipf : a.word.utf8.lexicographicallyPrecedes(b.word.utf8)
        }
        if items.count > LexiconFormat.maxWordCount { items.removeLast(items.count - LexiconFormat.maxWordCount) }
        zipf = items.map { LexiconFormat.zipfByte($0.zipf) }
        lap("sort words")

        while true {
            let dropped = layoutTrie(keys: items.map(\.key))
            if dropped.isEmpty { break }
            let drop = Set(dropped)
            items = items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            zipf = items.map { LexiconFormat.zipfByte($0.zipf) }
        }
        lap("layout")
        words = items.map(\.word)
        computeMaxZipf()
        lap("maxZipf")
        buildBigrams(bigrams)
        lap("bigrams")
    }

    /// Lays out the trie breadth-first. Returns the ids that must be dropped (node limits exceeded)
    /// without finishing the layout, or [] on success.
    private mutating func layoutTrie(keys: [[UInt16]]) -> [Int] {
        // Flatten keys so sorting compares raw buffers.
        var flat: [UInt16] = []
        flat.reserveCapacity(keys.reduce(0) { $0 + $1.count })
        var starts: [Int] = []
        starts.reserveCapacity(keys.count + 1)
        for key in keys {
            starts.append(flat.count)
            flat.append(contentsOf: key)
        }
        starts.append(flat.count)

        // Ids sorted by key (UTF-16 unit order), then id; group equal keys.
        var order = Array(0..<keys.count)
        var groupStart: [Int] = []
        flat.withUnsafeBufferPointer { f in
            starts.withUnsafeBufferPointer { s in
                func compare(_ a: Int, _ b: Int) -> Int {
                    var i = s[a], k = s[b]
                    let ea = s[a + 1], eb = s[b + 1]
                    while i < ea, k < eb {
                        if f[i] != f[k] { return f[i] < f[k] ? -1 : 1 }
                        i += 1
                        k += 1
                    }
                    return (ea - i) - (eb - k)
                }
                order.sort { a, b in
                    let c = compare(a, b)
                    return c != 0 ? c < 0 : a < b
                }
                for (i, id) in order.enumerated() where i == 0 || compare(order[i - 1], id) != 0 {
                    groupStart.append(i)
                }
            }
        }
        groupStart.append(order.count)
        let groupCount = groupStart.count - 1

        var dropped: [Int] = []
        for g in 0..<groupCount where groupStart[g + 1] - groupStart[g] > LexiconFormat.maxWordsPerKey {
            dropped.append(contentsOf: order[(groupStart[g] + LexiconFormat.maxWordsPerKey)..<groupStart[g + 1]])
        }
        if !dropped.isEmpty { return dropped }

        // Breadth-first: node p covers key groups lo..<hi sharing a prefix of length depth.
        @inline(__always) func keyLength(_ g: Int) -> Int { let id = order[groupStart[g]]; return starts[id + 1] - starts[id] }
        @inline(__always) func unit(_ g: Int, _ depth: Int) -> UInt16 { flat[starts[order[groupStart[g]]] + depth] }
        nodes = [LexiconNode(firstChild: 0, unit: 0, childCount: 0, maxZipf: 0, valueRef: 0)]
        values = []
        values.reserveCapacity(order.count)
        var ranges: [(lo: Int, hi: Int, depth: Int)] = [(0, groupCount, 0)]
        var children: [(unit: UInt16, lo: Int, hi: Int)] = []
        var p = 0
        while p < nodes.count {
            let (lo, hi, depth) = ranges[p]
            var g = lo
            if g < hi, keyLength(g) == depth {
                let count = groupStart[g + 1] - groupStart[g]
                nodes[p].valueRef = UInt32(count) << 24 | UInt32(values.count)
                for k in groupStart[g]..<groupStart[g + 1] { values.append(UInt32(order[k])) }
                g += 1
            }
            children.removeAll(keepingCapacity: true)
            while g < hi {
                let u = unit(g, depth)
                var end = g + 1
                while end < hi, unit(end, depth) == u { end += 1 }
                children.append((u, g, end))
                g = end
            }
            if children.count > LexiconFormat.maxChildren {
                // Keep the children holding the most frequent words (smallest ids).
                func minID(_ c: (unit: UInt16, lo: Int, hi: Int)) -> Int {
                    (c.lo..<c.hi).map { order[groupStart[$0]] }.min() ?? Int.max
                }
                for c in children.sorted(by: { minID($0) < minID($1) }).dropFirst(LexiconFormat.maxChildren) {
                    dropped.append(contentsOf: order[groupStart[c.lo]..<groupStart[c.hi]])
                }
                return dropped
            }
            if !children.isEmpty {
                nodes[p].firstChild = UInt32(nodes.count)
                nodes[p].childCount = UInt8(children.count)
                for c in children {
                    nodes.append(LexiconNode(firstChild: 0, unit: c.unit, childCount: 0, maxZipf: 0, valueRef: 0))
                    ranges.append((c.lo, c.hi, depth + 1))
                }
            }
            p += 1
        }
        return []
    }

    private mutating func computeMaxZipf() {
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
