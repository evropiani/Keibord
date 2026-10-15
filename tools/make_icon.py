#!/usr/bin/env python3
"""Re-centres the Keibord logo and writes the app icon + logo assets."""
import json, os
from PIL import Image, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "data", "logo-source.jpg")
ASSETS = os.path.join(ROOT, "App", "Assets.xcassets")


def main():
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    px = im.load()
    corners = [px[5, 5], px[w - 6, 5], px[5, h - 6], px[w - 6, h - 6]]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    xs, ys = [], []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            if b > bg[2] + 25 and b > r + 15:
                xs.append(x)
                ys.append(y)
    box = (min(xs), min(ys), max(xs), max(ys))
    margin = 60
    crop = im.crop((box[0] - margin, box[1] - margin, box[2] + margin, box[3] + margin))
    size = 1024
    scale = size * 0.84 / crop.width
    crop = crop.resize((round(crop.width * scale), round(crop.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGB", (size, size), bg)
    canvas.paste(crop, ((size - crop.width) // 2, (size - crop.height) // 2))
    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    canvas.save(os.path.join(icon_dir, "AppIcon-1024.png"))
    ImageOps.grayscale(canvas).convert("RGB").save(os.path.join(icon_dir, "AppIcon-1024-tinted.png"))
    json.dump({
        "images": [
            {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-1024-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, open(os.path.join(icon_dir, "Contents.json"), "w"), indent=2)
    logo_dir = os.path.join(ASSETS, "Logo.imageset")
    os.makedirs(logo_dir, exist_ok=True)
    canvas.resize((360, 360), Image.LANCZOS).save(os.path.join(logo_dir, "Logo.png"))
    json.dump({"images": [{"filename": "Logo.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}},
              open(os.path.join(logo_dir, "Contents.json"), "w"), indent=2)
    accent_dir = os.path.join(ASSETS, "AccentColor.colorset")
    os.makedirs(accent_dir, exist_ok=True)
    json.dump({"colors": [{"color": {"color-space": "srgb", "components": {"red": "0.329", "green": "0.443", "blue": "0.776", "alpha": "1.000"}}, "idiom": "universal"}],
               "info": {"author": "xcode", "version": 1}}, open(os.path.join(accent_dir, "Contents.json"), "w"), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(ASSETS, "Contents.json"), "w"), indent=2)
    print("bbox", box, "background", bg)


if __name__ == "__main__":
    main()
