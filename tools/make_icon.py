"""Generate WatchLoader's app icon (light, dark, tinted) into App/Assets.xcassets/AppIcon.appiconset.

    python -I tools/make_icon.py [--preview out.png]

Design: an Apple Watch with a download arrow on its screen, on an indigo -> teal gradient.
Rendered at 4x and downsampled for smooth edges.
"""
import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
K = 4  # supersampling
W = S * K
OUT = pathlib.Path(__file__).resolve().parent.parent / "App" / "Assets.xcassets"

INDIGO = (79, 70, 229)
VIOLET = (124, 58, 237)
TEAL = (20, 184, 166)
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, stops):
    """Diagonal (top-left -> bottom-right) gradient through the given colour stops."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    n = len(stops) - 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            i = min(int(t * n), n - 1)
            px[x, y] = lerp(stops[i], stops[i + 1], t * n - i)
    return g


def big_gradient(stops):
    # compute small then upscale (smooth, fast)
    return gradient(256, stops).resize((W, W), Image.BICUBIC)


def glyph_mask():
    """White-on-black mask of the watch + arrow, and a separate mask of the screen."""
    m = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(m)
    cx, cy = W // 2, W // 2 + 10 * K

    # bands (top & bottom), slightly narrower than the case
    bw, bh = 300 * K, 250 * K
    d.rounded_rectangle([cx - bw // 2, cy - 330 * K - bh // 2, cx + bw // 2, cy - 330 * K + bh // 2], 60 * K, fill=150)
    d.rounded_rectangle([cx - bw // 2, cy + 330 * K - bh // 2, cx + bw // 2, cy + 330 * K + bh // 2], 60 * K, fill=150)

    # case
    cw, ch = 470 * K, 540 * K
    case = [cx - cw // 2, cy - ch // 2, cx + cw // 2, cy + ch // 2]
    d.rounded_rectangle(case, 140 * K, fill=255)
    # crown + side button
    d.rounded_rectangle([cx + cw // 2 - 10 * K, cy - 120 * K, cx + cw // 2 + 46 * K, cy - 20 * K], 22 * K, fill=255)
    d.rounded_rectangle([cx + cw // 2 - 10 * K, cy + 30 * K, cx + cw // 2 + 26 * K, cy + 130 * K], 14 * K, fill=255)

    # screen
    s = Image.new("L", (W, W), 0)
    sd = ImageDraw.Draw(s)
    pad = 46 * K
    screen = [case[0] + pad, case[1] + pad, case[2] - pad, case[3] - pad]
    sd.rounded_rectangle(screen, 100 * K, fill=255)

    # download arrow (drawn on its own mask)
    a = Image.new("L", (W, W), 0)
    ad = ImageDraw.Draw(a)
    shaft_w = 64 * K
    top, tip = cy - 165 * K, cy + 95 * K
    ad.rounded_rectangle([cx - shaft_w // 2, top, cx + shaft_w // 2, tip - 60 * K], shaft_w // 2, fill=255)
    head = 140 * K
    ad.polygon([(cx - head, tip - 120 * K), (cx + head, tip - 120 * K), (cx, tip + 10 * K)], fill=255)
    ad.rounded_rectangle([cx - 140 * K, cy + 160 * K, cx + 140 * K, cy + 160 * K + 42 * K], 21 * K, fill=255)
    a = a.filter(ImageFilter.GaussianBlur(3 * K))
    return m, s, a


def compose(variant):
    body, screen, arrow = glyph_mask()
    if variant == "light":
        img = big_gradient([INDIGO, VIOLET, TEAL]).convert("RGBA")
        # soft highlight top-left
        glow = Image.new("L", (W, W), 0)
        ImageDraw.Draw(glow).ellipse([-W // 3, -W // 3, W // 1.6, W // 1.6], fill=70)
        img = Image.composite(Image.new("RGBA", (W, W), WHITE + (255,)), img, glow.filter(ImageFilter.GaussianBlur(160 * K)))
        shadow = body.filter(ImageFilter.GaussianBlur(28 * K)).point(lambda v: v * 0.45)
        img = Image.composite(Image.new("RGBA", (W, W), (20, 10, 60, 255)), img, shadow.transform((W, W), Image.AFFINE, (1, 0, 0, 0, 1, -24 * K)))
        img = Image.composite(Image.new("RGBA", (W, W), WHITE + (255,)), img, body)
        scr = big_gradient([(17, 24, 39), (30, 27, 75)]).convert("RGBA")
        img = Image.composite(scr, img, screen)
        arr = big_gradient([(94, 234, 212), (165, 180, 252)]).convert("RGBA")
        img = Image.composite(arr, img, arrow)
        return img.convert("RGB")
    if variant == "dark":
        img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        grad = big_gradient([(129, 140, 248), (45, 212, 191)]).convert("RGBA")
        img = Image.composite(grad, img, body)
        img = Image.composite(Image.new("RGBA", (W, W), (12, 12, 20, 255)), img, screen)
        img = Image.composite(big_gradient([(94, 234, 212), (165, 180, 252)]).convert("RGBA"), img, arrow)
        return img
    if variant == "tinted":
        img = Image.new("RGB", (W, W), (0, 0, 0))
        img = Image.composite(Image.new("RGB", (W, W), (235, 235, 235)), img, body)
        img = Image.composite(Image.new("RGB", (W, W), (40, 40, 40)), img, screen)
        img = Image.composite(Image.new("RGB", (W, W), (255, 255, 255)), img, arrow)
        return img.convert("L")
    raise ValueError(variant)


def main():
    iconset = OUT / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    files = {"light": "AppIcon.png", "dark": "AppIcon-dark.png", "tinted": "AppIcon-tinted.png"}
    rendered = {}
    for variant, name in files.items():
        img = compose(variant).resize((S, S), Image.LANCZOS)
        img.save(iconset / name, optimize=True)
        rendered[variant] = img
        print("wrote", iconset / name)

    images = [{"filename": files["light"], "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    for v in ("dark", "tinted"):
        images.append({
            "appearances": [{"appearance": "luminosity", "value": v}],
            "filename": files[v], "idiom": "universal", "platform": "ios", "size": "1024x1024",
        })
    (iconset / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
    (OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

    if "--preview" in sys.argv:
        out = pathlib.Path(sys.argv[sys.argv.index("--preview") + 1])
        tile, gap = 300, 40
        sheet = Image.new("RGB", (tile * 3 + gap * 4, tile + gap * 2 + 40), (242, 242, 247))
        bgs = {"light": (242, 242, 247), "dark": (28, 28, 30), "tinted": (28, 28, 30)}
        draw = ImageDraw.Draw(sheet)
        for i, v in enumerate(("light", "dark", "tinted")):
            x = gap + i * (tile + gap)
            sheet.paste(Image.new("RGB", (tile + 20, tile + 20), bgs[v]), (x - 10, gap - 10))
            icon = rendered[v].convert("RGBA").resize((tile, tile), Image.LANCZOS)
            if v == "dark":
                base = Image.new("RGBA", (tile, tile), (20, 20, 22, 255))
                icon = Image.alpha_composite(base, icon)
            if v == "tinted":
                tint = Image.new("RGBA", (tile, tile), (120, 170, 255, 255))
                icon = Image.composite(tint, Image.new("RGBA", (tile, tile), (20, 20, 22, 255)), rendered[v].resize((tile, tile)))
            mask = Image.new("L", (tile, tile), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, tile - 1, tile - 1], int(tile * 0.225), fill=255)
            sheet.paste(icon, (x, gap), mask)
            draw.text((x + tile // 2 - 20, gap + tile + 12), v.title(), fill=(60, 60, 67))
        sheet.save(out)
        print("preview", out)


if __name__ == "__main__":
    main()
