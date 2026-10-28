"""Glasses Solver icon: bold wayfarer glasses, with a spark in one lens for the answer they find.

One idea, two elements, a silhouette that reads at 60 px, no text (Apple's icon guidance; SplitMetrics 2025).
Appearances follow iOS 18: colored background by default, dark background with the color in the foreground for
Dark, grayscale with a clear foreground for Tinted.

Usage: python tools/make_icon.py GlassesSolver/Assets.xcassets/AppIcon.appiconset   (needs Pillow and NumPy)
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled, downscaled to 1024
DY = 0.03  # a little below center: an object at the true middle looks high (optical center)


def gradient(top, bottom):
    y = np.linspace(0, 1, S)[:, None]
    col = (np.array(top)[None, :] * (1 - y) + np.array(bottom)[None, :] * y).astype(np.uint8)
    arr = np.zeros((S, S, 4), dtype=np.uint8)
    arr[:, :, :3] = col[:, None, :]
    arr[:, :, 3] = 255
    return Image.fromarray(arr, "RGBA")


def rounded(points, radius):
    """A polygon with soft corners: draw it, blur, threshold."""
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(points, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(radius))
    return m.point(lambda v: 255 if v > 128 else 0).filter(ImageFilter.GaussianBlur(1.5))


def lens(cx, flip):
    """Wayfarer lens: wide at the brow, tapering toward the cheek, outer corner lifted."""
    w, top, bot = S * 0.36, S * (0.36 + DY), S * (0.62 + DY)
    o = -1 if flip else 1  # outer side
    pts = [
        (cx - o * w * 0.50, top),           # inner top (by the bridge)
        (cx + o * w * 0.56, top - S * 0.012),  # outer top, lifted
        (cx + o * w * 0.44, bot - S * 0.03),   # outer bottom
        (cx - o * w * 0.40, bot),            # inner bottom
    ]
    return pts


def inset(points, k, drop):
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    return [(cx + (x - cx) * k, cy + (y - cy) * k + drop) for x, y in points]


def render(bg, frame, glass, spark, mono=False):
    img = gradient(*bg)

    left, right = lens(S * 0.31, flip=True), lens(S * 0.69, flip=False)
    frame_mask = Image.new("L", (S, S), 0)
    for pts in (left, right):
        frame_mask.paste(255, mask=rounded(pts, S * 0.03))
    # Bridge and brow: one bar across the top, the wayfarer's signature.
    bar = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bar).rounded_rectangle([S * 0.44, S * (0.37 + DY), S * 0.56, S * (0.43 + DY)], radius=S * 0.02, fill=255)
    frame_mask.paste(255, mask=bar)
    # Temple stubs at the outer corners.
    stubs = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(stubs)
    sd.rounded_rectangle([S * 0.07, S * (0.355 + DY), S * 0.16, S * (0.405 + DY)], radius=S * 0.02, fill=255)
    sd.rounded_rectangle([S * 0.84, S * (0.355 + DY), S * 0.93, S * (0.405 + DY)], radius=S * 0.02, fill=255)
    frame_mask.paste(255, mask=stubs)

    # Soft shadow under the frame, so it sits on the background.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (0, int(S * 0.02)), frame_mask)
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S * 0.025)))

    img.paste((*frame, 255), (0, 0), frame_mask)

    # Glass: inset from the frame, thicker at the brow.
    for pts in (left, right):
        g = rounded(inset(pts, 0.80, S * 0.012), S * 0.025)
        layer = gradient(*glass)
        img.paste(layer, (0, 0), g)
        # A diagonal glint across each lens.
        glint = Image.new("L", (S, S), 0)
        xs = [p[0] for p in pts]
        x0, x1 = min(xs), max(xs)
        ImageDraw.Draw(glint).polygon(
            [(x0 + (x1 - x0) * 0.18, S * (0.62 + DY)), (x0 + (x1 - x0) * 0.32, S * (0.62 + DY)),
             (x0 + (x1 - x0) * 0.62, S * (0.36 + DY)), (x0 + (x1 - x0) * 0.48, S * (0.36 + DY))], fill=38)
        glint = Image.composite(glint, Image.new("L", (S, S), 0), g)
        img.paste((255, 255, 255, 255), (0, 0), glint)

    # The spark: a four-point star in the right lens, the answer.
    cx, cy, R = S * 0.69, S * (0.49 + DY), S * 0.085
    star = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pts = []
    for i in range(8):
        r = R if i % 2 == 0 else R * 0.26
        a = np.pi / 2 * (i / 2)
        pts.append((cx + r * np.sin(a), cy - r * np.cos(a)))
    ImageDraw.Draw(star).polygon(pts, fill=(*spark, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - R * 1.2, cy - R * 1.2, cx + R * 1.2, cy + R * 1.2], fill=(*spark, 150))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.04)))
    img.alpha_composite(star.filter(ImageFilter.GaussianBlur(S * 0.004)))

    out = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    return out.convert("L").convert("RGB") if mono else out


if __name__ == "__main__":
    out = sys.argv[1]
    # Default: warm amber, black frames, a white spark.
    render(((255, 196, 84), (255, 128, 44)), (24, 22, 28), ((54, 52, 66), (16, 15, 20)), (255, 255, 255)).save(out + "/AppIcon.png")
    # Dark: dark background, the amber moves into the frames.
    render(((30, 28, 36), (8, 8, 11)), (255, 170, 64), ((40, 38, 48), (14, 13, 18)), (255, 236, 200)).save(out + "/AppIcon-Dark.png")
    # Tinted: light frames and spark on black, as a grayscale template.
    render(((10, 10, 10), (0, 0, 0)), (225, 225, 225), ((48, 48, 48), (20, 20, 20)), (255, 255, 255), mono=True).save(out + "/AppIcon-Tinted.png")
    print("ok")
