#!/usr/bin/env python3
"""Unit tests for tools/kbdl.py (run: python3 -m unittest discover -s tools -p 'test_*.py')."""

import glob
import itertools
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kbdl  # noqa: E402
import build_dictionaries as builder  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def header(data):
    fields = struct.unpack_from("<4s13I8s", data, 0)
    names = ["magic", "version", "wordCount", "nodeCount", "valueCount", "bigramCount",
             "blobOffset", "blobSize", "wordOffsets", "zipfOffset", "nodesOffset",
             "valuesOffset", "bigramIndex", "bigramOffset", "langID"]
    return dict(zip(names, fields))


def nodes(data):
    h = header(data)
    return [struct.unpack_from("<IHBBI", data, h["nodesOffset"] + 12 * i) for i in range(h["nodeCount"])]


def u32s(data, offset, count):
    return list(struct.unpack_from(f"<{count}I", data, offset))


class HelperTests(unittest.TestCase):
    def test_lookup_key(self):
        self.assertEqual(kbdl.lookup_key("Haus"), "haus")
        self.assertEqual(kbdl.lookup_key("don\u2019t"), "don't")
        self.assertEqual(kbdl.lookup_key("Stra\u00dfe"), "stra\u00dfe")
        self.assertEqual(kbdl.lookup_key("E\u0308shte\u0308"), "\u00ebsht\u00eb")  # NFD input
        self.assertEqual(kbdl.lookup_key("\u00cb"), "\u00eb")
        self.assertEqual(kbdl.lookup_key("e\u0301"), "\u00e9")  # NFC composes

    def test_zipf_byte_rounding(self):
        self.assertEqual(kbdl.zipf_byte(0), 0)
        self.assertEqual(kbdl.zipf_byte(-3), 0)
        self.assertEqual(kbdl.zipf_byte(1.0), 32)
        self.assertEqual(kbdl.zipf_byte(0.5 / 32), 1)  # half rounds away from zero
        self.assertEqual(kbdl.zipf_byte(2.5 / 32), 3)  # not banker's rounding
        self.assertEqual(kbdl.zipf_byte(7.96875), 255)
        self.assertEqual(kbdl.zipf_byte(9.5), 255)
        self.assertAlmostEqual(kbdl.zipf_from_byte(kbdl.zipf_byte(4.4)), 4.40625)

    def test_bigram_score(self):
        self.assertEqual(kbdl.bigram_score(0), 255)
        self.assertEqual(kbdl.bigram_score(-1), 223)
        self.assertEqual(kbdl.bigram_score(-8), 0)
        self.assertEqual(kbdl.bigram_score(-20), 0)
        self.assertEqual(kbdl.bigram_score(-0.5 / 32), 255)
        self.assertEqual(kbdl.log2_prob_from_score(223), -1)


class WriterLayoutTests(unittest.TestCase):
    def test_byte_exact_small_lexicon(self):
        data = kbdl.build("de-AT", [("ab", 5.0), ("a", 4.0), ("Ab", 3.0)])
        h = header(data)
        self.assertEqual(h["magic"], b"KBDL")
        self.assertEqual(h["version"], 1)
        self.assertEqual(h["wordCount"], 3)
        self.assertEqual(h["nodeCount"], 3)
        self.assertEqual(h["valueCount"], 3)
        self.assertEqual(h["bigramCount"], 0)
        self.assertEqual(h["langID"], b"de-AT\0\0\0")
        # Blob: words in id order.
        self.assertEqual(h["blobOffset"], 64)
        self.assertEqual(h["blobSize"], 5)
        self.assertEqual(data[64:69], b"abaAb")
        # Sections are 4-byte aligned and follow each other.
        self.assertEqual(h["wordOffsets"], 72)
        self.assertEqual(u32s(data, 72, 4), [0, 2, 3, 5])
        self.assertEqual(h["zipfOffset"], 88)
        self.assertEqual(list(data[88:91]), [160, 128, 96])
        self.assertEqual(h["nodesOffset"], 92)
        # root -> 'a' (terminal "a") -> 'b' (terminal "ab", "Ab"), breadth-first.
        self.assertEqual(nodes(data), [
            (1, 0, 1, 160, 0),
            (2, ord("a"), 1, 160, (1 << 24) | 0),
            (0, ord("b"), 0, 160, (2 << 24) | 1),
        ])
        self.assertEqual(h["valuesOffset"], 92 + 36)
        self.assertEqual(u32s(data, h["valuesOffset"], 3), [1, 0, 2])
        self.assertEqual(h["bigramIndex"], h["valuesOffset"] + 12)
        self.assertEqual(u32s(data, h["bigramIndex"], 4), [0, 0, 0, 0])
        self.assertEqual(h["bigramOffset"], h["bigramIndex"] + 16)
        self.assertEqual(len(data), h["bigramOffset"])

    def test_breadth_first_and_sorted_children(self):
        data = kbdl.build("x", [("ba", 3), ("ab", 2), ("b", 1), ("zä", 1), ("za", 1)])
        n = nodes(data)
        chars = [chr(c) if c else "" for _, c, _, _, _ in n]
        # Level 1: a, b, z; level 2: a.b, b.a, z.a, z.ä (sorted by UTF-16 unit: a < ä).
        self.assertEqual(chars, ["", "a", "b", "z", "b", "a", "a", "ä"])
        self.assertEqual([fc for fc, _, _, _, _ in n], [1, 4, 5, 6, 0, 0, 0, 0])
        self.assertEqual([cc for _, _, cc, _, _ in n], [3, 1, 1, 2, 0, 0, 0, 0])
        lex = kbdl.Lexicon(data)
        self.assertEqual(lex.words(), ["ba", "ab", "b", "zä", "za"])

    def test_alignment_with_odd_sizes(self):
        data = kbdl.build("it", [("città", 3.3), ("è", 6.0), ("perché", 5.0)])
        h = header(data)
        for key in ("blobOffset", "wordOffsets", "zipfOffset", "nodesOffset", "valuesOffset",
                    "bigramIndex", "bigramOffset"):
            self.assertEqual(h[key] % 4, 0, key)
        kbdl.Lexicon(data)  # validates

    def test_ordering_dedup_and_ties(self):
        data = kbdl.build("x", [("b", 2.0), ("a", 3.0), ("b", 4.0), ("c", 2.0), ("d", 2.0)])
        lex = kbdl.Lexicon(data)
        self.assertEqual(lex.words(), ["b", "a", "c", "d"])  # dedup keeps max; ties keep input order
        self.assertEqual(lex.zipf(0), 4.0)

    def test_shared_keys_most_frequent_first(self):
        lex = kbdl.Lexicon(kbdl.build("de-AT", [("essen", 4.0), ("Essen", 4.5), ("US", 3.0), ("us", 5.0)]))
        self.assertEqual([lex.word(i) for i in lex.lookup("essen")], ["Essen", "essen"])
        self.assertEqual([lex.word(i) for i in lex.lookup("us")], ["us", "US"])

    def test_keys_are_normalised(self):
        lex = kbdl.Lexicon(kbdl.build("en-GB", [("don\u2019t", 5.0), ("Stra\u00dfe", 3.0), ("Cafe\u0301", 2.0)]))
        self.assertEqual([lex.word(i) for i in lex.lookup("don't")], ["don\u2019t"])
        self.assertEqual(lex.lookup("straße"), [1])
        self.assertEqual(lex.lookup("caf\u00e9"), [2])

    def test_non_bmp_and_empty_words_are_dropped(self):
        lex = kbdl.Lexicon(kbdl.build("x", [("ok", 1.0), ("a\U0001F600", 2.0), ("", 3.0), ("\U0001F600", 1.0)]))
        self.assertEqual(lex.words(), ["ok"])

    def test_too_many_casings_for_one_key(self):
        casings = ["".join(p) for p in itertools.product(*[(c, c.upper()) for c in "abcdefgh"])]
        self.assertEqual(len(casings), 256)
        with self.assertRaises(kbdl.KbdlError):
            kbdl.build("x", [(w, 1.0) for w in casings])
        kbdl.Lexicon(kbdl.build("x", [(w, 1.0) for w in casings[:255]]))

    def test_invalid_language_ids(self):
        for bad in ("", "toolongid", "dé"):
            with self.assertRaises((kbdl.KbdlError, UnicodeEncodeError)):
                kbdl.build(bad, [("a", 1)])
        self.assertEqual(header(kbdl.build("12345678", []))["langID"], b"12345678")

    def test_empty_lexicon(self):
        data = kbdl.build("sq", [])
        h = header(data)
        self.assertEqual((h["wordCount"], h["nodeCount"], h["valueCount"], h["bigramCount"]), (0, 1, 0, 0))
        lex = kbdl.Lexicon(data)
        self.assertEqual(lex.lookup(""), [])
        self.assertEqual(lex.completions("", 5), [])
        self.assertEqual(u32s(data, h["wordOffsets"], 1), [0])

    def test_deterministic(self):
        entries = [(f"w{i:05d}", (i * 7919) % 500 / 100) for i in range(3000)]
        bigrams = [(f"w{i:05d}", f"w{(i * 31) % 3000:05d}", -((i % 9) + 0.25)) for i in range(3000)]
        self.assertEqual(kbdl.build("de-AT", entries, bigrams), kbdl.build("de-AT", entries, bigrams))


class BigramTests(unittest.TestCase):
    def setUp(self):
        self.entries = [("the", 7.0), ("in", 6.5), ("of", 6.4), ("The", 5.0), ("house", 5.0), ("world", 4.0)]

    def test_encoding_and_order(self):
        data = kbdl.build("en-GB", self.entries, [
            ("in", "the", -1.0),
            ("in", "house", -3.0),
            ("in", "world", -9.0),       # below 2^-8: dropped
            ("of", "the", -0.5),
            ("of", "World", -2.0),       # mapped to "world"
            ("THE", "house", -4.0),      # mapped to "the" (most frequent casing)
            ("in", "unknown", -1.0),     # unknown side: dropped
            ("in", "the", -2.0),         # duplicate: keeps the higher probability
        ])
        h = header(data)
        self.assertEqual(h["bigramCount"], 5)
        lex = kbdl.Lexicon(data)
        ids = {w: i for i, w in enumerate(lex.words())}
        index = u32s(data, h["bigramIndex"], lex.word_count + 1)
        entries = u32s(data, h["bigramOffset"], 5)
        start, end = index[ids["in"]], index[ids["in"] + 1]
        self.assertEqual(entries[start:end], [ids["the"] | (223 << 24), ids["house"] | (159 << 24)])
        self.assertEqual(lex.successors(ids["of"], 10), [(ids["the"], -0.5), (ids["world"], -2.0)])
        self.assertEqual(lex.successors(ids["the"], 10), [(ids["house"], -4.0)])
        self.assertEqual(lex.successors(ids["The"], 10), [])
        self.assertEqual(index[0], 0)
        self.assertEqual(index[-1], 5)

    def test_probability_above_one_is_clamped(self):
        lex = kbdl.Lexicon(kbdl.build("x", self.entries, [("in", "the", 0.3)]))
        self.assertEqual(lex.successors(lex.lookup("in")[0], 1)[0][1], 0.0)

    def test_exactly_two_to_the_minus_eight_is_kept(self):
        lex = kbdl.Lexicon(kbdl.build("x", self.entries, [("in", "the", -8.0)]))
        self.assertEqual(lex.bigram_count, 1)
        self.assertEqual(lex.successors(lex.lookup("in")[0], 1)[0][1], kbdl.log2_prob_from_score(0))


class ReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = kbdl.build("de-AT", [
            ("ich", 7.5), ("schön", 5.0), ("schon", 6.0), ("Schule", 4.8), ("Schuh", 4.0),
            ("schnell", 5.2), ("Haus", 5.5), ("Häuser", 4.5), ("hausen", 1.0),
        ], [("ich", "schon", -3.0)])
        cls.lex = kbdl.Lexicon(cls.data)

    def names(self, ids):
        return [self.lex.word(i) for i in ids]

    def test_lookup(self):
        self.assertEqual(self.names(self.lex.lookup("haus")), ["Haus"])
        self.assertEqual(self.lex.lookup("hau"), [])
        self.assertEqual(self.lex.lookup("x"), [])
        self.assertEqual(self.lex.lookup("\U0001F600"), [])

    def test_completions_best_first(self):
        self.assertEqual(self.names(self.lex.completions("sch", 3)), ["schon", "schnell", "schön"])
        self.assertEqual(self.names(self.lex.completions("haus", 5)), ["Haus", "hausen"])
        self.assertEqual(self.names(self.lex.completions("", 2)), ["ich", "schon"])
        self.assertEqual(self.lex.completions("q", 3), [])

    def test_fuzzy(self):
        self.assertEqual([(self.lex.word(i), d) for i, d in self.lex.fuzzy("hsus", 1)], [("Haus", 1)])
        self.assertEqual(self.lex.fuzzy("xyz", 1), [])
        self.assertEqual([(self.lex.word(i), d) for i, d in self.lex.fuzzy("hous", 1)], [("Haus", 1)])
        self.assertIn("schön", self.names([i for i, _ in self.lex.fuzzy("schin", 1)]))

    def test_successors_and_top(self):
        ich = self.lex.lookup("ich")[0]
        self.assertEqual([(self.lex.word(i), p) for i, p in self.lex.successors(ich, 5)], [("schon", -3.0)])
        self.assertEqual(self.names(self.lex.top_words(2)), ["ich", "schon"])

    # -- corruption is detected ------------------------------------------------------------

    def corrupt(self, offset, fmt, value):
        data = bytearray(self.data)
        struct.pack_into(fmt, data, offset, value)
        return bytes(data)

    def test_rejects_bad_magic_and_version(self):
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(0, "<4s", b"KBDX"))
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(4, "<I", 2))
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.data[:40])

    def test_rejects_bad_sections(self):
        h = header(self.data)
        with self.assertRaises(kbdl.KbdlError):  # misaligned
            kbdl.Lexicon(self.corrupt(40, "<I", h["nodesOffset"] + 2))
        with self.assertRaises(kbdl.KbdlError):  # out of bounds
            kbdl.Lexicon(self.corrupt(52, "<I", len(self.data)))
        with self.assertRaises(kbdl.KbdlError):  # too many nodes
            kbdl.Lexicon(self.corrupt(12, "<I", h["nodeCount"] + 100))

    def test_rejects_bad_nodes(self):
        h = header(self.data)
        n = nodes(self.data)
        # Wrong maxZipf on the root.
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(h["nodesOffset"] + 7, "<B", n[0][3] - 1))
        # Swap the chars of the first two root children (unsorted children).
        a, b = n[1][1], n[2][1]
        data = bytearray(self.data)
        struct.pack_into("<H", data, h["nodesOffset"] + 12 + 4, b)
        struct.pack_into("<H", data, h["nodesOffset"] + 24 + 4, a)
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(bytes(data))
        # A word id out of range in the values section.
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(h["valuesOffset"], "<I", 999))

    def test_rejects_bad_bigrams(self):
        h = header(self.data)
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(h["bigramOffset"], "<I", (200 << 24) | 999))
        with self.assertRaises(kbdl.KbdlError):
            kbdl.Lexicon(self.corrupt(h["bigramIndex"] + 4 * h["wordCount"], "<I", 7))


class BundledDictionaryTests(unittest.TestCase):
    """Validates the committed dictionaries (skipped when they are not built yet)."""

    def test_bundled_files_are_valid(self):
        paths = sorted(glob.glob(os.path.join(ROOT, "Resources", "Dictionaries", "*.kbdl")))
        if not paths:
            self.skipTest("no bundled dictionaries")
        for path in paths:
            with self.subTest(path=os.path.basename(path)):
                lex = kbdl.Lexicon.from_file(path)
                self.assertEqual(lex.language_id, os.path.basename(path)[:-5])
                self.assertLessEqual(lex.word_count, 250_000)
                self.assertLessEqual(len(lex.data), 12 * 1024 * 1024)

    def bundled(self, lang_id):
        path = os.path.join(ROOT, "Resources", "Dictionaries", f"{lang_id}.kbdl")
        if not os.path.exists(path):
            self.skipTest(f"{lang_id}.kbdl is not built")
        return kbdl.Lexicon.from_file(path)

    def test_must_have_words(self):
        """tools/data/<id>-must-have.txt: everyday words with their main casing and frequency."""
        for lang_id, lang in builder.LANGUAGES.items():
            with self.subTest(lang=lang_id):
                self.assertIsNotNone(lang.must_have)
                required, _ = builder.read_must_have(lang.must_have, lang_id)
                self.assertGreaterEqual(len(required), 120)
                self.assertEqual(builder.check_must_have(self.bundled(lang_id), lang.must_have, lang_id), [])

    def test_required_and_forbidden_words(self):
        for lang_id, lang in builder.LANGUAGES.items():
            with self.subTest(lang=lang_id):
                lex = self.bundled(lang_id)
                words = set(lex.words())
                required = list(lang.required)
                if lang.supplement:
                    required += [word for word, _, _ in builder.read_supplement(lang.supplement)]
                self.assertEqual([w for w in required if w not in words], [])
                self.assertEqual([w for w in lang.forbidden if w in words], [])

    def test_bigrams_only_with_a_source(self):
        for lang_id, lang in builder.LANGUAGES.items():
            with self.subTest(lang=lang_id):
                count = self.bundled(lang_id).stats()["bigrams"]
                if lang.ngrams is None:
                    self.assertEqual(count, 0)  # Albanian: no bigram source
                else:
                    self.assertGreater(count, 2000)

    def test_common_bigrams(self):
        def log2p(lang_id, a, b):
            lex = self.bundled(lang_id)
            ids = sorted(lex.lookup(kbdl.lookup_key(a)))
            target = sorted(lex.lookup(kbdl.lookup_key(b)))[0]
            return dict(lex.successors(ids[0], 1000)).get(target)

        for lang_id, a, b in [("de-AT", "ich", "bin"), ("de-AT", "in", "der"), ("en-GB", "of", "the"),
                              ("en-US", "I", "am"), ("it", "non", "è"), ("it", "per", "favore")]:
            with self.subTest(pair=f"{a} {b}"):
                self.assertIsNotNone(log2p(lang_id, a, b))

    def test_casing_of_twins(self):
        """The main casing of a key comes first: nouns in German, proper nouns, lower-case verbs."""
        cases = {
            "de-AT": ["Zeit", "Freund", "Angst", "Hause", "Haus", "gehen", "haben", "sein", "ich", "Österreich"],
            "en-GB": ["I", "God", "French", "York", "China", "London", "may", "will", "bill", "John", "Mike", "nick"],
            "en-US": ["I", "God", "French", "Charlie", "China", "center", "may", "John", "Tom", "Peter", "Josh"],
            "it": ["Dio", "Roma", "papa", "perché"],
            "sq": ["Kosovë", "Gjermani", "është"],
        }
        for lang_id, words in cases.items():
            lex = self.bundled(lang_id)
            for word in words:
                with self.subTest(lang=lang_id, word=word):
                    ids = sorted(lex.lookup(kbdl.lookup_key(word)))
                    self.assertTrue(ids, f"{word} is missing")
                    self.assertEqual(lex.word(ids[0]), word)


class PipelineHelperTests(unittest.TestCase):
    """Pure helpers of tools/build_dictionaries.py (no downloads, no Hunspell)."""

    def test_spelling_variants(self):
        self.assertIn("color", builder.spelling_variants("colour"))
        self.assertIn("colour", builder.spelling_variants("color"))
        self.assertIn("center", builder.spelling_variants("centre"))
        self.assertIn("centres", builder.spelling_variants("centers"))
        self.assertIn("traveled", builder.spelling_variants("travelled"))
        self.assertIn("realize", builder.spelling_variants("realise"))
        self.assertIn("defense", builder.spelling_variants("defence"))
        self.assertIn("grey", builder.spelling_variants("gray"))
        self.assertIn("judgment", builder.spelling_variants("judgement"))
        self.assertNotIn("york", builder.spelling_variants("york"))
        self.assertEqual({v for v in builder.spelling_variants("york") if v in {"yorke", "yorks"}}, set())

    def test_must_have_list(self):
        data = kbdl.build("de-AT", [("ich", 7.0), ("Zeit", 6.0), ("gehen", 5.5), ("zeit", 5.0), ("Gehen", 4.5),
                                    ("Topfen", 2.6), ("strasse", 2.0)])
        lex = kbdl.Lexicon(data)
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
            f.write("# comment\nich 6.5\nZeit 5.5\ngehen\nde-AT: Topfen 3   # Austrian\nen-GB: colour\n"
                    "!Straße\n")
        try:
            required, absent = builder.read_must_have(f.name, "de-AT")
            self.assertEqual(required, [("ich", 6.5), ("Zeit", 5.5), ("gehen", 2.0), ("Topfen", 3.0)])
            self.assertEqual(absent, ["straße"])
            self.assertEqual(builder.check_must_have(lex, f.name, "de-AT"),
                             ["must-have 'Topfen' has zipf 2.59 < 3.0"])
            with open(f.name, "a", encoding="utf-8") as g:
                g.write("zeit\nHaus\n!STRASSE\n")
            self.assertEqual(builder.check_must_have(lex, f.name, "de-AT"), [
                "must-have 'Topfen' has zipf 2.59 < 3.0",
                "must-have 'zeit' is not the main casing ('Zeit' ranks first)",
                "must-have 'Haus' is missing",
                "'strasse' must be absent (has ['strasse'])",
            ])
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
