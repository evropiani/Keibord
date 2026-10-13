import Foundation

/// Errors thrown when opening or validating a `.kbdl` lexicon.
public enum LexiconError: Error, Equatable, CustomStringConvertible {
    /// The data is shorter than the 64-byte header.
    case truncated
    /// The file does not start with "KBDL".
    case badMagic
    case unsupportedVersion(UInt32)
    /// A section offset is not 4-byte aligned, overlaps the header or extends past the end of the file.
    case invalidSection(String)
    /// A structural inconsistency (found by the header check or `LexiconFormat.validate`).
    case corrupt(String)

    public var description: String {
        switch self {
        case .truncated: return "Lexicon file is shorter than its header"
        case .badMagic: return "Not a Keibord lexicon (bad magic)"
        case .unsupportedVersion(let v): return "Unsupported lexicon version \(v)"
        case .invalidSection(let s): return "Invalid lexicon section: \(s)"
        case .corrupt(let s): return "Corrupt lexicon: \(s)"
        }
    }
}

/// Summary of a lexicon file returned by `LexiconFormat.validate`.
public struct LexiconStats: Hashable, Sendable {
    public var languageID: String
    public var fileSize: Int
    public var wordCount: Int
    public var nodeCount: Int
    public var valueCount: Int
    public var bigramCount: Int
    public var blobSize: Int
    /// Length of the longest lookup key in UTF-16 units (= trie depth).
    public var maxKeyLength: Int
    /// Words whose trie path differs from `TextUnits.lookupKey(word)` (nil when not checked).
    public var mismatchedKeys: Int?

    public init(languageID: String, fileSize: Int, wordCount: Int, nodeCount: Int, valueCount: Int, bigramCount: Int, blobSize: Int, maxKeyLength: Int, mismatchedKeys: Int? = nil) {
        self.languageID = languageID
        self.fileSize = fileSize
        self.wordCount = wordCount
        self.nodeCount = nodeCount
        self.valueCount = valueCount
        self.bigramCount = bigramCount
        self.blobSize = blobSize
        self.maxKeyLength = maxKeyLength
        self.mismatchedKeys = mismatchedKeys
    }
}

/// Constants and helpers of the binary lexicon format `.kbdl` version 1 (ARCHITECTURE.md §3).
public enum LexiconFormat {
    /// "KBDL"
    public static let magic: [UInt8] = [0x4B, 0x42, 0x44, 0x4C]
    public static let version: UInt32 = 1
    public static let headerSize = 64
    public static let nodeSize = 12
    /// Bytes reserved for the NUL-padded ASCII dictionary id in the header.
    public static let languageIDSize = 8
    /// `childCount` is a UInt8.
    public static let maxChildren = 255
    /// The high 8 bits of `valueRef` hold the number of word ids per node.
    public static let maxWordsPerKey = 255
    /// Word ids (in values and bigram entries) and value indices are 24-bit.
    public static let maxWordCount = 1 << 24

    /// Zipf frequency → stored byte: `round(zipf × 32)` clamped to 0…255.
    public static func zipfByte(_ zipf: Double) -> UInt8 {
        guard !zipf.isNaN else { return 0 }
        return UInt8(min(255, max(0, (zipf * 32).rounded(.toNearestOrEven))))
    }

    public static func zipf(fromByte byte: UInt8) -> Double {
        Double(byte) / 32
    }

    /// log2 P(next | previous) → stored bigram score `round(255 + 32 × log2P)` clamped to 0…255,
    /// or nil when the pair is dropped (P < 2^-8 or NaN).
    public static func bigramScore(log2Prob: Double) -> UInt8? {
        guard !log2Prob.isNaN, log2Prob >= -8 else { return nil }
        return UInt8(min(255, max(0, (255 + 32 * log2Prob).rounded(.toNearestOrEven))))
    }

    public static func log2Prob(fromScore score: UInt8) -> Double {
        (Double(score) - 255) / 32
    }

    /// Full structural check of a `.kbdl` file (diagnostics and tests; `BinaryLexicon` itself only checks
    /// the header so opening stays cheap). Verifies the header, word offsets and UTF-8, frequency order,
    /// the breadth-first tree shape, sorted children, value references (every word stored exactly once),
    /// `maxZipf` and the bigram tables. With `checkWordKeys` it also counts words whose trie path is not
    /// their lookup key (`LexiconStats.mismatchedKeys`) instead of failing, so tooling can report drift
    /// between writers.
    public static func validate(_ data: Data, checkWordKeys: Bool = true) throws -> LexiconStats {
        try data.withUnsafeBytes { raw in
            try validate(raw: raw, checkWordKeys: checkWordKeys)
        }
    }

    private static func validate(raw: UnsafeRawBufferPointer, checkWordKeys: Bool) throws -> LexiconStats {
        let h = try LexiconHeader(raw)
        let t = BinaryTrieView(raw: raw, header: h)

        // Words: monotone offsets inside the blob, non-empty, valid UTF-8; zipf non-increasing by id.
        var previousEnd = t.wordOffset(0)
        for id in 0..<h.wordCount {
            let start = previousEnd, end = t.wordOffset(id + 1)
            guard start <= end, end <= h.blobSize else { throw LexiconError.corrupt("word offsets of word \(id) out of order") }
            guard start < end else { throw LexiconError.corrupt("word \(id) is empty") }
            let bytes = UnsafeRawBufferPointer(rebasing: raw[(h.blobOffset + start)..<(h.blobOffset + end)])
            let invalid = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF32.self, stoppingOnError: true, into: { _ in })
            guard !invalid else { throw LexiconError.corrupt("word \(id) is not valid UTF-8") }
            if id > 0, t.zipfByte(id) > t.zipfByte(id - 1) { throw LexiconError.corrupt("word ids are not ordered by frequency at \(id)") }
            previousEnd = end
        }

        // Tree: breadth-first, every node except the root is the child of exactly one earlier node.
        var parent = [Int32](repeating: -1, count: h.nodeCount)
        var depth = [Int32](repeating: 0, count: h.nodeCount)
        var nodeOfWord = [Int32](repeating: -1, count: h.wordCount)
        var nextChild = 1
        var maxDepth = 0
        for p in 0..<h.nodeCount {
            let count = t.nodeChildCount(p)
            if count > 0 {
                let first = t.nodeFirstChild(p)
                guard first == nextChild, first + count <= h.nodeCount else {
                    throw LexiconError.corrupt("children of node \(p) are not in breadth-first order")
                }
                for c in first..<(first + count) {
                    if c > first, t.nodeUnit(c) <= t.nodeUnit(c - 1) {
                        throw LexiconError.corrupt("children of node \(p) are not sorted")
                    }
                    parent[c] = Int32(p)
                    depth[c] = depth[p] + 1
                    maxDepth = max(maxDepth, Int(depth[c]))
                }
                nextChild += count
            }
            let ref = t.nodeValueRef(p)
            let valueCount = Int(ref >> 24), start = Int(ref & 0xFF_FFFF)
            guard start + valueCount <= h.valueCount else { throw LexiconError.corrupt("values of node \(p) out of bounds") }
            if valueCount > 0, p == 0 { throw LexiconError.corrupt("root node stores words") }
            for k in start..<(start + valueCount) {
                let id = t.value(at: k)
                guard id < h.wordCount else { throw LexiconError.corrupt("node \(p) references unknown word \(id)") }
                guard nodeOfWord[id] < 0 else { throw LexiconError.corrupt("word \(id) is stored twice") }
                if k > start, t.zipfByte(id) > t.zipfByte(t.value(at: k - 1)) {
                    throw LexiconError.corrupt("values of node \(p) are not ordered by frequency")
                }
                nodeOfWord[id] = Int32(p)
            }
        }
        guard nextChild == h.nodeCount else { throw LexiconError.corrupt("unreachable nodes") }
        if let missing = nodeOfWord.firstIndex(of: -1) { throw LexiconError.corrupt("word \(missing) is not in the trie") }

        // maxZipf must be the exact maximum over the subtree (children follow their parent).
        var subtreeMax = [UInt8](repeating: 0, count: h.nodeCount)
        for p in stride(from: h.nodeCount - 1, through: 0, by: -1) {
            var m: UInt8 = 0
            for k in t.values(of: p) { m = max(m, t.zipfByte(t.value(at: k))) }
            for c in t.children(of: p) { m = max(m, subtreeMax[c]) }
            subtreeMax[p] = m
            guard t.nodeMaxZipf(p) == m else { throw LexiconError.corrupt("maxZipf of node \(p) is \(t.nodeMaxZipf(p)), expected \(m)") }
        }

        // Bigrams: monotone index, known successor ids, scores non-increasing per word.
        guard t.bigramStart(h.wordCount) == h.bigramCount else { throw LexiconError.corrupt("bigram index does not cover all entries") }
        for id in 0..<h.wordCount {
            let start = t.bigramStart(id), end = t.bigramStart(id + 1)
            guard start <= end, end <= h.bigramCount else { throw LexiconError.corrupt("bigram index not monotone at \(id)") }
            var previousScore = UInt32.max
            for k in start..<end {
                let entry = t.bigramEntry(k)
                guard Int(entry & 0xFF_FFFF) < h.wordCount else { throw LexiconError.corrupt("bigram of word \(id) references an unknown word") }
                guard entry >> 24 <= previousScore else { throw LexiconError.corrupt("bigrams of word \(id) are not sorted by score") }
                previousScore = entry >> 24
            }
        }

        var mismatched: Int?
        if checkWordKeys {
            var count = 0
            var path: [UInt16] = []
            for id in 0..<h.wordCount {
                path.removeAll(keepingCapacity: true)
                var node = Int(nodeOfWord[id])
                while node > 0 {
                    path.append(t.nodeUnit(node))
                    node = Int(parent[node])
                }
                path.reverse()
                if LexiconKey.units(t.word(id)) != path { count += 1 }
            }
            mismatched = count
        }

        return LexiconStats(languageID: h.languageID, fileSize: raw.count, wordCount: h.wordCount, nodeCount: h.nodeCount,
                            valueCount: h.valueCount, bigramCount: h.bigramCount, blobSize: h.blobSize,
                            maxKeyLength: maxDepth, mismatchedKeys: mismatched)
    }
}

/// Parsed and bounds-checked `.kbdl` header. After a successful parse, every section the header
/// declares lies inside the buffer, so `BinaryTrieView` reads with in-range indices are memory-safe.
struct LexiconHeader: Sendable {
    let wordCount: Int
    let nodeCount: Int
    let valueCount: Int
    let bigramCount: Int
    let blobOffset: Int
    let blobSize: Int
    let wordOffsetsOffset: Int
    let zipfOffset: Int
    let nodesOffset: Int
    let valuesOffset: Int
    let bigramIndexOffset: Int
    let bigramsOffset: Int
    let languageID: String

    init(_ raw: UnsafeRawBufferPointer) throws {
        guard raw.count >= LexiconFormat.headerSize else { throw LexiconError.truncated }
        guard raw.prefix(4).elementsEqual(LexiconFormat.magic) else { throw LexiconError.badMagic }
        func u32(_ offset: Int) -> Int {
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
        let version = UInt32(u32(4))
        guard version == LexiconFormat.version else { throw LexiconError.unsupportedVersion(version) }
        wordCount = u32(8)
        nodeCount = u32(12)
        valueCount = u32(16)
        bigramCount = u32(20)
        blobOffset = u32(24)
        blobSize = u32(28)
        wordOffsetsOffset = u32(32)
        zipfOffset = u32(36)
        nodesOffset = u32(40)
        valuesOffset = u32(44)
        bigramIndexOffset = u32(48)
        bigramsOffset = u32(52)
        let idBytes = raw[56..<(56 + LexiconFormat.languageIDSize)].prefix { $0 != 0 }
        languageID = String(decoding: idBytes, as: UTF8.self)

        // Offsets and counts are < 2^32, so these products cannot overflow a 64-bit Int.
        let sections: [(String, Int, Int)] = [
            ("blob", blobOffset, blobSize),
            ("wordOffsets", wordOffsetsOffset, (wordCount + 1) * 4),
            ("zipf", zipfOffset, wordCount),
            ("nodes", nodesOffset, nodeCount * LexiconFormat.nodeSize),
            ("values", valuesOffset, valueCount * 4),
            ("bigramIndex", bigramIndexOffset, (wordCount + 1) * 4),
            ("bigrams", bigramsOffset, bigramCount * 4),
        ]
        for (name, offset, length) in sections {
            guard offset % 4 == 0 else { throw LexiconError.invalidSection("\(name) is not 4-byte aligned") }
            guard length == 0 || offset >= LexiconFormat.headerSize else { throw LexiconError.invalidSection("\(name) overlaps the header") }
            guard offset + length <= raw.count else { throw LexiconError.invalidSection("\(name) extends past the end of the file") }
        }
        guard nodeCount >= 1 else { throw LexiconError.corrupt("missing root node") }
        guard u32(wordOffsetsOffset + wordCount * 4) <= blobSize else { throw LexiconError.corrupt("word offsets exceed the blob") }
        guard u32(bigramIndexOffset + wordCount * 4) <= bigramCount else { throw LexiconError.corrupt("bigram index exceeds the entries") }
    }
}
