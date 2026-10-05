"""Generate all Android launcher icon densities from the WASL source icon."""
import os
from PIL import Image, ImageDraw

SRC = r"D:\WORK\WASL\wasl_app\vibe_images\wasl_app_icon_1789772963360_4434d073.png"
RES = r"D:\WORK\WASL\wasl_app\android\app\src\main\res"

img = Image.open(SRC).convert("RGBA")
W, H = img.size
px = img.load()

def is_teal(p):
    r, g, b = p[0], p[1], p[2]
    return g - r > 20 and g - b > -30 and r < 160

# Bounding box of the teal rounded square (ignores gray bg + shadow)
min_x, min_y, max_x, max_y = W, H, 0, 0
for y in range(H):
    for x in range(W):
        if is_teal(px[x, y]):
            if x < min_x: min_x = x
            if x > max_x: max_x = x
            if y < min_y: min_y = y
            if y > max_y: max_y = y

sq = img.crop((min_x, min_y, max_x + 1, max_y + 1))
sw, sh = sq.size
sq = sq.resize((1024, 1024), Image.LANCZOS)
print(f"square bounds: {min_x},{min_y} -> {max_x},{max_y} ({sw}x{sh})")

# Corner radius: first teal pixel on the very top row of the square
sp = sq.load()
radius = 0
for x in range(1024):
    if is_teal(sp[x, 0]):
        radius = x
        break
radius = int(radius * 1.15)  # slight over-round to hide anti-alias seams
print(f"corner radius: {radius}")

# Sample gradient colors (center column, near top and bottom, teal rows)
def sample_tall_color(y_from, y_to, x):
    rs = gs = bs = n = 0
    for y in range(y_from, y_to):
        p = sp[x, y]
        if is_teal(p):
            rs += p[0]; gs += p[1]; bs += p[2]; n += 1
    if n == 0: return None
    return (rs // n, gs // n, bs // n)

top_c = sample_tall_color(10, 60, 512)
bot_c = sample_tall_color(964, 1014, 512)
print("gradient:", top_c, "->", bot_c)

# ---------- legacy + round icons ----------
def rounded_mask(size, r):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m

def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([0, 0, size - 1, size - 1], fill=255)
    return m

densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
for d, size in densities.items():
    r = max(2, round(radius * size / 1024))
    legacy = sq.resize((size, size), Image.LANCZOS)
    legacy.putalpha(rounded_mask(size, r))
    legacy.save(os.path.join(RES, f"mipmap-{d}", "ic_launcher.png"))

    rnd = sq.resize((size, size), Image.LANCZOS)
    rnd.putalpha(circle_mask(size))
    rnd.save(os.path.join(RES, f"mipmap-{d}", "ic_launcher_round.png"))

# ---------- adaptive icons (Android 8+) ----------
fg_sizes = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
for d, size in fg_sizes.items():
    # Foreground: artwork fills the whole 108dp canvas; the launcher mask
    # (max 72dp circle) only ever shows the central gradient + bubble.
    fg = sq.resize((size, size), Image.LANCZOS)
    fg.save(os.path.join(RES, f"mipmap-{d}", "ic_launcher_foreground.png"))

    # Background: matching vertical gradient, full-bleed
    bg = Image.new("RGB", (size, size))
    bp = bg.load()
    tc = top_c or (0, 125, 120)
    bc = bot_c or (0, 70, 60)
    for y in range(size):
        t = y / max(1, size - 1)
        col = tuple(round(tc[i] + (bc[i] - tc[i]) * t) for i in range(3))
        for x in range(size):
            bp[x, y] = col
    bg.save(os.path.join(RES, f"mipmap-{d}", "ic_launcher_background.png"))

# anydpi-v26 adaptive icon XMLs
anydpi = os.path.join(RES, "mipmap-anydpi-v26")
os.makedirs(anydpi, exist_ok=True)
xml = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n'
)
with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
    f.write(xml)
with open(os.path.join(anydpi, "ic_launcher_round.xml"), "w", encoding="utf-8") as f:
    f.write(xml)

print("done: icons written to", RES)
