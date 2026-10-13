import Foundation

/// A `.kbdl` lexicon read directly from (memory-mapped) data. Nothing is copied or decoded up front:
/// opening only checks the header, words are decoded from the UTF-8 blob on demand. All reads are
/// bounds-safe for any file that passes the header check, so a damaged file can give wrong results but
/// cannot crash the keyboard (use `LexiconFormat.validate` for a full check).
public final class BinaryLexicon: WordLexicon, Sendable {
    public let languageID: String
    public let wordCount: Int
    /// Size of the underlying data in bytes.
    public let byteCount: Int
    private let data: Data
    private let header: LexiconHeader

    public init(data: Data) throws {
        header = try data.withUnsafeBytes { try LexiconHeader($0) }
        self.data = data
        languageID = header.languageID
        wordCount = header.wordCount
        byteCount = data.count
    }

    /// Opens a lexicon file memory-mapped.
    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    @inline(__always)
    private func withTrie<R>(_ body: (BinaryTrieView) -> R) -> R {
        data.withUnsafeBytes { body(BinaryTrieView(raw: $0, header: header)) }
    }

    public func word(_ id: Int) -> String {
        guard id >= 0, id < wordCount else { return "" }
        return withTrie { $0.word(id) }
    }

    public func zipf(_ id: Int) -> Double {
        guard id >= 0, id < wordCount else { return 0 }
        return withTrie { LexiconFormat.zipf(fromByte: $0.zipfByte(id)) }
    }

    public func lookup(key: String) -> [Int] {
        withTrie { TrieSearch.lookup($0, key: key) }
    }

    public func completions(prefix: String, limit: Int) -> [Int] {
        withTrie { TrieSearch.completions($0, prefix: prefix, limit: limit) }
    }

    public func fuzzySearch(taps: [TapInput], costs: FuzzyCostModel, maxCost: Double, limit: Int) -> [FuzzyMatch] {
        withTrie { TrieSearch.fuzzySearch($0, taps: taps, costs: costs, maxCost: maxCost, limit: limit) }
    }

    /// Bigram successors of `id`. Bigrams are stored under the most frequent casing of a key, so for
    /// another casing ("Essen") the successors of the key's main form ("essen") are returned.
    public func successors(of id: Int, limit: Int) -> [(id: Int, log2Prob: Double)] {
        withTrie { t in
            let direct = TrieSearch.successors(t, of: id, limit: limit)
            guard direct.isEmpty, id >= 0, id < wordCount,
                  let main = TrieSearch.lookup(t, key: t.word(id)).first, main != id else { return direct }
            return TrieSearch.successors(t, of: main, limit: limit)
        }
    }

    public func topWords(limit: Int) -> [Int] {
        withTrie { TrieSearch.topWords($0, limit: limit) }
    }
}

/// Unaligned little-endian reads of the `.kbdl` sections inside a buffer whose header was checked.
struct BinaryTrieView: TrieNodeAccess {
    let raw: UnsafeRawBufferPointer
    let header: LexiconHeader

    var wordCount: Int { header.wordCount }
    var nodeCount: Int { header.nodeCount }
    var valueCount: Int { header.valueCount }
    var bigramCount: Int { header.bigramCount }

    @inline(__always)
    private func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    private func nodeOffset(_ node: Int) -> Int {
        header.nodesOffset + node * LexiconFormat.nodeSize
    }

    func nodeFirstChild(_ node: Int) -> Int { Int(u32(nodeOffset(node))) }
    func nodeUnit(_ node: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: nodeOffset(node) + 4, as: UInt16.self))
    }
    func nodeChildCount(_ node: Int) -> Int { Int(raw[nodeOffset(node) + 6]) }
    func nodeMaxZipf(_ node: Int) -> UInt8 { raw[nodeOffset(node) + 7] }
    func nodeValueRef(_ node: Int) -> UInt32 { u32(nodeOffset(node) + 8) }
    func value(at index: Int) -> Int { Int(u32(header.valuesOffset + index * 4)) }
    func zipfByte(_ id: Int) -> UInt8 { raw[header.zipfOffset + id] }
    func bigramStart(_ id: Int) -> Int { Int(u32(header.bigramIndexOffset + id * 4)) }
    func bigramEntry(_ index: Int) -> UInt32 { u32(header.bigramsOffset + index * 4) }

    /// Blob offset of word `id` (0...wordCount), clamped to the blob.
    func wordOffset(_ id: Int) -> Int {
        min(Int(u32(header.wordOffsetsOffset + id * 4)), header.blobSize)
    }

    /// Decodes word `id` (0..<wordCount) from the blob.
    func word(_ id: Int) -> String {
        let start = wordOffset(id), end = wordOffset(id + 1)
        guard start < end else { return "" }
        let base = header.blobOffset
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[(base + start)..<(base + end)]), as: UTF8.self)
    }
}
