#!/usr/bin/env python3
"""Generate front-facing Termind device mockups using MockUPhone templates.

Raw screenshots are read-only inputs. Framed outputs are written alongside them
with a ``-framed.png`` suffix so the source captures remain available.
"""

from __future__ import annotations

import io
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps


REPOSITORY = Path(__file__).resolve().parents[1]
SCREENSHOTS = REPOSITORY / "LandingPage" / "public" / "screenshots"
CACHE = REPOSITORY / ".build" / "mockuphone-assets"
MOCKUPHONE = "https://mockuphone.com/images"
FEATURES = ("vault", "sftp", "ssh", "metrics", "assistant")
LOCALES = ("en", "zh-hans", "zh-hant")


@dataclass(frozen=True)
class Device:
    name: str
    asset: str
    screen_size: tuple[int, int]
    screen_origin: tuple[int, int]
    canvas_size: tuple[int, int]


IPHONE = Device(
    name="iPhone 15 Pro Max",
    asset="apple-iphone-15-pro-max-black-titanium-portrait.png",
    screen_size=(1290, 2796),
    screen_origin=(120, 120),
    canvas_size=(1530, 3036),
)
IPAD = Device(
    name='iPad Pro 13"',
    asset="apple-ipadpro13-spacegrey-landscape.png",
    screen_size=(2732, 2048),
    screen_origin=(113, 120),
    canvas_size=(2960, 2290),
)
MAC = Device(
    name='MacBook Pro 16"',
    asset="apple-macbookpro16-front.png",
    screen_size=(3456, 2234),
    screen_origin=(441, 312),
    canvas_size=(4340, 2860),
)


def template(device: Device, kind: str) -> Image.Image:
    CACHE.mkdir(parents=True, exist_ok=True)
    destination = CACHE / f"{kind}-{device.asset}"
    if not destination.exists():
        url = f"{MOCKUPHONE}/{kind}_templates/{device.asset}"
        with urllib.request.urlopen(url) as response:
            destination.write_bytes(response.read())
    image = Image.open(destination).convert("RGBA")
    if image.size != device.canvas_size:
        raise ValueError(f"Unexpected {device.name} template size: {image.size}")
    return image


def fit_screen(source: Path, size: tuple[int, int]) -> Image.Image:
    with Image.open(source) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGBA")
    scale = min(size[0] / image.width, size[1] / image.height)
    image = image.resize(
        (round(image.width * scale), round(image.height * scale)),
        Image.Resampling.LANCZOS,
    )
    fitted = Image.new("RGBA", size, (0, 0, 0, 255))
    fitted.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return fitted


def original_wallpaper(size: tuple[int, int]) -> Image.Image:
    width, height = size
    desktop = Image.new("RGBA", size)
    draw = ImageDraw.Draw(desktop)
    top = (22, 76, 100)
    bottom = (7, 35, 55)
    for y in range(height):
        amount = y / max(height - 1, 1)
        color = tuple(round(a + (b - a) * amount) for a, b in zip(top, bottom))
        draw.line((0, y, width, y), fill=(*color, 255))

    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        (-round(width * 0.30), -round(height * 0.55), round(width * 0.62), round(height * 0.85)),
        fill=(54, 201, 239, 190),
    )
    glow_draw.ellipse(
        (round(width * 0.52), -round(height * 0.18), round(width * 1.18), round(height * 0.78)),
        fill=(39, 119, 181, 155),
    )
    glow_draw.ellipse(
        (round(width * 0.62), round(height * 0.58), round(width * 1.06), round(height * 1.18)),
        fill=(235, 144, 111, 80),
    )
    desktop.alpha_composite(glow.filter(ImageFilter.GaussianBlur(round(width * 0.12))))

    grain = Image.effect_noise(size, 18).convert("L")
    grain_layer = Image.new("RGBA", size, (255, 255, 255, 0))
    grain_layer.putalpha(grain.point(lambda value: round(value * 0.055)))
    desktop.alpha_composite(grain_layer)
    return desktop


def mac_desktop(source: Path, size: tuple[int, int]) -> Image.Image:
    desktop = original_wallpaper(size)
    with Image.open(source) as opened:
        window = ImageOps.exif_transpose(opened).convert("RGBA")

    # Make the app the clear subject while retaining enough wallpaper to read
    # as a Mac desktop. The original screenshot is never cropped.
    scale = min(size[0] * 0.91 / window.width, size[1] * 0.88 / window.height)
    window = window.resize(
        (round(window.width * scale), round(window.height * scale)),
        Image.Resampling.LANCZOS,
    )
    origin = ((size[0] - window.width) // 2, (size[1] - window.height) // 2)
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    shadow.alpha_composite(Image.new("RGBA", window.size, (16, 29, 40, 110)), origin)
    shadow.putalpha(shadow.getchannel("A").filter(ImageFilter.GaussianBlur(34)))
    desktop.alpha_composite(shadow)
    desktop.alpha_composite(window, origin)
    return desktop


def generate(source: Path, destination: Path, device: Device) -> None:
    device_mask = template(device, "mockup_mask")
    device_front = template(device, "mockup")
    screen = mac_desktop(source, device.screen_size) if device == MAC else fit_screen(source, device.screen_size)

    screen_layer = Image.new("RGBA", device.canvas_size, (0, 0, 0, 0))
    screen_layer.alpha_composite(screen, device.screen_origin)

    # This mirrors MockUPhone's front-device pipeline: constrain the inserted
    # image to the supplied device mask, then place the bezel above it.
    constrained = Image.composite(screen_layer, device_mask, device_mask.getchannel("A"))
    constrained.alpha_composite(device_front)
    destination.parent.mkdir(parents=True, exist_ok=True)
    constrained.save(destination, format="PNG", optimize=True)


def mobile_sources(device_name: str):
    for feature in FEATURES:
        for locale in LOCALES:
            source = SCREENSHOTS / feature / f"{device_name}-{locale}.png"
            yield source, source.with_name(f"{device_name}-{locale}-framed.png")


def main() -> int:
    jobs = [
        *((source, destination, IPHONE) for source, destination in mobile_sources("iphone")),
        *((source, destination, IPAD) for source, destination in mobile_sources("ipad")),
        *((
            SCREENSHOTS / "workspace" / f"mac-{locale}.png",
            SCREENSHOTS / "workspace" / f"mac-{locale}-framed.png",
            MAC,
        ) for locale in LOCALES),
    ]
    missing = [source for source, _, _ in jobs if not source.exists()]
    if missing:
        print("Missing raw screenshots:", file=sys.stderr)
        for source in missing:
            print(f"  {source}", file=sys.stderr)
        return 66

    for source, destination, device in jobs:
        generate(source, destination, device)
        print(f"Generated {destination.relative_to(REPOSITORY)} ({device.name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
