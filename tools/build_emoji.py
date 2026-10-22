#!/usr/bin/env python3
"""Builds Resources/Emoji/emoji.json and keywords-<lang>.json from Unicode emoji-test.txt (17.0)
and CLDR annotations. Downloads into tools/.cache (raw.githubusercontent.com)."""
import json, os, re, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", ".cache")
OUT = os.path.join(ROOT, "Resources", "Emoji")
RAW = "https://raw.githubusercontent.com/"
TEST = "unicode-org/unicodetools/main/unicodetools/data/emoji/17.0/emoji-test.txt"
ANN = "unicode-org/cldr-json/main/cldr-json/cldr-annotations-full/annotations/{}/annotations.json"
DER = "unicode-org/cldr-json/main/cldr-json/cldr-annotations-derived-full/annotationsDerived/{}/annotations.json"
LANGS = ["de", "en", "it", "sq"]
GROUPS = {
    "Smileys & Emotion": "smileys_people", "People & Body": "smileys_people",
    "Animals & Nature": "animals_nature", "Food & Drink": "food_drink", "Activities": "activity",
    "Travel & Places": "travel_places", "Objects": "objects", "Symbols": "symbols", "Flags": "flags",
}
TONES = re.compile("[\U0001F3FB-\U0001F3FF]")


def fetch(path):
    local = os.path.join(CACHE, path)
    if not os.path.exists(local):
        os.makedirs(os.path.dirname(local), exist_ok=True)
        urllib.request.urlretrieve(RAW + path, local)
    with open(local, encoding="utf-8") as f:
        return f.read()


TONE_NAMES = re.compile(r"(?::\s*|,\s*)(?:light|medium-light|medium|medium-dark|dark) skin tone")


def strip_tones(e):
    return TONES.sub("", e)


def grid_base(emoji, name, names, by_name):
    """The grid emoji a toned sequence belongs to. Usually the sequence without its modifiers, but
    mixed tones of two people are written with other code points than the grid emoji ("🫱🏻‍🫲🏼" for
    🤝, "🧑🏻‍❤️‍💋‍🧑🏼" for 💏, "👩🏻‍🤝‍👩🏼" for 👭): those are found by their name ("handshake: light skin
    tone, medium-light skin tone" -> "handshake"; "kiss: person, person, …" -> "kiss")."""
    base = strip_tones(emoji)
    if base in names:
        return base
    plain = TONE_NAMES.sub("", name)
    return by_name.get(plain) or by_name.get(plain.split(":")[0])


def matrix_order(base, toned):
    """Variants of two people as a 5 x 5 grid in reading order (row = first person's tone, column =
    the second's; the diagonal is the form with one tone for both, e.g. "🤝🏽"); otherwise as listed."""
    def tones(e):
        t = [ord(c) - 0x1F3FB for c in e if TONES.match(c)]
        return (t[0], t[-1]) if t else None
    if len(toned) != 25:
        return toned
    cells = {}
    for e in toned:
        t = tones(e)
        if t is None or t in cells:
            return toned
        cells[t] = e
    if len(cells) != 25:
        return toned
    return [cells[(i, j)] for i in range(5) for j in range(5)]


def main():
    order, cats, variants, names, toned = [], {}, {}, {}, []
    group = None
    for line in fetch(TEST).splitlines():
        if line.startswith("# group:"):
            group = GROUPS.get(line.split(":", 1)[1].strip())
            continue
        if not line or line.startswith("#") or group is None:
            continue
        m = re.match(r"^([0-9A-F ]+);\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.*)$", line)
        if not m:
            continue
        emoji = "".join(chr(int(x, 16)) for x in m.group(1).split())
        name = m.group(3).strip().lower()
        if strip_tones(emoji) != emoji:
            toned.append((emoji, name))
            continue
        cats.setdefault(group, []).append(emoji)
        names[emoji] = name
    by_name = {}
    for e, n in names.items():
        by_name.setdefault(n, e)
    for emoji, name in toned:
        base = grid_base(emoji, name, names, by_name)
        if base is not None:
            variants.setdefault(base, []).append(emoji)
    variants = {b: matrix_order(b, v) for b, v in variants.items()}
    order = ["smileys_people", "animals_nature", "food_drink", "activity", "travel_places", "objects", "symbols", "flags"]
    os.makedirs(OUT, exist_ok=True)
    data = {"version": "17.0", "categories": [{"id": c, "emojis": cats[c]} for c in order],
            "variants": {b: v for b, v in variants.items() if b in names}}
    with open(os.path.join(OUT, "emoji.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    for lang in LANGS:
        table = {}
        for src in (ANN, DER):
            ann = json.loads(fetch(src.format(lang)))
            root = ann.get("annotations") or ann.get("annotationsDerived") or {}
            for e, v in root.get("annotations", {}).items():
                words = [w.lower() for w in v.get("tts", [])] + [w.lower() for w in v.get("default", [])]
                table.setdefault(e, [])
                for w in words:
                    if w not in table[e]:
                        table[e].append(w)
        out = {}
        for e in names:
            key = e if e in table else e.replace("️", "")
            words = table.get(key) or ([names[e]] if lang == "en" else [])
            if words:
                out[e] = words
        with open(os.path.join(OUT, f"keywords-{lang}.json"), "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        print(lang, len(out), "emoji with keywords")
    print("categories:", {c: len(cats[c]) for c in order}, "variants:", len(data["variants"]))


if __name__ == "__main__":
    main()
