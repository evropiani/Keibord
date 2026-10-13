#!/usr/bin/env python3
"""Builds Keibord's word lists: Resources/Dictionaries/<id>.kbdl (de-AT, en-GB, en-US, sq, it).

    python3 tools/build_dictionaries.py                 # download (cached), build all, verify
    python3 tools/build_dictionaries.py --lang de-AT    # build one dictionary, then verify it
    python3 tools/build_dictionaries.py --verify        # only re-read and check the committed files
    python3 tools/build_dictionaries.py --dump DIR      # also write DIR/<id>.tsv (id, word, zipf, source)

Pipeline per dictionary (see tools/README.md for sources and licenses):
  1. Corpus frequencies: OpenSubtitles 2018 word counts (hermitdave/FrequencyWords), lower-cased.
     zipf = log10(count / total * 1e9) with total = sum of all counts in the full list.
  2. Spelling + casing with Hunspell (LibreOffice dictionaries) through libhunspell (ctypes; the
     library ships with the hunspell CLI). For each corpus word the valid forms among
     {lower, Capitalised, UPPER (len <= 4)} are kept. Hunspell accepts "Gehen"/"HAUS" for any valid
     lower-case word, so a Capitalised/UPPER form counts only if a copy of the dictionary
     restricted to capitalised/upper-case stems accepts it.
  3. Spelling variants: the counts of words that are (mostly) misspellings move to the word they
     spell and the misspelling is left out, so the keyboard corrects it: diacritic-less spellings
     ("eshte" -> "është", "perche'" -> "perché"; for Albanian/Italian also Hunspell-valid forms
     that are far rarer than their accented twin, "shume" -> "shumë", "cosi" -> "così"), Swiss
     "ss" ("strasse"), English contractions without apostrophe ("dont"), subtitle OCR errors
     ("lch" -> "ich") and the spellings listed in the supplements.
  4. Frequent words rejected by Hunspell are kept (okay, handy, slang) when plausible.
  5. Extras: English contractions (tools/data/en-contractions.txt), Italian elisions ("dell'"),
     the supplements (tools/data/<id>-supplement.txt) and Hunspell-only stems at zipf 0.8.
  6. Bigrams from Google Books 2grams (orgtre/google-books-ngram-frequency):
     P(next | prev) = c(prev next) / c(prev), with 1grams as denominators.
  7. The most frequent words that fit into the budget (word count and file size) are written.
Output is deterministic: the same inputs always produce identical bytes.
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import ctypes.util
import math
import multiprocessing
import os
import re
import sys
import unicodedata
import urllib.request
from collections import defaultdict
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kbdl  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
CACHE = os.path.join(TOOLS, ".cache")
DATA = os.path.join(TOOLS, "data")
OUTPUT = os.path.join(ROOT, "Resources", "Dictionaries")
RAW = "https://raw.githubusercontent.com/"

FREQUENCY_WORDS = "hermitdave/FrequencyWords/master/content/2018/{0}/{0}_full.txt"
HUNSPELL = "LibreOffice/dictionaries/master/{0}.{1}"
NGRAMS = "orgtre/google-books-ngram-frequency/main/ngrams/{0}grams_{1}.csv"

MAX_FILE_BYTES = 12_000_000
MAX_WORDS = 250_000
MAX_WORD_LENGTH = 30
DIC_ONLY_ZIPF = 0.8
FREQUENT_RANK = 30_000          # words Hunspell cannot vouch for must be among the most frequent
KEPT_MIN_COUNT = 100            # ... and seen often enough to trust (matters for the small Albanian corpus)
DUPLICATE_MIN_RANK = 1000       # see `keep_duplicates`
GLUE_RANK = 300                 # "ofthe" = two of the most frequent words glued together
SUBTITLE_JUNK = frozenset({"resynch", "resync", "synch", "sync", "subs", "www", "http", "https", "com", "org"})
# English words that other languages use as they are (kept when frequent in their corpus; other
# English words there come from untranslated subtitle lines).
ENGLISH_LOANWORDS = frozenset({
    "ok", "okay", "wow", "hey", "hi", "hallo", "hello", "bye", "baby", "sorry", "cool", "yeah", "party",
    "super", "sexy", "boss", "team", "online", "chat", "fan", "show", "star", "weekend", "computer",
    "internet", "film", "email", "job", "stop", "bar", "test", "hotel", "taxi", "sport", "club", "pub",
    "drink", "bravo", "mama", "papa", "shopping", "fitness", "handy", "camping", "manager", "trailer",
})
GERMAN_FUNCTION_WORD_RANK = 300
MIN_LOG2_BIGRAM = -8.0


@dataclass
class Language:
    id: str
    corpus: str                     # FrequencyWords language code
    hunspell: str                   # LibreOffice path without extension
    letters: str                    # core alphabet (lower-case)
    singles: frozenset              # one-letter words that are kept (exact forms)
    max_words: int
    ngrams: str | None = None       # google-books-ngram-frequency language
    sibling: str | None = None      # hunspell of a sibling variant (en-GB <-> en-US)
    min_count: int = 2              # ignore corpus words seen fewer times
    capital_penalty: float = 1.5    # zipf penalty for a Capitalised/UPPER duplicate of a valid word
    german_casing: bool = False     # German rule: Capitalised duplicates keep their zipf (−0.3 for function words)
    allow_triples: bool = False     # "Schifffahrt"
    elisions: bool = False          # Italian "dell'", "l'"
    contractions: str | None = None
    supplement: str | None = None
    forced_caps: tuple = ()         # Capitalised forms Hunspell does not list on their own ("Sie")
    keep_duplicates: tuple = ()     # Capitalised/UPPER twins of very frequent words that are kept ("US")
    # Hunspell-valid diacritic-free words are dropped as misspellings when their accented twin is
    # at least `respell_ratio` times as frequent (and seen at least `respell_min_count` times).
    respell_ratio: float | None = None
    respell_min_count: int = 0
    respell_keep: frozenset = frozenset()
    # Sloppy spellings of words Hunspell rejects: a dropped final letter ("goin") and letter swaps.
    sloppy_suffix: str = ""
    sloppy_swaps: tuple = ()
    known: list = field(default_factory=list)      # words Hunspell must accept (conversion check)
    required: list = field(default_factory=list)   # --verify: must be in the file with this casing
    forbidden: list = field(default_factory=list)  # --verify: must not be in the file


ENGLISH_REQUIRED = ["the", "I", "don't", "I'm", "it's", "can't", "London", "okay", "ok", "OK", "us",
                    "US", "May", "email", "you're"]
ENGLISH_FORBIDDEN = ["i", "don", "didn", "The", "It", "dont", "im", "youre", "thats", "lt", "lm", "goin", "cant"]

LANGUAGES = {
    "de-AT": Language(
        id="de-AT", corpus="de", hunspell="de/de_AT_frami", letters="abcdefghijklmnopqrstuvwxyzäöüß",
        singles=frozenset(), max_words=MAX_WORDS, ngrams="german", german_casing=True, allow_triples=True,
        supplement="de-AT-supplement.txt",
        forced_caps=("Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer", "Ihres"),
        known=["Haus", "Straße", "für", "schön", "Jänner"],
        required=["Haus", "Straße", "für", "schön", "ich", "Jänner", "Feber", "heuer", "Paradeiser",
                  "Erdäpfel", "Servus", "leiwand", "Sackerl", "E-Mail", "Essen", "essen", "Sie", "sie",
                  "Ihnen", "gehen", "Gehen", "ok", "grüß", "Gott"],
        forbidden=["haus", "HAUS", "fur", "strasse", "lch", "lhr", "s-sie", "Ne", "mußt", "wieviel"]),
    "en-GB": Language(
        id="en-GB", corpus="en", hunspell="en/en_GB", letters="abcdefghijklmnopqrstuvwxyz",
        singles=frozenset({"a", "I"}), max_words=150_000, ngrams="english", sibling="en/en_US",
        contractions="en-contractions.txt", supplement="en-supplement.txt",
        keep_duplicates=("US", "May", "God"), sloppy_suffix="g",
        known=["the", "colour", "London", "don't"],
        required=ENGLISH_REQUIRED + ["colour", "favourite"],
        forbidden=ENGLISH_FORBIDDEN + ["color", "favorite"]),
    "en-US": Language(
        id="en-US", corpus="en", hunspell="en/en_US", letters="abcdefghijklmnopqrstuvwxyz",
        singles=frozenset({"a", "I"}), max_words=150_000, ngrams="english", sibling="en/en_GB",
        contractions="en-contractions.txt", supplement="en-supplement.txt",
        keep_duplicates=("US", "May", "God"), sloppy_suffix="g",
        known=["the", "color", "London", "don't"],
        required=ENGLISH_REQUIRED + ["color", "favorite"],
        forbidden=ENGLISH_FORBIDDEN + ["colour", "favourite"]),
    "it": Language(
        id="it", corpus="it", hunspell="it_IT/it_IT", letters="abcdefghijklmnopqrstuvwxyzàèéìòù",
        singles=frozenset({"a", "e", "è", "i", "o"}), max_words=150_000, ngrams="italian", elisions=True,
        respell_ratio=0.8, respell_min_count=300,
        respell_keep=frozenset({"papa", "meta", "senno", "necessita"}),
        known=["perché", "città", "caffè", "l'amico"],
        required=["è", "e", "perché", "città", "più", "già", "così", "però", "caffè", "dell'", "l'",
                  "Roma", "papa", "papà", "sarà"],
        forbidden=["perche", "piu", "citta", "perche'", "cosi", "pero", "sara", "e'", "s-si", "pò"]),
    "sq": Language(
        id="sq", corpus="sq", hunspell="sq_AL/sq_AL", letters="abcdefghijklmnopqrstuvwxyzçë",
        singles=frozenset({"a", "e", "i", "o", "u"}), max_words=150_000, supplement="sq-supplement.txt",
        respell_ratio=3.0, respell_keep=frozenset({"te", "ne"}),
        sloppy_suffix="ë", sloppy_swaps=(("q", "ç"),),
        known=["është", "një", "çfarë", "Kosovë"],
        required=["është", "që", "për", "një", "të", "në", "çfarë", "mirë", "faleminderit", "shqip",
                  "Kosovë", "Prishtinë", "Tiranë", "te", "ne", "me", "shumë"],
        forbidden=["eshte", "cfare", "nje", "mire", "shume", "lshte", "Kosove", "është-është"]),
}

# Must match KeibordCore `Diacritics.variantsOf` (used to detect diacritic-less spellings).
DIACRITIC_VARIANTS = {
    "a": "àáâäãåāæ", "c": "çćč", "d": "đď", "e": "ëèéêēėę", "g": "ğ", "i": "ìíîïīį", "l": "łľ",
    "n": "ñńň", "o": "öòóôõøōœ", "r": "ř", "s": "ßśšş", "t": "ť", "u": "üùúûūů", "y": "ÿý", "z": "žźż",
}
BASE_OF = {v: base for base, variants in DIACRITIC_VARIANTS.items() for v in variants}
VOWELS = set("aeiouy") | {v for b in "aeiouy" for v in DIACRITIC_VARIANTS[b]}
ITALIAN_FINAL_ACCENTS = {"a": "à", "e": "èé", "i": "ì", "o": "ò", "u": "ù"}
ITALIAN_ELISION_PROBES = ["anno", "uomo", "amico", "altra", "idea", "ora", "essere", "è", "era", "ho",
                          "hai", "ha", "hanno", "erano", "io", "eri", "inizio", "ultimo", "una"]
TRIPLE = re.compile(r"(.)\1\1")
SOURCE_RANK = {"supplement": 0, "contraction": 0, "corpus": 1, "kept": 2, "hunspell": 3}


def fold(word: str) -> str:
    """Diacritic-insensitive form, like `Diacritics.fold` in KeibordCore."""
    return "".join(BASE_OF.get(c, c) for c in word.lower())


def zipf_of(count: float, total: int) -> float:
    return math.log10(count / total * 1e9)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------
# Downloads (cached in tools/.cache, which is gitignored)
# ---------------------------------------------------------------------------------------------

def fetch(path: str) -> str:
    """Returns the local copy of RAW + path, downloading it once."""
    dest = os.path.join(CACHE, *path.split("/"))
    if os.path.exists(dest):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    log(f"  downloading {path}")
    with urllib.request.urlopen(RAW + path, timeout=300) as response:
        data = response.read()
    with open(dest + ".part", "wb") as f:
        f.write(data)
    os.replace(dest + ".part", dest)
    return dest


# ---------------------------------------------------------------------------------------------
# Hunspell
# ---------------------------------------------------------------------------------------------

def _hunspell_library():
    name = ctypes.util.find_library("hunspell") or ctypes.util.find_library("hunspell-1.7")
    for candidate in filter(None, [name, "libhunspell-1.7.so.0", "libhunspell-1.7.0.dylib",
                                   "libhunspell.so", "libhunspell.dylib"]):
        try:
            lib = ctypes.CDLL(candidate)
            break
        except OSError:
            continue
    else:
        raise SystemExit("libhunspell not found (Debian/Ubuntu: apt install hunspell; macOS: brew install hunspell)")
    lib.Hunspell_create.restype = ctypes.c_void_p
    lib.Hunspell_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.Hunspell_spell.restype = ctypes.c_int
    lib.Hunspell_spell.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.Hunspell_destroy.argtypes = [ctypes.c_void_p]
    return lib


class Hunspell:
    """Exact whole-word checks (the CLI tokenizer would split "l'amico" and "e-mail")."""

    _lib = None

    def __init__(self, base: str):
        if Hunspell._lib is None:
            Hunspell._lib = _hunspell_library()
        self._handle = Hunspell._lib.Hunspell_create((base + ".aff").encode(), (base + ".dic").encode())

    def __call__(self, word: str) -> bool:
        return bool(Hunspell._lib.Hunspell_spell(self._handle, word.encode("utf-8")))


def _dic_stem(line: str) -> str | None:
    """The word of a .dic line ("Haus/STp" -> "Haus"; "\\/" is an escaped slash)."""
    out = []
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line) and line[i + 1] == "/":
            out.append("/")
            i += 2
            continue
        if c in "/ \t":
            break
        out.append(c)
        i += 1
    return "".join(out) or None


def _read_dic_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        lines = f.read().lstrip("﻿").split("\n")
    return [line.rstrip("\r") for line in lines[1:] if line.strip()]  # first line = entry count


def prepare_hunspell(name: str) -> dict[str, str]:
    """UTF-8 copies of a LibreOffice dictionary plus capitalised-only and upper-only variants.
    Returns {"main"|"caps"|"upper": base path}."""
    aff_src = fetch(HUNSPELL.format(name, "aff"))
    dic_src = fetch(HUNSPELL.format(name, "dic"))
    out_dir = os.path.join(CACHE, "hunspell-utf8")
    os.makedirs(out_dir, exist_ok=True)
    stem = name.replace("/", "_")
    bases = {kind: os.path.join(out_dir, f"{stem}-{kind}") for kind in ("main", "caps", "upper")}
    if all(os.path.exists(b + ".dic") for b in bases.values()):
        return bases

    with open(aff_src, "rb") as f:
        aff_raw = f.read()
    match = re.search(rb"^SET\s+(\S+)", aff_raw, re.M)
    encoding = match.group(1).decode("ascii") if match else "ISO8859-1"
    py_encoding = {"UTF-8": "utf-8", "UTF8": "utf-8"}.get(encoding.upper(), encoding.replace("ISO8859", "iso8859"))
    aff = aff_raw.decode(py_encoding).lstrip("﻿")
    with open(dic_src, "rb") as f:
        dic = f.read().decode(py_encoding).lstrip("﻿")
    lines = [line.rstrip("\r") for line in dic.split("\n")[1:] if line.strip()]
    if not py_encoding.startswith("utf"):
        # Re-encoding is lossless only when every affix flag is ASCII (single-byte flags would
        # otherwise turn into multi-byte UTF-8 sequences).
        flags = "".join(line.split("/", 1)[1].split()[0] for line in lines if "/" in line and line.split("/", 1)[1].strip())
        if any(ord(c) > 127 for c in flags):
            raise SystemExit(f"{name}: non-ASCII affix flags; cannot convert to UTF-8")
        aff = re.sub(r"^SET\s+\S+", "SET UTF-8", aff, count=1, flags=re.M)

    def write(base: str, entries: list[str]) -> None:
        with open(base + ".aff", "w", encoding="utf-8") as f:
            f.write(aff)
        with open(base + ".dic", "w", encoding="utf-8") as f:
            f.write(f"{len(entries)}\n" + "\n".join(entries) + "\n")

    def first_letter_upper(line: str) -> bool:
        s = _dic_stem(line)
        return bool(s) and s[0].isupper()

    write(bases["main"], lines)
    write(bases["caps"], [line for line in lines if first_letter_upper(line)])
    write(bases["upper"], [line for line in lines if is_all_upper(_dic_stem(line) or "")])
    return bases


def is_all_upper(word: str) -> bool:
    letters = [c for c in word if c.isalpha()]
    return len(letters) >= 2 and all(c.isupper() for c in letters)


# Worker state for multiprocessing (each process owns its own Hunspell handles).
_W: dict = {}


def _init_worker(bases: dict, sibling_base: str | None, lang_id: str) -> None:
    _W["main"] = Hunspell(bases["main"])
    _W["caps"] = Hunspell(bases["caps"])
    _W["upper"] = Hunspell(bases["upper"])
    _W["sibling"] = Hunspell(sibling_base) if sibling_base else None
    _W["lang"] = LANGUAGES[lang_id]


def _capitalised_candidates(word: str) -> list[str]:
    first = word[:1].upper() + word[1:]
    out = [first]
    if "-" in word:
        each = "-".join(part[:1].upper() + part[1:] for part in word.split("-"))
        if each != first:
            out.append(each)
    return out


def _classify(words: list[str]) -> list[tuple]:
    """For each lower-case corpus word: (valid forms [(form, kind)], valid in sibling dictionary)."""
    main, caps, upper, sibling, lang = _W["main"], _W["caps"], _W["upper"], _W["sibling"], _W["lang"]
    results = []
    for w in words:
        if lang.elisions and w.endswith("'"):
            ok = any(main(w + probe) for probe in ITALIAN_ELISION_PROBES) or main(w)
            results.append(([(w, "lower")] if ok else [], False))
            continue
        forms = []
        lower_ok = main(w)
        if lower_ok:
            forms.append((w, "lower"))
        for c in _capitalised_candidates(w):
            if c != w and main(c) and (not lower_ok or caps(c)):
                forms.append((c, "cap"))
                break
        if len(w) <= 4 and w.isalpha() and "ß" not in w:
            u = w.upper()
            if u != w and len(u) == len(w) and upper(u):
                forms.append((u, "upper"))
        sib = bool(sibling and not forms and sibling(w))
        results.append((forms, sib))
    return results


def _check_words(words: list[str]) -> list[bool]:
    main = _W["main"]
    return [main(w) for w in words]


class SpellPool:
    def __init__(self, bases: dict, sibling_base: str | None, lang_id: str, processes: int):
        ctx = multiprocessing.get_context("fork" if sys.platform != "win32" else "spawn")
        self.pool = ctx.Pool(processes, initializer=_init_worker, initargs=(bases, sibling_base, lang_id))

    def _map(self, fn, items: list, chunk: int = 2000) -> list:
        chunks = [items[i:i + chunk] for i in range(0, len(items), chunk)]
        out = []
        for part in self.pool.imap(fn, chunks):
            out.extend(part)
        return out

    def classify(self, words: list[str]) -> list[tuple]:
        return self._map(_classify, words)

    def check(self, words: list[str]) -> list[bool]:
        return self._map(_check_words, words)

    def close(self) -> None:
        self.pool.close()
        self.pool.join()


# ---------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------

def read_frequencies(code: str) -> tuple[dict[str, int], int]:
    counts: dict[str, int] = defaultdict(int)
    total = 0
    with open(fetch(FREQUENCY_WORDS.format(code)), encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").rsplit(" ", 1)
            if len(parts) != 2 or not parts[1].isdigit():
                continue
            count = int(parts[1])
            total += count
            counts[unicodedata.normalize("NFC", parts[0]).lower()] += count
    return dict(counts), total


def read_ngrams(language: str, n: int) -> list[tuple[list[str], int]]:
    rows = []
    with open(fetch(NGRAMS.format(n, language)), encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            tokens = unicodedata.normalize("NFC", row["ngram"]).split(" ")
            if len(tokens) == n and row["freq"].isdigit():
                rows.append((tokens, int(row["freq"])))
    return rows


def read_table(name: str) -> list[list[str]]:
    """Whitespace-separated data file; '#' starts a comment."""
    rows = []
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                rows.append(line.split())
    return rows


def read_supplement(name: str) -> list[tuple[str, float, list[str]]]:
    """Rows "<word> <zipf> [<absorbed spelling> ...]"."""
    out = []
    for row in read_table(name):
        try:
            z = float(row[1])
        except (IndexError, ValueError):
            raise SystemExit(f"{name}: expected 'word zipf [spellings]', got {' '.join(row)!r}")
        absorbed = [kbdl.lookup_key(unicodedata.normalize("NFC", s)) for s in row[2:]]
        out.append((unicodedata.normalize("NFC", row[0]), z, absorbed))
    return out


def is_plain_word(word: str, letters: str) -> bool:
    return all(c in letters for c in word)


def is_latin_word(word: str, letters: str) -> bool:
    """Letters of the language or Latin letters with diacritics (é in "Café"), optional inner hyphens."""
    for part in word.split("-"):
        if not part:
            return False
        for c in part:
            if c in letters:
                continue
            base = unicodedata.normalize("NFD", c)[0]
            if not (c.isalpha() and "a" <= base.lower() <= "z"):
                return False
    return True


def is_stutter(word: str) -> bool:
    """Hyphenated stammering in subtitles: "s-sie", "i-ich", "është-është"."""
    parts = word.split("-")
    return any(b.startswith(a) or a.startswith(b) for a, b in zip(parts, parts[1:]))


def is_corpus_token(word: str, lang: Language) -> bool:
    if not word or len(word) > MAX_WORD_LENGTH:
        return False
    if lang.elisions and word.endswith("'") and word.count("'") == 1 and len(word) >= 2:
        return is_plain_word(word[:-1], lang.letters)
    if "'" in word:
        return False
    if not is_latin_word(word, lang.letters) or ("-" in word and is_stutter(word)):
        return False
    if len(word) == 1:
        return any(s.lower() == word for s in lang.singles)
    return True


# ---------------------------------------------------------------------------------------------
# Building one dictionary
# ---------------------------------------------------------------------------------------------

def apply_contractions(counts: dict[str, int], table: list[list[str]]) -> dict[str, float]:
    """Rebuilds English contractions that the corpus tokenizer split ("don" + "'t")."""
    result: dict[str, float] = {}
    taken: dict[str, float] = defaultdict(float)
    rules = []
    for row in table:
        word, mode = row[0], row[1]
        stem, rest = word.split("'", 1)
        rules.append((word, mode, float(row[2]) if mode == "share" else 1.0, stem.lower(), "'" + rest.lower()))
    for word, mode, _, stem, suffix in rules:
        if mode == "stem":
            result[word] = counts.get(stem, 0)
            taken[suffix] += result[word]
    for word, mode, weight, stem, suffix in rules:
        if mode == "share":
            result[word] = max(0.0, counts.get(suffix, 0) - taken[suffix]) * weight
    for word, mode, weight, stem, suffix in rules:
        counts[stem] = max(0, counts.get(stem, 0) - int(round(result[word])))
    return {w: c for w, c in result.items() if c >= 1}


def casing_hints(lang: Language) -> dict[str, int]:
    """Google Books unigram counts by casing (their lists keep the dominant casing of a word;
    breaks ties between "Essen" and "essen")."""
    if not lang.ngrams:
        return {}
    hints: dict[str, int] = defaultdict(int)
    for (token,), freq in read_ngrams(lang.ngrams, 1):
        hints[token] += freq
    return dict(hints)


def build_bigrams(lang: Language) -> list[tuple[str, str, float]]:
    """(previous key, next key, log2 P(next | previous)) with P >= 2^-8."""
    if not lang.ngrams:
        return []
    unigrams: dict[str, int] = defaultdict(int)
    for (token,), freq in read_ngrams(lang.ngrams, 1):
        unigrams[kbdl.lookup_key(token)] += freq
    pairs: dict[tuple[str, str], int] = defaultdict(int)
    for (a, b), freq in read_ngrams(lang.ngrams, 2):
        pairs[(kbdl.lookup_key(a), kbdl.lookup_key(b))] += freq
    out = []
    for (a, b), freq in sorted(pairs.items()):
        denominator = unigrams.get(a)
        if not denominator:
            continue
        log2p = math.log2(min(1.0, freq / denominator))
        if log2p >= MIN_LOG2_BIGRAM:
            out.append((a, b, log2p))
    return out


def find_respellings(lang: Language, tokens: list[str], counts: dict[str, int], classified: dict,
                     contractions: dict[str, str], standalone: set[str]) -> dict[str, str]:
    """Corpus words that are (mostly) misspellings -> the word they spell (a valid corpus word or
    a contraction). `tokens` are sorted by descending count; `standalone` holds the words ending
    in an apostrophe that Hunspell accepts on their own ("po'")."""
    def valid(w: str) -> bool:
        return w in classified and bool(classified[w][0])

    # Most frequent valid word for each diacritic-free spelling (`accented`: only words with diacritics).
    by_fold: dict[str, str] = {}
    accented: dict[str, str] = {}
    for w in tokens:
        if valid(w):
            by_fold.setdefault(fold(w), w)
            if fold(w) != w:
                accented.setdefault(fold(w), w)

    def spelled(c: str) -> str | None:
        """The valid word `c` spells: itself or its most frequent twin that differs only in diacritics."""
        return c if valid(c) else by_fold.get(fold(c))

    def ocr_fix(w: str) -> str | None:
        # Subtitle OCR confuses "I" and "l": "lch" -> "ich", "lshte" -> "ishte", "faieminderit".
        for a, b in (("l", "i"), ("i", "l")):
            candidates = [w[:m.start()] + b + w[m.end():] for m in re.finditer(a, w)]
            if w.count(a) > 1:
                candidates.append(w.replace(a, b))
            for c in candidates:
                if valid(c) and counts[c] >= 2 * counts[w]:
                    return c
        return None

    def sloppy_fix(w: str) -> str | None:
        # Dropped final letters (Albanian "shum", "mir"; English "goin"), a needless final letter
        # (Albanian "largë") and letter swaps (Albanian "q" for "ç": "qka", "qfar").
        suffix = lang.sloppy_suffix
        variants = [w]
        for a, b in lang.sloppy_swaps:
            if a in w:
                variants.append(w.replace(a, b))
        for v in variants:
            for c in [v] + ([v + suffix] if suffix else []):
                target = spelled(c)
                if target is not None and target != w:
                    return target
        if suffix and w.endswith(suffix) and len(w) > len(suffix) + 1:
            target = spelled(w[:-len(suffix)])
            if target is not None and counts[target] >= 2 * counts[w]:
                return target
        return None

    def candidates(w: str):
        """Words that the rejected word `w` may be a misspelling of, most likely first."""
        yield by_fold.get(fold(w))  # "eshte" -> "është", "vënd" -> "vend"
        if lang.german_casing and ("ss" in w or "ß" in w):
            # Swiss "strasse" -> "Straße", pre-1996 "mußt" -> "musst".
            variants = [w[:m.start()] + "ß" + w[m.end():] for m in re.finditer("ss", w)]
            variants += [w.replace("ss", "ß"), w.replace("ß", "ss")]
            yield next((v for v in variants if v != w and valid(v)), None)
        if lang.elisions and w[-1] in BASE_OF:
            apocope = w[:-1] + BASE_OF[w[-1]] + "'"  # "pò" for "po'"
            yield apocope if apocope in standalone else None
        if lang.sloppy_suffix or lang.sloppy_swaps:
            yield sloppy_fix(w)
        if "l" in w or "i" in w:
            yield ocr_fix(w)

    result: dict[str, str] = {}
    for w in tokens:
        if (lang.elisions and w.endswith("'") and len(w) >= 2 and w[-2] in ITALIAN_FINAL_ACCENTS
                and w not in standalone):
            # Italian subtitles write "perche'" / "e'" for "perché" / "è".
            for accent in ITALIAN_FINAL_ACCENTS[w[-2]]:
                if valid(w[:-2] + accent):
                    result[w] = w[:-2] + accent
                    break
            continue
        if not valid(w):
            if w in contractions:
                result[w] = contractions[w]  # "dont" -> "don't"
                continue
            for target in candidates(w):
                # The intended word is at least half as frequent as the misspelling ("ok" is not "okë").
                if target is not None and target != w and counts.get(target, 0) * 2 >= counts[w]:
                    result[w] = target
                    break
            continue
        if (lang.respell_ratio and fold(w) == w and w not in lang.respell_keep and w in accented
                and counts[accented[w]] >= max(lang.respell_min_count, lang.respell_ratio * counts[w])):
            result[w] = accented[w]
    return result


def entry_sort_key(entry: tuple) -> tuple:
    """Frequency first; ties: curated sources, Google Books casing, lower-case, shorter words."""
    form, zipf, source, hint = entry
    return (-zipf, SOURCE_RANK[source], -hint, form != form.lower(), len(form), form)


def fit_budget(forms: list[str], bigram_count: int, max_words: int, max_bytes: int) -> int:
    """Largest n such that a .kbdl of forms[:n] fits (counting every bigram as an upper bound)."""
    prefixes: set[str] = set()
    blob = 0

    def align(n: int) -> int:
        return (n + 3) & ~3

    for n, form in enumerate(forms[:max_words], 1):
        key = kbdl.lookup_key(form)
        prefixes.update(key[:i] for i in range(1, len(key) + 1))
        blob += len(form.encode("utf-8"))
        size = (kbdl.HEADER_SIZE + align(blob) + 4 * (n + 1) + align(n) + kbdl.NODE_SIZE * (1 + len(prefixes))
                + 4 * n + 4 * (n + 1) + 4 * bigram_count)
        if size > max_bytes:
            return n - 1
    return min(len(forms), max_words)


def build_language(lang: Language, processes: int) -> tuple[bytes, dict, list[tuple]]:
    """Returns (file bytes, statistics, final entries (form, zipf, source, hint) in id order)."""
    log(f"[{lang.id}] reading corpus")
    counts, total = read_frequencies(lang.corpus)
    stats: dict = {"corpus tokens": len(counts), "corpus total": total}

    contraction_counts: dict[str, float] = {}
    contraction_stems: set[str] = set()  # "don", "didn": only ever part of a contraction
    if lang.contractions:
        table = read_table(lang.contractions)
        contraction_counts = apply_contractions(counts, table)
        contraction_stems = {row[0].split("'")[0].lower() for row in table if row[1] == "stem"}

    tokens = [w for w, c in counts.items() if c >= lang.min_count and is_corpus_token(w, lang)]
    tokens.sort(key=lambda w: (-counts[w], w))
    rank = {w: i for i, w in enumerate(tokens)}
    stats["candidate tokens"] = len(tokens)
    supplement = read_supplement(lang.supplement) if lang.supplement else []

    bases = prepare_hunspell(lang.hunspell)
    sibling = prepare_hunspell(lang.sibling)["main"] if lang.sibling else None
    main = Hunspell(bases["main"])
    rejected_known = [w for w in lang.known if not main(w)]
    if rejected_known:
        raise SystemExit(f"{lang.id}: hunspell rejects {rejected_known}; dictionary conversion failed?")

    pool = SpellPool(bases, sibling, lang.id, processes)
    try:
        log(f"[{lang.id}] checking {len(tokens)} words with hunspell")
        classified = dict(zip(tokens, pool.classify(tokens)))
        names = sorted(contraction_counts)
        contraction_counts = {w: contraction_counts[w] for w, ok in zip(names, pool.check(names)) if ok}

        dic_stems = []
        seen_stems = set()
        for line in _read_dic_lines(bases["main"] + ".dic"):
            stem = _dic_stem(line)
            if stem and stem not in seen_stems:
                seen_stems.add(stem)
                dic_stems.append(unicodedata.normalize("NFC", stem))
        dic_ok = pool.check(dic_stems)
    finally:
        pool.close()

    for form in lang.forced_caps:
        w = form.lower()
        if w in classified and all(f != form for f, _ in classified[w][0]):
            classified[w] = (classified[w][0] + [(form, "cap")], classified[w][1])

    # Spelling variants: counts move to the word they spell; the variants are left out.
    effective: dict[str, float] = {w: float(c) for w, c in counts.items()}
    standalone = {w for w in tokens if w.endswith("'") and main(w)}
    respelled = find_respellings(lang, tokens, counts, classified,
                                 {w.replace("'", "").lower(): w for w in contraction_counts}, standalone)
    for w, target in respelled.items():
        for _ in range(4):  # chains such as an OCR error of a diacritic-less spelling
            target = respelled.get(target, target)
        if target in contraction_counts:
            contraction_counts[target] += counts[w]
        else:
            effective[target] += counts[w]
    stats["merged spellings"] = len(respelled)

    hints = casing_hints(lang)
    # English Hunspell: recognises English words in other corpora and names (also for en-GB/en-US,
    # whose sibling may know a name that their own dictionary lacks).
    english = None if lang.corpus == "en" else Hunspell(prepare_hunspell("en/en_US")["main"])
    namer = Hunspell(sibling) if sibling else english
    function_words = set(tokens[:GERMAN_FUNCTION_WORD_RANK])
    top_words = {w for w in tokens[:GLUE_RANK] if len(w) >= 2}
    entries: list[tuple] = []  # (form, zipf, source, hint)
    kept_unknown = 0
    for w in tokens:
        if w in respelled or (TRIPLE.search(w) and not lang.allow_triples):
            continue
        forms, sibling_valid = classified[w]
        z = zipf_of(effective[w], total)
        if "-" in w and rank[w] >= FREQUENT_RANK:
            continue  # Hunspell accepts any hyphenation of two valid words
        if not forms:
            # Frequent words Hunspell does not know (okay, handy, slang, names), but not glued
            # words ("ofthe") nor, in other languages, English from untranslated subtitle lines.
            if not (rank[w] < FREQUENT_RANK and counts[w] >= KEPT_MIN_COUNT and len(w) >= 2
                    and not sibling_valid and is_plain_word(w, lang.letters)
                    and any(c in VOWELS for c in w) and w not in SUBTITLE_JUNK
                    and not any(w[:i] in top_words and w[i:] in top_words for i in range(2, len(w) - 1))):
                continue
            if english is not None and english(w) and w not in ENGLISH_LOANWORDS:
                continue
            cap = w[:1].upper() + w[1:]
            form = w
            # Two-letter words are left alone: Hunspell lists symbols such as "Ne" (neon).
            if len(w) >= 3 and namer is not None and w not in ENGLISH_LOANWORDS and not namer(w):
                if namer(cap):
                    form = cap  # a name ("john")
                elif len(w) <= 4 and namer(w.upper()):
                    form = w.upper()  # "fbi"
            if form == w and len(w) >= 3 and hints.get(cap, 0) > 4 * hints.get(w, 0):
                form = cap  # mostly written capitalised
            entries.append((form, z, "kept", hints.get(form, 0)))
            kept_unknown += 1
            continue
        forms = [(form, kind) for form, kind in forms if len(form) > 1 or form in lang.singles]
        kinds = {kind for _, kind in forms}
        for form, kind in forms:
            value = z
            duplicate = (kind == "cap" and "lower" in kinds) or (kind == "upper" and len(kinds) > 1)
            if duplicate and not lang.german_casing:
                # Outside German a Capitalised/UPPER twin of a very frequent word is dictionary
                # noise (chemical symbols "He", "In"; place names "Came"; acronyms "OR").
                if rank[w] < DUPLICATE_MIN_RANK and form not in lang.keep_duplicates:
                    continue
                value = z - lang.capital_penalty
            elif duplicate and kind == "cap":
                value = z - (0.3 if w in function_words else 0.0)
            elif duplicate:
                value = z - lang.capital_penalty
            entries.append((form, value, "corpus", hints.get(form, 0)))
    stats["kept unknown"] = kept_unknown

    for word, count in contraction_counts.items():
        entries.append((word, zipf_of(count, total), "contraction", 0))

    # Supplement: curated words win over corpus values; absorbed spellings are removed.
    absorbed = {key for _, _, keys in supplement for key in keys}
    supplement_words = {word for word, _, _ in supplement}
    index = {e[0]: i for i, e in enumerate(entries)}
    for word, z, _ in supplement:
        if word in index:
            form, old, source, hint = entries[index[word]]
            entries[index[word]] = (form, max(old, z), source, hint)
        else:
            index[word] = len(entries)
            entries.append((word, z, "supplement", hints.get(word, 0)))
    entries = [e for e in entries if e[0] in supplement_words or kbdl.lookup_key(e[0]) not in absorbed]

    # Hunspell-only stems (not in the corpus) fill the remaining budget at zipf 0.8.
    present = {kbdl.lookup_key(e[0]) for e in entries}
    blocked = present | absorbed | contraction_stems | {kbdl.lookup_key(w) for w in respelled}
    accented_folds = {fold(k) for k in present if fold(k) != k}
    added = 0
    for stem, ok in zip(dic_stems, dic_ok):
        key = kbdl.lookup_key(stem)
        # Capitalised stems are nouns in German but rare proper names elsewhere ("Kilfinan").
        if (not ok or key in blocked or not 2 <= len(stem) <= MAX_WORD_LENGTH or is_all_upper(stem)
                or (stem != key and not lang.german_casing)
                or not is_latin_word(key, lang.letters) or "-" in key
                or (TRIPLE.search(key) and not lang.allow_triples)
                or (lang.respell_ratio and fold(key) == key and key in accented_folds)):
            continue
        entries.append((stem, DIC_ONLY_ZIPF, "hunspell", 0))
        blocked.add(key)
        added += 1
    stats["hunspell-only candidates"] = added

    entries.sort(key=entry_sort_key)
    deduped, seen_forms = [], set()
    for e in entries:
        if e[0] not in seen_forms:
            seen_forms.add(e[0])
            deduped.append(e)

    bigrams = build_bigrams(lang)
    limit = fit_budget([e[0] for e in deduped], len(bigrams), lang.max_words, MAX_FILE_BYTES)
    final = deduped[:limit]
    data = kbdl.build(lang.id, [(form, z) for form, z, _, _ in final], bigrams)
    if len(data) > MAX_FILE_BYTES:
        raise SystemExit(f"{lang.id}: {len(data)} bytes exceeds the budget")
    for source in ("corpus", "kept", "contraction", "supplement", "hunspell"):
        stats[f"words from {source}"] = sum(1 for e in final if e[2] == source)
    stats["cut by budget"] = len(deduped) - limit
    return data, stats, final


# ---------------------------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------------------------

SAMPLES = {
    "de-AT": (["haus", "essen", "sie", "jänner", "e-mail", "strasse", "fur", "gehen"], ["schö", "jä", "ös"], ["in", "ich"]),
    "en-GB": (["i", "dont", "london", "us", "colour", "color", "im"], ["th", "don"], ["of", "i"]),
    "en-US": (["i", "im", "colour", "color", "ok"], ["th", "col"], ["in"]),
    "it": (["perche", "citta", "dell'", "roma", "e", "cosi", "sara"], ["perc", "cit"], ["di", "non"]),
    "sq": (["eshte", "cfare", "kosove", "faleminderit", "shqip", "shume", "te"], ["ësh", "fal", "prisht"], []),
}


def verify(ids: list[str]) -> bool:
    ok = True
    for lang_id in ids:
        lang = LANGUAGES[lang_id]
        path = os.path.join(OUTPUT, f"{lang_id}.kbdl")
        print(f"\n== {lang_id}  ({os.path.relpath(path, ROOT)})")
        problems = []
        try:
            lex = kbdl.Lexicon.from_file(path)  # validates every section
        except (OSError, kbdl.KbdlError) as exc:
            print(f"  INVALID: {exc}")
            ok = False
            continue
        s = lex.stats()
        print(f"  words {s['words']:,}  nodes {s['nodes']:,}  values {s['values']:,}  "
              f"bigrams {s['bigrams']:,}  size {s['bytes']:,} bytes ({s['bytes'] / 1e6:.2f} MB)")
        if lex.language_id != lang_id:
            problems.append(f"langID is {lex.language_id!r}")
        if s["words"] > MAX_WORDS or s["bytes"] > MAX_FILE_BYTES:
            problems.append("over the size budget")
        if (s["bigrams"] == 0) != (lang.ngrams is None):
            problems.append(f"unexpected bigram count {s['bigrams']}")
        if lang.ngrams is None and any(lex.bigram_index):
            problems.append("bigram index must be all zero without bigrams")

        def rank(word):
            for i in lex.lookup(kbdl.lookup_key(word)):
                if lex.word(i) == word:
                    return i
            return None

        required = list(lang.required)
        if lang.supplement:
            required += [word for word, _, _ in read_supplement(lang.supplement)]
        missing = [w for w in required if rank(w) is None]
        present = [w for w in lang.forbidden if rank(w) is not None]
        if missing:
            problems.append(f"missing {missing}")
        if present:
            problems.append(f"should not contain {present}")
        if lang_id == "de-AT":
            j, jan = rank("Jänner"), rank("Januar")
            if j is None or (jan is not None and j > jan):
                problems.append("Jänner must outrank Januar")
        if lang_id == "en-GB" and (rank("colour") is None or rank("color") is not None):
            problems.append("en-GB must contain colour but not color")
        if lang_id == "en-US" and (rank("color") is None or rank("colour") is not None):
            problems.append("en-US must contain color but not colour")

        def show(ids_):
            return ", ".join(f"{lex.word(i)} {lex.zipf(i):.2f}" for i in ids_)

        keys, prefixes, previous = SAMPLES[lang_id]
        print(f"  top: {show(lex.top_words(12))}")
        for key in keys:
            exact = show(lex.lookup(kbdl.lookup_key(key))) or "-"
            # Words that differ only by diacritics/ß (what accent restoration can reach) and 1-edit neighbours.
            accents = ", ".join(lex.word(i) for i, _ in lex.fuzzy(key, 3, 60)
                                if fold(lex.word(i)) == fold(key) and lex.word(i).lower() != key)
            near = ", ".join(lex.word(i) for i, d in lex.fuzzy(key, 1, 8) if d == 1)
            print(f"  lookup {key!r}: [{exact}]  accents [{accents or '-'}]  1 edit [{near or '-'}]")
        for p in prefixes:
            print(f"  complete {p!r}: {show(lex.completions(kbdl.lookup_key(p), 6))}")
        for w in previous:
            ids_ = lex.lookup(w)
            if ids_:
                nxt = ", ".join(f"{lex.word(i)} {p:.2f}" for i, p in lex.successors(ids_[0], 6))
                print(f"  after {w!r}: {nxt or '-'}")
        if problems:
            ok = False
            for p in problems:
                print(f"  PROBLEM: {p}")
        else:
            print("  OK")
    return ok


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lang", action="append", choices=sorted(LANGUAGES), help="build only these")
    parser.add_argument("--verify", action="store_true", help="only verify the existing files")
    parser.add_argument("--dump", metavar="DIR", help="write DIR/<id>.tsv with every word and its source")
    parser.add_argument("--processes", type=int, default=max(1, min(8, os.cpu_count() or 1)))
    args = parser.parse_args(argv)
    ids = args.lang or list(LANGUAGES)
    if not args.verify:
        os.makedirs(OUTPUT, exist_ok=True)
        for lang_id in ids:
            data, stats, final = build_language(LANGUAGES[lang_id], args.processes)
            path = os.path.join(OUTPUT, f"{lang_id}.kbdl")
            with open(path + ".tmp", "wb") as f:
                f.write(data)
            os.replace(path + ".tmp", path)
            log(f"[{lang_id}] wrote {len(data):,} bytes: " + ", ".join(f"{k} {v:,}" for k, v in stats.items()))
            if args.dump:
                os.makedirs(args.dump, exist_ok=True)
                with open(os.path.join(args.dump, f"{lang_id}.tsv"), "w", encoding="utf-8") as f:
                    for i, (form, z, source, _) in enumerate(final):
                        f.write(f"{i}\t{form}\t{z:.3f}\t{source}\n")
    return 0 if verify(ids) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
