"""Generate Relay's 1024x1024 App Icon (obsidian layered-glass geometric monogram).

Usage:  python ios/scripts/generate_icon.py
Requires Pillow + numpy. Renders at 2x and downsamples with Lanczos for clean edges.
Output is RGB (no alpha) as required by App Store / Xcode.
"""
from __future__ import annotations

import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # supersampled canvas
OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "Relay",
    "Assets.xcassets",
    "AppIcon.appiconset",
    "AppIcon-1024.png",
)


def lerp(a, b, t):
    return a + (b - a) * t


def hex_rgb(h: str):
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def radial(size, cx, cy, radius, color, strength):
    """Soft radial glow layer as float array HxWx4 (premultiplied-ish)."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / radius
    a = np.clip(1.0 - d, 0, 1) ** 2.2 * strength
    rgb = np.array(color, dtype=np.float32)[None, None, :] / 255.0
    return rgb, a[..., None]


def composite(base, rgb, alpha):
    return base * (1 - alpha) + rgb * alpha


def background():
    y = np.linspace(0, 1, S, dtype=np.float32)[:, None]
    top = np.array(hex_rgb("#12121A"), np.float32) / 255
    bot = np.array(hex_rgb("#040406"), np.float32) / 255
    base = top[None, None, :] * (1 - y[..., None]) + bot[None, None, :] * y[..., None]
    base = np.broadcast_to(base, (S, S, 3)).copy()

    for (cx, cy, r, col, st) in [
        (S * 0.22, S * 0.18, S * 0.85, hex_rgb("#5B5FE0"), 0.55),
        (S * 0.92, S * 0.95, S * 0.70, hex_rgb("#0F9D84"), 0.30),
        (S * 0.70, S * 0.10, S * 0.45, hex_rgb("#A7B0FF"), 0.12),
    ]:
        rgb, a = radial(S, cx, cy, r, col, st)
        base = composite(base, rgb, a)

    # fine film grain for tactility
    rng = np.random.default_rng(7)
    grain = rng.normal(0, 0.012, (S, S, 1)).astype(np.float32)
    base = np.clip(base + grain, 0, 1)
    return Image.fromarray((base * 255).astype(np.uint8), "RGB")


def rounded_mask(box, radius, angle=0.0):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    if angle:
        cx = (box[0] + box[2]) / 2
        cy = (box[1] + box[3]) / 2
        m = m.rotate(angle, resample=Image.BICUBIC, center=(cx, cy))
    return m


def linear_gradient(c1, c2, a1, a2, direction=(1, 1)):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    t = (x * direction[0] + y * direction[1]) / (abs(direction[0]) + abs(direction[1]))
    t = np.clip(t, 0, 1)[..., None]
    c1 = np.array(c1, np.float32) / 255
    c2 = np.array(c2, np.float32) / 255
    rgb = c1 * (1 - t) + c2 * t
    a = (a1 * (1 - t[..., 0]) + a2 * t[..., 0])[..., None]
    return rgb, a


def glass_pane(img: Image.Image, box, radius, angle, tint, tint_alpha, blur=28):
    mask = rounded_mask(box, radius, angle)
    # frosted: blur what is underneath
    blurred = img.filter(ImageFilter.GaussianBlur(blur))
    img = Image.composite(blurred, img, mask)

    base = np.asarray(img).astype(np.float32) / 255
    m = np.asarray(mask).astype(np.float32)[..., None] / 255

    rgb, a = linear_gradient(tint, (255, 255, 255), tint_alpha, tint_alpha * 0.35, (-1, -1))
    base = composite(base, rgb, a * m)

    # inner sheen: top-left brighter
    rgb2, a2 = linear_gradient((255, 255, 255), (255, 255, 255), 0.10, 0.0, (1, 1.4))
    base = composite(base, rgb2, a2 * m)

    img = Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB")

    # specular hairline rim (brighter on top-left)
    edge = mask.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(1.2))
    edge_np = np.asarray(edge).astype(np.float32) / 255
    _, rim_a = linear_gradient((255, 255, 255), (255, 255, 255), 0.95, 0.12, (1, 1))
    rim = np.clip(edge_np[..., None] * 3.2, 0, 1) * rim_a
    base = np.asarray(img).astype(np.float32) / 255
    base = composite(base, np.ones(3, np.float32), rim)
    return Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB")


def drop_shadow(img: Image.Image, box, radius, angle, offset=(0, 40), blur=70, opacity=0.55):
    sh = rounded_mask(
        (box[0] + offset[0], box[1] + offset[1], box[2] + offset[0], box[3] + offset[1]),
        radius,
        angle,
    ).filter(ImageFilter.GaussianBlur(blur))
    black = Image.new("RGB", (S, S), (0, 0, 0))
    sh = sh.point(lambda v: int(v * opacity))
    return Image.composite(black, img, sh)


def monogram_mask():
    """Geometric 'R': stem + bowl ring + diagonal leg, all round-capped."""
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    w = 124  # stroke weight
    cx, cy = S * 0.555, S * 0.555
    left = cx - 270
    top = cy - 360
    bottom = cy + 360
    bowl_h = 430  # outer height of the bowl
    bowl_right = cx + 210

    # outer D (soft top-left corner, fully round right side)
    d.rounded_rectangle((left, top, bowl_right - bowl_h / 2 + 2, top + bowl_h), radius=56, corners=(True, False, False, True), fill=255)
    d.ellipse((bowl_right - bowl_h, top, bowl_right, top + bowl_h), fill=255)
    # carve inner counter
    ih = bowl_h - 2 * w
    d.rounded_rectangle(
        (left + w, top + w, bowl_right - w, top + w + ih),
        radius=ih / 2 - 1,
        corners=(False, True, True, False),
        fill=0,
    )
    # stem with rounded foot
    d.rounded_rectangle((left, top + 40, left + w, bottom), radius=w / 2, corners=(False, False, True, True), fill=255)
    d.rectangle((left, top + 40, left + w, bottom - w / 2), fill=255)

    # leg: starts inside the bowl's lower bar, ends at a relay node
    x0, y0 = cx - 10, top + bowl_h - w / 2
    x1, y1 = bowl_right - 20, bottom - 40
    d.line((x0, y0, x1, y1), fill=255, width=int(w))
    d.ellipse((x0 - w / 2, y0 - w / 2, x0 + w / 2, y0 + w / 2), fill=255)
    return m, (x1, y1), (bowl_right, top + bowl_h / 2)


def main():
    img = background()

    back_box = (S * 0.17, S * 0.15, S * 0.70, S * 0.68)
    front_box = (S * 0.27, S * 0.27, S * 0.84, S * 0.84)

    img = drop_shadow(img, back_box, 190, -8, blur=80, opacity=0.6)
    img = glass_pane(img, back_box, 190, -8, hex_rgb("#6E73F0"), 0.38, blur=18)

    img = drop_shadow(img, front_box, 210, 0, offset=(0, 50), blur=90, opacity=0.7)
    img = glass_pane(img, front_box, 210, 0, hex_rgb("#1A1B26"), 0.62, blur=40)

    # monogram with porcelain gradient + soft luminous halo
    mono, leg_end, bowl_edge = monogram_mask()
    halo = mono.filter(ImageFilter.GaussianBlur(48)).point(lambda v: int(v * 0.55))
    halo_col = Image.new("RGB", (S, S), hex_rgb("#8E9BFF"))
    img = Image.composite(halo_col, img, halo)

    rgb, _ = linear_gradient(hex_rgb("#FFFFFF"), hex_rgb("#C9CCE6"), 1, 1, (0.4, 1))
    porcelain = Image.fromarray((rgb * 255).astype(np.uint8), "RGB")
    img = Image.composite(porcelain, img, mono)

    # relay node: luminous dot at the leg terminal
    lx, ly = leg_end
    node = Image.new("L", (S, S), 0)
    r = 96
    ImageDraw.Draw(node).ellipse((lx - r, ly - r, lx + r, ly + r), fill=255)
    node_glow = node.filter(ImageFilter.GaussianBlur(40))
    img = Image.composite(Image.new("RGB", (S, S), hex_rgb("#7CF5D3")), img, node_glow.point(lambda v: int(v * 0.7)))
    rgbn, _ = linear_gradient(hex_rgb("#B9FFF0"), hex_rgb("#2BD4A8"), 1, 1, (1, 1))
    img = Image.composite(Image.fromarray((rgbn * 255).astype(np.uint8), "RGB"), img, node)

    # subtle vignette
    base = np.asarray(img).astype(np.float32) / 255
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    d = np.sqrt((x - S / 2) ** 2 + (y - S / 2) ** 2) / (S * 0.75)
    vig = 1 - np.clip(d - 0.55, 0, 1) * 0.55
    base = base * vig[..., None]
    img = Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB")

    img = img.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, "PNG", optimize=True)
    print("wrote", os.path.normpath(OUT), img.size, img.mode)


if __name__ == "__main__":
    main()
