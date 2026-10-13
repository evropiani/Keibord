#!/usr/bin/env python3
"""Writer and reader for Keibord's binary lexicon format `.kbdl` (version 1).

The format is specified byte-exactly in docs/ARCHITECTURE.md section 3. In short (little-endian,
all section offsets absolute and 4-byte aligned):

    Header (64 bytes): "KBDL", version, wordCount, nodeCount, valueCount, bigramCount,
                       blobOffset, blobSize, wordOffsets, zipfOffset, nodesOffset,
                       valuesOffset, bigramIndex, bigramOffset, langID (8 bytes ASCII, NUL padded)
    Node (12 bytes):   firstChild u32, char u16, childCount u8, maxZipf u8, valueRef u32
                       (valueRef: high 8 bits = number of ids, low 24 bits = start in values)

Words are stored with their dictionary casing; ids are assigned by descending frequency. The trie
is keyed by `lookup_key(word)` (NFC, lower-case, typographic apostrophe -> "'"), nodes are laid
out breadth-first with children sorted by UTF-16 code unit.

Usable as a module (`build`, `Lexicon`) or from the command line:

    python3 tools/kbdl.py info Resources/Dictionaries/de-AT.kbdl
    python3 tools/kbdl.py lookup Resources/Dictionaries/de-AT.kbdl haus
    python3 tools/kbdl.py complete Resources/Dictionaries/de-AT.kbdl schö
"""

from __future__ import annotations

import heapq
import math
import struct
import sys
import unicodedata
from array import array
from typing import Iterable, Sequence

MAGIC = b"KBDL"
VERSION = 1
HEADER_SIZE = 64
NODE_SIZE = 12
LANG_ID_SIZE = 8
MAX_IDS_PER_NODE = 255
MAX_CHILDREN = 255
MAX_WORD_ID = (1 << 24) - 1

_HEADER = struct.Struct("<4s13I8s")
_NODE = struct.Struct("<IHBBI")

assert _HEADER.size == HEADER_SIZE
assert _NODE.size == NODE_SIZE


class KbdlError(ValueError):
    """Raised for invalid input to the writer or a malformed file in the reader."""


# ---------------------------------------------------------------------------------------------
# Shared helpers (must match the Swift implementation)
# ---------------------------------------------------------------------------------------------

def lookup_key(word: str) -> str:
    """Mirror of `TextUnits.lookupKey`: NFC, lower-case, U+2019 -> "'"."""
    return unicodedata.normalize("NFC", word).lower().replace("\u2019", "'")


def _round_half_away(x: float) -> int:
    """Swift's `rounded()` (schoolbook rounding), not Python's banker's rounding."""
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def zipf_byte(zipf: float) -> int:
    """zipf byte = round(zipf * 32) clamped to 0...255."""
    return max(0, min(255, _round_half_away(zipf * 32)))


def zipf_from_byte(b: int) -> float:
    return b / 32.0


def bigram_score(log2_prob: float) -> int:
    """score = clamp(round(255 + 32 * log2 P), 0, 255)."""
    return max(0, min(255, _round_half_away(255 + 32 * log2_prob)))


def log2_prob_from_score(score: int) -> float:
    return (score - 255) / 32.0


def _align4(n: int) -> int:
    return (n + 3) & ~3


def _is_bmp_key(key: str) -> bool:
    # Every key character must be a single UTF-16 code unit (no surrogates, no astral planes).
    return all(ord(c) < 0xD800 or 0xE000 <= ord(c) <= 0xFFFF for c in key)


def _u32_array(values: Iterable[int]) -> bytes:
    a = array("I", values)
    if a.itemsize != 4:  # pragma: no cover - every supported platform has 4-byte unsigned int
        raise RuntimeError("array('I') is not 32-bit on this platform")
    if sys.byteorder == "big":  # pragma: no cover
        a.byteswap()
    return a.tobytes()


def _read_u32_array(data: bytes, offset: int, count: int) -> array:
    a = array("I")
    a.frombytes(data[offset:offset + 4 * count])
    if sys.byteorder == "big":  # pragma: no cover
        a.byteswap()
    return a


# ---------------------------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------------------------

def build(language_id: str,
          entries: Iterable[tuple[str, float]],
          bigrams: Iterable[tuple[str, str, float]] = ()) -> bytes:
    """Serialises a lexicon to `.kbdl` bytes.

    * `entries`: (word, zipf). Words are ordered by descending zipf; ties keep the input order,
      so pass entries in a deterministic order. A word listed twice keeps its highest zipf.
      Words whose lookup key is empty or contains non-BMP characters are dropped.
    * `bigrams`: (previous, next, log2 P(next | previous)). Each side is mapped to the id of the
      most frequent word with the same lookup key; pairs with an unknown side or P < 2^-8 are
      dropped; duplicates keep the highest probability.

    The output is deterministic: the same input sequence always produces identical bytes.
    """
    lang = language_id.encode("ascii")
    if not lang or len(lang) > LANG_ID_SIZE or b"\0" in lang:
        raise KbdlError(f"language id must be 1...{LANG_ID_SIZE} ASCII characters: {language_id!r}")

    # Deduplicate (keep max zipf, first position) and order by zipf descending (stable).
    best: dict[str, tuple[float, int]] = {}
    for position, (word, zipf) in enumerate(entries):
        if not isinstance(word, str) or not word:
            continue
        zipf = float(zipf)
        if math.isnan(zipf):
            raise KbdlError(f"zipf is NaN for {word!r}")
        key = lookup_key(word)
        if not key or not _is_bmp_key(key):
            continue
        previous = best.get(word)
        if previous is None:
            best[word] = (zipf, position)
        elif zipf > previous[0]:
            best[word] = (zipf, previous[1])
    ordered = sorted(best.items(), key=lambda item: (-item[1][0], item[1][1]))
    words = [w for w, _ in ordered]
    zipfs = [z for _, (z, _) in ordered]
    word_count = len(words)
    if word_count > MAX_WORD_ID:
        raise KbdlError(f"too many words: {word_count}")
    zbytes = bytes(zipf_byte(z) for z in zipfs)

    # Trie: node = [children dict char -> node, ids list]
    root: list = [{}, []]
    keys = [lookup_key(w) for w in words]
    for word_id, key in enumerate(keys):
        node = root
        for ch in key:
            child = node[0].get(ch)
            if child is None:
                child = [{}, []]
                node[0][ch] = child
            node = child
        node[1].append(word_id)  # ids arrive ascending = most frequent first

    # Breadth-first layout. Children of each node are contiguous and sorted by UTF-16 unit
    # (all key characters are BMP, so the code point order equals the UTF-16 order).
    order: list[list] = [root]
    chars: list[int] = [0]
    first_child: list[int] = []
    child_counts: list[int] = []
    head = 0
    while head < len(order):
        node = order[head]
        head += 1
        children = node[0]
        if len(children) > MAX_CHILDREN:
            raise KbdlError(f"a trie node has {len(children)} children (max {MAX_CHILDREN})")
        if children:
            first_child.append(len(order))
            for ch in sorted(children):
                order.append(children[ch])
                chars.append(ord(ch))
        else:
            first_child.append(0)
        child_counts.append(len(children))
    node_count = len(order)

    # maxZipf bottom-up: children always have larger indices than their parent.
    max_zipf = [0] * node_count
    for index in range(node_count - 1, -1, -1):
        node = order[index]
        best_byte = max((zbytes[i] for i in node[1]), default=0)
        fc = first_child[index]
        for c in range(fc, fc + child_counts[index]):
            if max_zipf[c] > best_byte:
                best_byte = max_zipf[c]
        max_zipf[index] = best_byte

    values: list[int] = []
    node_blob = bytearray(node_count * NODE_SIZE)
    for index, node in enumerate(order):
        ids = node[1]
        if len(ids) > MAX_IDS_PER_NODE:
            raise KbdlError(f"{len(ids)} words share the key {keys[ids[0]]!r} (max {MAX_IDS_PER_NODE})")
        if ids:
            value_ref = (len(ids) << 24) | len(values)
            values.extend(ids)
        else:
            value_ref = 0
        _NODE.pack_into(node_blob, index * NODE_SIZE, first_child[index], chars[index],
                        child_counts[index], max_zipf[index], value_ref)
    if len(values) >= (1 << 24):
        raise KbdlError("values section exceeds 24-bit addressing")

    # Bigrams keyed by the most frequent casing of each side.
    first_id_for_key: dict[str, int] = {}
    for word_id, key in enumerate(keys):
        first_id_for_key.setdefault(key, word_id)
    pair_scores: dict[tuple[int, int], int] = {}
    for previous, nxt, log2_prob in bigrams:
        log2_prob = float(log2_prob)
        if math.isnan(log2_prob) or log2_prob < -8:
            continue
        a = first_id_for_key.get(lookup_key(previous))
        b = first_id_for_key.get(lookup_key(nxt))
        if a is None or b is None:
            continue
        score = bigram_score(min(0.0, log2_prob))
        if score > pair_scores.get((a, b), -1):
            pair_scores[(a, b)] = score
    per_word: dict[int, list[tuple[int, int]]] = {}
    for (a, b), score in pair_scores.items():
        per_word.setdefault(a, []).append((score, b))
    bigram_index = [0] * (word_count + 1)
    bigram_entries: list[int] = []
    for word_id in range(word_count):
        bigram_index[word_id] = len(bigram_entries)
        for score, b in sorted(per_word.get(word_id, ()), key=lambda e: (-e[0], e[1])):
            bigram_entries.append(b | (score << 24))
    bigram_index[word_count] = len(bigram_entries)

    # Sections.
    blob = bytearray()
    offsets = [0]
    for w in words:
        blob += w.encode("utf-8")
        offsets.append(len(blob))

    out = bytearray(HEADER_SIZE)

    def add_section(payload: bytes) -> int:
        start = len(out)
        out.extend(payload)
        out.extend(b"\0" * (_align4(len(out)) - len(out)))
        return start

    blob_offset = add_section(bytes(blob))
    word_offsets_offset = add_section(_u32_array(offsets))
    zipf_offset = add_section(zbytes)
    nodes_offset = add_section(bytes(node_blob))
    values_offset = add_section(_u32_array(values))
    bigram_index_offset = add_section(_u32_array(bigram_index))
    bigram_offset = add_section(_u32_array(bigram_entries))

    _HEADER.pack_into(out, 0, MAGIC, VERSION, word_count, node_count, len(values),
                      len(bigram_entries), blob_offset, len(blob), word_offsets_offset,
                      zipf_offset, nodes_offset, values_offset, bigram_index_offset,
                      bigram_offset, lang.ljust(LANG_ID_SIZE, b"\0"))
    return bytes(out)


# ---------------------------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------------------------

class Lexicon:
    """Reads a `.kbdl` file. `validate()` checks every section against the spec."""

    def __init__(self, data: bytes, validate: bool = True):
        self.data = bytes(data)
        if len(self.data) < HEADER_SIZE:
            raise KbdlError("file is shorter than the header")
        (magic, version, self.word_count, self.node_count, self.value_count, self.bigram_count,
         self.blob_offset, self.blob_size, self.word_offsets_offset, self.zipf_offset,
         self.nodes_offset, self.values_offset, self.bigram_index_offset, self.bigram_offset,
         lang) = _HEADER.unpack_from(self.data, 0)
        if magic != MAGIC:
            raise KbdlError(f"bad magic {magic!r}")
        if version != VERSION:
            raise KbdlError(f"unsupported version {version}")
        try:
            self.language_id = lang.rstrip(b"\0").decode("ascii")
        except UnicodeDecodeError as exc:
            raise KbdlError("language id is not ASCII") from exc
        if b"\0" in lang.rstrip(b"\0"):
            raise KbdlError("language id has inner NUL bytes")
        self._check_sections()
        self.word_offsets = _read_u32_array(self.data, self.word_offsets_offset, self.word_count + 1)
        self.zipf_bytes = self.data[self.zipf_offset:self.zipf_offset + self.word_count]
        self.values = _read_u32_array(self.data, self.values_offset, self.value_count)
        self.bigram_index = _read_u32_array(self.data, self.bigram_index_offset, self.word_count + 1)
        self.bigram_entries = _read_u32_array(self.data, self.bigram_offset, self.bigram_count)
        nodes = self.data[self.nodes_offset:self.nodes_offset + self.node_count * NODE_SIZE]
        unpacked = list(_NODE.iter_unpack(nodes))
        self.first_child = [n[0] for n in unpacked]
        self.chars = [n[1] for n in unpacked]
        self.child_counts = [n[2] for n in unpacked]
        self.max_zipf = [n[3] for n in unpacked]
        self.value_refs = [n[4] for n in unpacked]
        self._words: list[str] | None = None
        if validate:
            self.validate()

    @classmethod
    def from_file(cls, path: str, validate: bool = True) -> "Lexicon":
        with open(path, "rb") as f:
            return cls(f.read(), validate=validate)

    # -- structure ------------------------------------------------------------------------

    def _check_sections(self) -> None:
        size = len(self.data)
        sections = [
            ("blob", self.blob_offset, self.blob_size),
            ("wordOffsets", self.word_offsets_offset, 4 * (self.word_count + 1)),
            ("zipf", self.zipf_offset, self.word_count),
            ("nodes", self.nodes_offset, NODE_SIZE * self.node_count),
            ("values", self.values_offset, 4 * self.value_count),
            ("bigramIndex", self.bigram_index_offset, 4 * (self.word_count + 1)),
            ("bigrams", self.bigram_offset, 4 * self.bigram_count),
        ]
        spans = []
        for name, offset, length in sections:
            if offset % 4:
                raise KbdlError(f"{name} offset {offset} is not 4-byte aligned")
            if offset < HEADER_SIZE or offset + length > size:
                raise KbdlError(f"{name} section [{offset}, {offset + length}) is out of bounds ({size} bytes)")
            if length:
                spans.append((offset, offset + length, name))
        spans.sort()
        for (s1, e1, n1), (s2, _, n2) in zip(spans, spans[1:]):
            if s2 < e1:
                raise KbdlError(f"sections {n1} and {n2} overlap")
        if self.node_count < 1:
            raise KbdlError("the trie has no root node")

    def validate(self) -> None:
        """Checks every invariant of the format. Raises `KbdlError` on the first violation."""
        wc, nc = self.word_count, self.node_count
        offs = self.word_offsets
        if offs[0] != 0 or offs[wc] != self.blob_size:
            raise KbdlError("word offsets do not span the blob")
        words = self.words()
        for i in range(wc):
            if offs[i + 1] <= offs[i]:
                raise KbdlError(f"word {i} is empty or offsets are not increasing")
        for i in range(1, wc):
            if self.zipf_bytes[i] > self.zipf_bytes[i - 1]:
                raise KbdlError(f"word ids are not in descending frequency order at id {i}")

        # Trie shape: root at 0 with char 0, breadth-first, contiguous sorted children.
        if self.chars[0] != 0:
            raise KbdlError("root node char must be 0")
        expected_next = 1
        for index in range(nc):
            count = self.child_counts[index]
            first = self.first_child[index]
            if count == 0:
                if first != 0:
                    raise KbdlError(f"node {index} has firstChild but no children")
                continue
            if first != expected_next:
                raise KbdlError(f"node {index}: children not laid out breadth-first "
                                f"(firstChild {first}, expected {expected_next})")
            if first + count > nc:
                raise KbdlError(f"node {index}: children out of range")
            for c in range(first + 1, first + count):
                if self.chars[c] <= self.chars[c - 1]:
                    raise KbdlError(f"node {index}: children are not sorted by char")
            expected_next = first + count
        if expected_next != nc:
            raise KbdlError(f"{nc - expected_next} nodes are unreachable")

        # Values, terminal ids and maxZipf.
        seen = bytearray(wc)
        used_values = 0
        for index in range(nc):
            ref = self.value_refs[index]
            count, start = ref >> 24, ref & 0xFFFFFF
            best = 0
            if count:
                if start + count > self.value_count:
                    raise KbdlError(f"node {index}: values out of range")
                ids = self.values[start:start + count]
                for j, word_id in enumerate(ids):
                    if word_id >= wc:
                        raise KbdlError(f"node {index}: word id {word_id} out of range")
                    if j and ids[j] <= ids[j - 1]:
                        raise KbdlError(f"node {index}: ids are not most-frequent-first")
                    if seen[word_id]:
                        raise KbdlError(f"word id {word_id} is stored at more than one node")
                    seen[word_id] = 1
                    best = max(best, self.zipf_bytes[word_id])
                used_values += count
            first = self.first_child[index]
            for c in range(first, first + self.child_counts[index]):
                best = max(best, self.max_zipf[c])
            if self.max_zipf[index] != best:
                raise KbdlError(f"node {index}: maxZipf {self.max_zipf[index]} != {best}")
        if used_values != self.value_count or not all(seen):
            raise KbdlError("values section does not reference every word exactly once")
        for word_id, word in enumerate(words):
            key = lookup_key(word)
            if word_id not in self.lookup(key):
                raise KbdlError(f"word {word!r} (id {word_id}) is not stored under its key {key!r}")

        # Bigrams.
        index = self.bigram_index
        if index[0] != 0 or index[wc] != self.bigram_count:
            raise KbdlError("bigram index does not span the entries")
        for w in range(wc):
            start, end = index[w], index[w + 1]
            if end < start:
                raise KbdlError(f"bigram index decreases at word {w}")
            previous_score = 256
            for e in range(start, end):
                entry = self.bigram_entries[e]
                nxt, score = entry & 0xFFFFFF, entry >> 24
                if nxt >= wc:
                    raise KbdlError(f"bigram of word {w} points to id {nxt} out of range")
                if score > previous_score:
                    raise KbdlError(f"bigrams of word {w} are not sorted by score")
                previous_score = score

    # -- access ---------------------------------------------------------------------------

    def words(self) -> list[str]:
        if self._words is None:
            blob = self.data[self.blob_offset:self.blob_offset + self.blob_size]
            offs = self.word_offsets
            try:
                self._words = [blob[offs[i]:offs[i + 1]].decode("utf-8") for i in range(self.word_count)]
            except UnicodeDecodeError as exc:
                raise KbdlError("word blob is not valid UTF-8") from exc
        return self._words

    def word(self, word_id: int) -> str:
        return self.words()[word_id]

    def zipf(self, word_id: int) -> float:
        return zipf_from_byte(self.zipf_bytes[word_id])

    def _node_ids(self, index: int) -> list[int]:
        ref = self.value_refs[index]
        count, start = ref >> 24, ref & 0xFFFFFF
        return list(self.values[start:start + count]) if count else []

    def _child(self, index: int, unit: int) -> int | None:
        lo = self.first_child[index]
        hi = lo + self.child_counts[index] - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            c = self.chars[mid]
            if c == unit:
                return mid
            if c < unit:
                lo = mid + 1
            else:
                hi = mid - 1
        return None

    def _walk(self, key: str) -> int | None:
        node = 0
        for ch in key:
            if ord(ch) > 0xFFFF:
                return None
            nxt = self._child(node, ord(ch))
            if nxt is None:
                return None
            node = nxt
        return node

    def lookup(self, key: str) -> list[int]:
        """Ids of the words whose lookup key equals `key`, most frequent first."""
        node = self._walk(key)
        return self._node_ids(node) if node is not None else []

    def completions(self, prefix: str, limit: int) -> list[int]:
        """Most frequent words starting with `prefix` (best-first search on maxZipf)."""
        start = self._walk(prefix)
        if start is None or limit <= 0:
            return []
        # Heap of (-priority, kind, value); kind 0 = word id (emit), 1 = node (expand).
        heap: list[tuple[int, int, int]] = [(-self.max_zipf[start], 1, start)]
        result: list[int] = []
        while heap and len(result) < limit:
            _, kind, value = heapq.heappop(heap)
            if kind == 0:
                result.append(value)
                continue
            for word_id in self._node_ids(value):
                heapq.heappush(heap, (-self.zipf_bytes[word_id], 0, word_id))
            first = self.first_child[value]
            for c in range(first, first + self.child_counts[value]):
                heapq.heappush(heap, (-self.max_zipf[c], 1, c))
        return result

    def successors(self, word_id: int, limit: int) -> list[tuple[int, float]]:
        start, end = self.bigram_index[word_id], self.bigram_index[word_id + 1]
        out = []
        for e in range(start, min(end, start + limit)):
            entry = self.bigram_entries[e]
            out.append((entry & 0xFFFFFF, log2_prob_from_score(entry >> 24)))
        return out

    def top_words(self, limit: int) -> list[int]:
        return list(range(min(limit, self.word_count)))

    def fuzzy(self, key: str, max_edits: int = 1, limit: int = 10) -> list[tuple[int, int]]:
        """Plain Levenshtein search over the trie (used for sanity checks, not by the keyboard).
        Returns (word id, edit distance) sorted by distance, then frequency."""
        units = [ord(c) for c in key]
        found: dict[int, int] = {}

        def visit(node: int, previous_row: list[int]) -> None:
            for c in range(self.first_child[node], self.first_child[node] + self.child_counts[node]):
                unit = self.chars[c]
                row = [previous_row[0] + 1]
                for i, u in enumerate(units, 1):
                    row.append(min(row[i - 1] + 1, previous_row[i] + 1,
                                   previous_row[i - 1] + (0 if u == unit else 1)))
                if row[-1] <= max_edits:
                    for word_id in self._node_ids(c):
                        if row[-1] < found.get(word_id, max_edits + 1):
                            found[word_id] = row[-1]
                if min(row) <= max_edits:
                    visit(c, row)

        visit(0, list(range(len(units) + 1)))
        ranked = sorted(found.items(), key=lambda item: (item[1], item[0]))
        return ranked[:limit]

    def stats(self) -> dict:
        return {
            "language": self.language_id,
            "words": self.word_count,
            "nodes": self.node_count,
            "values": self.value_count,
            "bigrams": self.bigram_count,
            "bytes": len(self.data),
        }


# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

def _main(argv: Sequence[str]) -> int:
    if len(argv) < 2 or argv[0] not in {"info", "lookup", "complete", "fuzzy", "next", "top"}:
        print(__doc__)
        print("commands: info FILE | lookup FILE KEY | complete FILE PREFIX | fuzzy FILE KEY | "
              "next FILE WORD | top FILE")
        return 2
    command, path, *rest = argv
    lex = Lexicon.from_file(path)

    def show(ids):
        return ", ".join(f"{lex.word(i)} ({lex.zipf(i):.2f})" for i in ids)

    if command == "info":
        for k, v in lex.stats().items():
            print(f"{k:>9}: {v}")
    elif command == "lookup":
        print(show(lex.lookup(lookup_key(rest[0]))))
    elif command == "complete":
        print(show(lex.completions(lookup_key(rest[0]), 10)))
    elif command == "fuzzy":
        print(", ".join(f"{lex.word(i)} (d={d})" for i, d in lex.fuzzy(lookup_key(rest[0]), 2, 15)))
    elif command == "next":
        ids = lex.lookup(lookup_key(rest[0]))
        if ids:
            print(", ".join(f"{lex.word(i)} ({p:.2f})" for i, p in lex.successors(ids[0], 15)))
    elif command == "top":
        print(show(lex.top_words(50)))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
