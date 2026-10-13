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


def strip_tones(e):
    return TONES.sub("", e)


def main():
    order, cats, variants, names = [], {}, {}, {}
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
        base = strip_tones(emoji)
        if base != emoji:
            variants.setdefault(base, []).append(emoji)
            continue
        cats.setdefault(group, []).append(emoji)
        names[emoji] = m.group(3).strip().lower()
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
