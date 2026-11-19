"""Regenerate the fork's image assets from the repository's Mist logo."""

import json
from array import array
from io import BytesIO
from pathlib import Path
import shutil
from statistics import median
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps, PngImagePlugin
import pymupdf


ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "mist/brand"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def smoothstep(value):
    value = max(0, min(1, value))
    return value * value * (3 - 2 * value)


def float_blur(image, radius):
    """Approximate a Gaussian with three separable box passes, without 8-bit rounding."""
    image = image.convert("F")
    box_radius = max(1, round((radius * radius + 0.25) ** 0.5 - 0.5))
    window = 2 * box_radius + 1
    for _ in range(3):
        for _ in range(2):
            width, height = image.size
            values = array("f", image.tobytes())
            result = array("f")
            for y in range(height):
                row = values[y * width:(y + 1) * width]
                padded = [row[0]] * box_radius + list(row) + [row[-1]] * box_radius
                total = sum(padded[:window])
                result.append(total / window)
                for incoming, outgoing in zip(padded[window:], padded):
                    total += incoming - outgoing
                    result.append(total / window)
            image = Image.frombytes("F", image.size, result.tobytes()).transpose(Image.Transpose.TRANSPOSE)
    return image


def extract_alpha(source):
    if "A" in source.getbands() or "transparency" in source.info:
        return source.convert("RGBA").getchannel("A")

    # Denoise before the alpha gain can amplify WebP blocks and speckles.
    pixel_scale = min(source.size) / 1600
    luminance = float_blur(ImageOps.grayscale(source), 4 * pixel_scale)
    # Separate the dark curl from the pale tile using Otsu's histogram split.
    histogram = luminance.convert("L").histogram()
    count = sum(histogram)
    total = sum(value * frequency for value, frequency in enumerate(histogram))
    weight = moment = 0
    best_score = -1
    threshold = 0
    for value, frequency in enumerate(histogram):
        weight += frequency
        moment += value * frequency
        if not weight or weight == count:
            continue
        score = weight * (count - weight) * (moment / weight - (total - moment) / (count - weight)) ** 2
        if score > best_score:
            best_score, threshold = score, value

    # Estimate the local gradient with a normalized large-radius blur that
    # excludes the curl. Restrict extraction to its expanded neighborhood so
    # the unrelated tile boundary cannot become a second foreground outline.
    small = luminance.copy()
    small.thumbnail((256, 256), Image.Resampling.LANCZOS)
    foreground = small.convert("L").point(lambda value: 255 if value <= threshold else 0)
    neighborhood = foreground.filter(ImageFilter.MaxFilter(21)).filter(
        ImageFilter.GaussianBlur(2.5)
    )
    # The white surround is not part of the tile's background gradient.
    tile = small.convert("L").point(lambda value: round(255 * (1 - smoothstep((value - 250) / 5))))
    background_mask = ImageChops.multiply(ImageOps.invert(neighborhood), tile)
    radius = max(3, min(small.size) * 0.06)
    weighted = Image.new("F", small.size)
    weighted.putdata([
        value * weight
        for value, weight in zip(array("f", small.tobytes()), background_mask.tobytes())
    ])
    weighted = float_blur(weighted, radius)
    weights = float_blur(background_mask, radius)
    background = Image.new("F", small.size)
    # Tiny weights need fractional precision: rounding either side of this
    # division to 8 bits creates bands and holes even on a perfectly smooth curl.
    background.putdata([
        min(255, value / weight) if weight > 1e-6 else 255
        for value, weight in zip(array("f", weighted.tobytes()), array("f", weights.tobytes()))
    ])
    background = background.resize(source.size, Image.Resampling.BILINEAR)
    difference = [
        max(0, background_value - value)
        for background_value, value in zip(array("f", background.tobytes()), array("f", luminance.tobytes()))
    ]
    # Suppress compression noise and interpolation residuals in the background.
    noise_floor = 5
    peak = max(difference)
    if peak <= noise_floor:
        raise ValueError("No dark glyph found; supply a transparent logo instead")
    alpha = Image.new("L", source.size)
    alpha.putdata([round(255 * smoothstep((value - noise_floor) / (peak - noise_floor))) for value in difference])
    feathered = ImageChops.multiply(
        alpha, neighborhood.resize(source.size, Image.Resampling.BICUBIC)
    )
    # Smooth the final alpha quantization after the nonlinear mapping.
    return feathered.filter(ImageFilter.GaussianBlur(2 * pixel_scale))


def colored_glyph(alpha, size, color):
    result = Image.new("RGBA", (size, size), (*color, 0))
    result.putalpha(alpha.resize((size, size), Image.Resampling.BICUBIC))
    return result


def write_framework_logos(square):
    directory = BRAND / "framework"
    directory.mkdir(exist_ok=True)
    colored_glyph(square, 192, (0, 0, 0)).save(directory / "glyph-mask.png")
    marker = PngImagePlugin.PngInfo()
    marker.add_text("mist-logo", "1")
    for name, sizes, color, opacity in [
        ("product-logo", (16, 32, 64), (80, 80, 80), 1),
        ("swirl-gray", (16, 32), (128, 134, 139), 1),
        ("swirl-faint", (16, 32), (0, 0, 0), 0.2),
    ]:
        for size in sizes:
            image = colored_glyph(square, size, color)
            image.putalpha(image.getchannel("A").point(lambda value: round(value * opacity)))
            image.save(directory / f"{name}-{size}.png", pnginfo=marker)

    font_path = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
    for width, height, gap in [(78, 32, 2), (155, 64, 4)]:
        for name, color in [("black", (0, 0, 0)), ("white", (255, 255, 255))]:
            image = Image.new("RGBA", (width, height))
            image.alpha_composite(colored_glyph(square, height, (0, 0, 0)))
            draw = ImageDraw.Draw(image)
            for size in range(int(height * 0.75), 0, -1):
                font = ImageFont.truetype(font_path, size)
                left, top, right, bottom = draw.textbbox((0, 0), "Mist", font=font)
                if right - left <= width - height - gap and bottom - top <= height:
                    break
            draw.text((height + gap - left, (height - (bottom - top)) // 2 - top),
                      "Mist", font=font, fill=(*color, 255))
            image.save(directory / f"wordmark-{name}-{width}x{height}.png", pnginfo=marker)
    print("Framework: 192 px mask; product: 16/32/64 px; swirls: 16/32 px; wordmarks: 78x32/155x64 px")


def write_app_icon(catalog, name):
    """Cut an app's gray-on-white art (`mist/brand/<name>-favicon.webp`) into its tab template and page favicon."""
    with Image.open(BRAND / f"{name}-favicon.webp") as source:
        pixel_scale = min(source.size) / 1600
        luminance = float_blur(ImageOps.grayscale(source), 4 * pixel_scale)
        values = array("f", luminance.tobytes())
        stroke = median(value for value in values if value < 240)
        noise = 3
        alpha = Image.new("L", source.size)
        alpha.putdata([
            round(255 * max(0, min(1, (255 - value - noise) / (255 - stroke - noise))))
            for value in values
        ])
        alpha = alpha.filter(ImageFilter.GaussianBlur(2 * pixel_scale))
        # Mail's source has faint specks along its top edge; bounding them would push the
        # envelope low in a too-tall square. Bound only clearly visible ink, plus the blur.
        bounds = alpha.point(lambda value: 255 if value >= 32 else 0).getbbox()
        if bounds is None:
            raise ValueError(f"{name} icon is fully transparent")
        margin = round(6 * pixel_scale)
        bounds = (max(0, bounds[0] - margin), max(0, bounds[1] - margin),
                  min(source.width, bounds[2] + margin), min(source.height, bounds[3] + margin))
        cropped = alpha.crop(bounds)
        padding = max(8, round(max(cropped.size) * 0.06))
        side = max(cropped.size) + 2 * padding
        square = Image.new("L", (side, side), 0)
        square.paste(cropped, ((side - cropped.width) // 2, (side - cropped.height) // 2))

    imageset = catalog / f"{name}-favicon.imageset"
    imageset.mkdir(exist_ok=True)
    images = []
    for scale in (1, 2, 3):
        filename = f"{name}@{scale}x.png"
        colored_glyph(square, 18 * scale, (0, 0, 0)).save(imageset / filename)
        images.append({"filename": filename, "idiom": "universal", "scale": f"{scale}x"})
    write_json(imageset / "Contents.json", {
        "images": images, "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"}
    })
    tile = catalog / f"{name}-tile.imageset"
    tile.mkdir(exist_ok=True)
    images = []
    for scale in (1, 2, 3):
        filename = f"{name}@{scale}x.png"
        colored_glyph(square, 32 * scale, (0, 0, 0)).save(tile / filename)
        images.append({"filename": filename, "idiom": "universal", "scale": f"{scale}x"})
    write_json(tile / "Contents.json", {
        "images": images, "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"}
    })
    favicon = catalog / f"{name}-page-favicon.imageset"
    favicon.mkdir(exist_ok=True)
    colored_glyph(square, 64, (128, 134, 139)).save(favicon / f"{name}.png")
    write_json(favicon / "Contents.json", {
        "images": [{"filename": f"{name}.png", "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1}
    })
    print(f"{name}: stroke luminance {stroke:.1f}; bounds {bounds}; template 18/36/54 px; favicon 64 px")


def main():
    if len(sys.argv) > 2:
        raise ValueError("Usage: make_brand_assets.sh [logo.png]")
    BRAND.mkdir(parents=True, exist_ok=True)
    logo = BRAND / "logo.png"
    if len(sys.argv) == 2:
        supplied = Path(sys.argv[1]).expanduser().resolve()
        if supplied != logo:
            shutil.copyfile(supplied, logo)

    with Image.open(logo) as source:
        source.load()
        alpha = extract_alpha(source)
        points = [(0.22, 0.22), (0.78, 0.78), (0.22, 0.78), (0.78, 0.22)]
        print("Source corner alpha:", [alpha.getpixel((round(x * source.width), round(y * source.height))) for x, y in points])
        bounds = alpha.getbbox()
        if bounds is None:
            raise ValueError("Logo is fully transparent")
        cropped = alpha.crop(bounds)
        # Leave room for the resampling filter even in the 35 px alert asset.
        padding = max(8, round(max(cropped.size) * 0.06))
        side = max(cropped.size) + 2 * padding
        square = Image.new("L", (side, side), 0)
        square.paste(cropped, ((side - cropped.width) // 2, (side - cropped.height) // 2))
        colored_glyph(square, side, (0, 0, 0)).save(BRAND / "glyph.png")
        print(f"Source: {source.size}; glyph bounds: {bounds}; padded glyph: {side}x{side}")

    write_framework_logos(square)

    icon = ROOT / "Resources/PhiIcon.icon"
    shutil.rmtree(icon / "Assets")
    (icon / "Assets").mkdir()
    colored_glyph(square, 1024, (110, 110, 110)).save(icon / "Assets/Mist.png")
    write_json(icon / "icon.json", {
        "fill": {"solid": "extended-gray:1.00000,1.00000"},
        "groups": [{
            "layers": [{"glass": False, "image-name": "Mist.png", "name": "Mist",
                        "position": {"scale": 0.8, "translation-in-points": [0, 0]}}],
            "shadow": {"kind": "neutral", "opacity": 0},
            "translucency": {"enabled": False, "value": 0}
        }],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}
    })

    catalog = ROOT / "Resources/Assets.xcassets"
    for name in ("clipboard", "mail"):
        write_app_icon(catalog, name)
    for name, height, variants, properties in [
        ("phi-alert-icon", 35, [("", (0, 0, 0))], {"template-rendering-intent": "template"}),
        ("native-NTP-icon", 58, [("light", (80, 80, 80)), ("dark", (210, 210, 210))], {}),
    ]:
        imageset = catalog / f"{name}.imageset"
        for old in imageset.iterdir():
            if old.is_file():
                old.unlink()
        images = []
        for appearance, color in variants:
            for scale in (1, 2, 3):
                filename = f"mist{'-' + appearance if appearance else ''}@{scale}x.png"
                colored_glyph(square, height * scale, color).save(imageset / filename)
                entry = {"filename": filename, "idiom": "universal", "scale": f"{scale}x"}
                if appearance == "dark":
                    entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
                images.append(entry)
        contents = {"images": images, "info": {"author": "xcode", "version": 1}}
        if properties:
            contents["properties"] = properties
        write_json(imageset / "Contents.json", contents)

    favicon = catalog / "side-tab/phi-default-favicon.imageset"
    for filename, color, opacity in [("Frame 9.png", (0, 0, 0), 0.2), ("Frame 10.png", (255, 255, 255), 0.4)]:
        image = colored_glyph(square, 512, color)
        image.putalpha(image.getchannel("A").point(lambda value: round(value * opacity)))
        image.save(favicon / filename)

    preview = catalog / "Settings/newtab-ntp.imageset"
    for old in preview.iterdir():
        if old.is_file():
            old.unlink()
    images = []
    for appearance, color in [("light", (0, 0, 0)), ("dark", (255, 255, 255))]:
        with pymupdf.open(BRAND / f"templates/newtab-{appearance}.pdf") as document:
            for scale in (1, 2, 3):
                pixmap = document[0].get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=True)
                image = Image.open(BytesIO(pixmap.tobytes("png"))).convert("RGBA")
                # The original mark occupies (90, 28.5)-(104, 44.5) pt. Restore
                # its flat background, retaining the surrounding page and search field.
                background = image.getpixel((80 * scale, 36 * scale))
                image.paste(background, (88 * scale, 27 * scale, 106 * scale, 46 * scale))
                mark = colored_glyph(square, 16 * scale, color)
                mark.putalpha(mark.getchannel("A").point(lambda value: round(value * 0.28)))
                image.alpha_composite(mark, (89 * scale, round(28.5 * scale)))
                filename = f"mist-{appearance}@{scale}x.png"
                image.save(preview / filename)
                entry = {"filename": filename, "idiom": "universal", "scale": f"{scale}x"}
                if appearance == "dark":
                    entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
                images.append(entry)
    write_json(preview / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})
    print("Icon layer: 1024x1024 at 80%; alert: 35/70/105 px; NTP: 58/116/174 px (light and dark)")
    print("App tiles: 32/64/96 px; favicon: 512 px; settings: 32/64/96 px; preview: 194x112 pt at 1x/2x/3x")


if __name__ == "__main__":
    main()
