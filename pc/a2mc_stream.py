#!/usr/bin/env python3
"""Stream tiny Minecraft-ish frames to an Apple II lo-res receiver."""

from __future__ import annotations

import argparse
import ctypes
import math
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence

MAGIC = b"\xA2MC\x01"
LORES_W = 40
LORES_H = 48
PAGE_SIZE = 1024

# Apple II lo-res color numbers, using pragmatic RGB approximations for mapping.
APPLE_PALETTE: tuple[tuple[int, int, int], ...] = (
    (0x00, 0x00, 0x00),  # 0 black
    (0x9D, 0x1B, 0x6C),  # 1 magenta
    (0x40, 0x2C, 0xB8),  # 2 dark blue
    (0xD6, 0x43, 0xFF),  # 3 purple
    (0x00, 0x7A, 0x3D),  # 4 dark green
    (0x80, 0x80, 0x80),  # 5 gray
    (0x2F, 0x95, 0xFF),  # 6 medium blue
    (0xBF, 0xD7, 0xFF),  # 7 light blue
    (0x6F, 0x4F, 0x1F),  # 8 brown
    (0xFF, 0x6A, 0x00),  # 9 orange
    (0xC0, 0xC0, 0xC0),  # A light gray
    (0xFF, 0xA0, 0xD0),  # B pink
    (0x2F, 0xD1, 0x41),  # C green
    (0xFF, 0xF0, 0x4A),  # D yellow
    (0x72, 0xFF, 0xB5),  # E aquamarine
    (0xFF, 0xFF, 0xFF),  # F white
)


@dataclass(frozen=True)
class Region:
    left: int
    top: int
    width: int
    height: int

    def as_mss(self) -> dict[str, int]:
        return {
            "left": self.left,
            "top": self.top,
            "width": self.width,
            "height": self.height,
        }


def text_page_offset(text_row: int, col: int) -> int:
    return (text_row & 0x07) * 0x80 + (text_row >> 3) * 0x28 + col


def checksum(payload: bytes | bytearray) -> int:
    value = 0
    for byte in payload:
        value ^= byte
    return value


def parse_region(value: str) -> Region:
    parts = [int(part.strip()) for part in value.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("region must be left,top,width,height")
    left, top, width, height = parts
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("region width and height must be positive")
    return Region(left, top, width, height)


def nearest_apple_color(rgb: Sequence[int], cache: dict[tuple[int, int, int], int]) -> int:
    key = (int(rgb[0]), int(rgb[1]), int(rgb[2]))
    cached = cache.get(key)
    if cached is not None:
        return cached

    r, g, b = key
    best_index = 0
    best_distance = 1 << 62
    for index, (pr, pg, pb) in enumerate(APPLE_PALETTE):
        dr = r - pr
        dg = g - pg
        db = b - pb
        distance = dr * dr * 30 + dg * dg * 59 + db * db * 11
        if distance < best_distance:
            best_index = index
            best_distance = distance
    cache[key] = best_index
    return best_index


def pack_indices_to_page(indices: Sequence[int], *, swap_nibbles: bool = False) -> bytes:
    if len(indices) != LORES_W * LORES_H:
        raise ValueError(f"expected {LORES_W * LORES_H} color indices")

    page = bytearray(PAGE_SIZE)
    for y in range(0, LORES_H, 2):
        text_row = y // 2
        row_base = text_page_offset(text_row, 0)
        upper = y * LORES_W
        lower = (y + 1) * LORES_W
        for x in range(LORES_W):
            top = indices[upper + x] & 0x0F
            bottom = indices[lower + x] & 0x0F
            if swap_nibbles:
                page[row_base + x] = (top << 4) | bottom
            else:
                page[row_base + x] = top | (bottom << 4)
    return bytes(page)


def packet_for_page(page: bytes) -> bytes:
    if len(page) != PAGE_SIZE:
        raise ValueError(f"expected {PAGE_SIZE} page bytes")
    return MAGIC + page + bytes([checksum(page)])


def demo_indices(frame_no: int) -> list[int]:
    pixels: list[int] = []
    sun_x = 5 + (frame_no % 28)
    cloud_x = (frame_no * 2) % 52 - 8
    for y in range(LORES_H):
        for x in range(LORES_W):
            if y < 22:
                color = 7 if y < 16 else 6
                if (x - sun_x) ** 2 + (y - 7) ** 2 < 18:
                    color = 13
                if abs(y - 10) < 2 and cloud_x <= x <= cloud_x + 10:
                    color = 15
            elif y < 28:
                color = 12 if (x + frame_no // 2) % 5 else 14
            else:
                noise = (x * 7 + y * 3 + frame_no) % 11
                color = 8 if noise < 7 else 9
                if y in (34, 35) and 7 < x < 18:
                    color = 5

            if (x == 20 and 20 <= y <= 28) or (y == 24 and 16 <= x <= 24):
                color = 15
            pixels.append(color)
    return pixels


_palette_image = None


def _get_palette_image():
    """A 'P' image whose 256 palette slots tile the 16 Apple colors.

    Tiling means any index Pillow assigns maps back to the intended
    color as index % 16, so quantize() can use the whole table.
    """
    global _palette_image
    if _palette_image is None:
        from PIL import Image

        flat = [channel for rgb in APPLE_PALETTE for channel in rgb] * 16
        _palette_image = Image.new("P", (1, 1))
        _palette_image.putpalette(flat)
    return _palette_image


def image_to_indices(
    image,
    fit: str,
    dither: bool = False,
    saturation: float = 1.35,
    contrast: float = 1.12,
    gamma: float = 1.15,
) -> list[int]:
    from PIL import Image, ImageEnhance, ImageOps

    resampling = getattr(Image, "Resampling", Image).BOX
    image = image.convert("RGB")
    if gamma != 1.0:
        lut = [round(255.0 * (i / 255.0) ** (1.0 / gamma)) for i in range(256)] * 3
        image = image.point(lut)
    if saturation != 1.0:
        image = ImageEnhance.Color(image).enhance(saturation)
    if contrast != 1.0:
        image = ImageEnhance.Contrast(image).enhance(contrast)
    if fit == "stretch":
        image = image.resize((LORES_W, LORES_H), resampling)
    elif fit == "letterbox":
        contained = ImageOps.contain(image, (LORES_W, LORES_H), resampling)
        canvas = Image.new("RGB", (LORES_W, LORES_H), (0, 0, 0))
        canvas.paste(contained, ((LORES_W - contained.width) // 2, (LORES_H - contained.height) // 2))
        image = canvas
    else:
        image = ImageOps.fit(image, (LORES_W, LORES_H), method=resampling, centering=(0.5, 0.5))

    if dither:
        dither_mode = getattr(Image, "Dither", Image).FLOYDSTEINBERG
        quantized = image.quantize(palette=_get_palette_image(), dither=dither_mode)
        return [index % 16 for index in quantized.getdata()]

    cache: dict[tuple[int, int, int], int] = {}
    return [nearest_apple_color(rgb, cache) for rgb in image.getdata()]


def save_preview(indices: Sequence[int], path: Path, scale: int = 8) -> None:
    from PIL import Image

    data = bytes(channel for index in indices for channel in APPLE_PALETTE[index & 0x0F])
    image = Image.frombytes("RGB", (LORES_W, LORES_H), data)
    resampling = getattr(Image, "Resampling", Image).NEAREST
    image = image.resize((LORES_W * scale, LORES_H * scale), resampling)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def find_window_region(title_part: str) -> Region:
    if sys.platform != "win32":
        raise RuntimeError("--window-title currently uses the Windows API")

    user32 = ctypes.windll.user32

    class RECT(ctypes.Structure):
        _fields_ = [
            ("left", ctypes.c_long),
            ("top", ctypes.c_long),
            ("right", ctypes.c_long),
            ("bottom", ctypes.c_long),
        ]

    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

    matches: list[Region] = []
    title_lower = title_part.lower()

    def callback(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, length + 1)
        if title_lower not in buffer.value.lower():
            return True

        rect = RECT()
        point = POINT(0, 0)
        if not user32.GetClientRect(hwnd, ctypes.byref(rect)):
            return True
        if not user32.ClientToScreen(hwnd, ctypes.byref(point)):
            return True

        width = rect.right - rect.left
        height = rect.bottom - rect.top
        if width > 0 and height > 0:
            matches.append(Region(point.x, point.y, width, height))
        return True

    enum_proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)(callback)
    user32.EnumWindows(enum_proc, None)
    if not matches:
        raise RuntimeError(f"no visible window title contains {title_part!r}")
    return matches[0]


def screen_images(args: argparse.Namespace) -> Iterator:
    import mss
    from PIL import Image

    with mss.mss() as sct:
        if args.region:
            region = args.region
        elif args.window_title:
            region = find_window_region(args.window_title)
        else:
            try:
                monitor = sct.monitors[args.monitor]
            except IndexError as exc:
                raise RuntimeError(f"monitor {args.monitor} is not available") from exc
            region = Region(monitor["left"], monitor["top"], monitor["width"], monitor["height"])

        while True:
            if args.window_title:
                # Follow the window if it moves or resizes.
                try:
                    region = find_window_region(args.window_title)
                except RuntimeError:
                    pass  # window briefly gone; reuse the last region
            shot = sct.grab(region.as_mss())
            yield Image.frombytes("RGB", shot.size, shot.rgb)


def source_pages(args: argparse.Namespace) -> Iterator[bytes]:
    frame_no = 0
    if args.demo:
        while True:
            yield pack_indices_to_page(demo_indices(frame_no), swap_nibbles=args.swap_nibbles)
            frame_no += 1
    elif args.image:
        from PIL import Image

        image = Image.open(args.image)
        indices = image_to_indices(image, args.fit, args.dither, args.saturation, args.contrast, args.gamma)
        while True:
            yield pack_indices_to_page(indices, swap_nibbles=args.swap_nibbles)
    else:
        for image in screen_images(args):
            indices = image_to_indices(image, args.fit, args.dither, args.saturation, args.contrast, args.gamma)
            yield pack_indices_to_page(indices, swap_nibbles=args.swap_nibbles)


def limited_pages(pages: Iterable[bytes], frames: int | None, duration: float | None) -> Iterator[bytes]:
    started = time.monotonic()
    for frame_no, page in enumerate(pages):
        if frames is not None and frame_no >= frames:
            return
        if duration is not None and time.monotonic() - started >= duration:
            return
        yield page


def stream(args: argparse.Namespace) -> None:
    if args.port is None and not args.dry_run:
        raise SystemExit("serial port is required unless --dry-run is used")

    pages = limited_pages(source_pages(args), args.frames, args.duration)
    frame_interval = 1.0 / args.fps if args.fps > 0 else 0.0

    if args.dry_run:
        page = next(iter(pages))
        if args.out_frame:
            args.out_frame.parent.mkdir(parents=True, exist_ok=True)
            args.out_frame.write_bytes(packet_for_page(page))
            print(f"wrote packet: {args.out_frame}")
        if args.preview:
            indices = unpack_page_for_preview(page, swap_nibbles=args.swap_nibbles)
            save_preview(indices, args.preview)
            print(f"wrote preview: {args.preview}")
        print(f"page checksum: ${checksum(page):02X}")
        return

    import serial

    assert args.port is not None
    with serial.Serial(
        args.port,
        args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0,
        write_timeout=2,
        rtscts=False,
        dsrdtr=False,
        xonxoff=False,
    ) as ser:
        # The SSC's 6551 disables its receiver unless DCD (wired from the
        # PC's DTR/RTS through the null modem) is asserted.
        ser.dtr = True
        ser.rts = True
        time.sleep(args.open_delay)
        max_fps = (args.baud / 10.0) / (len(MAGIC) + PAGE_SIZE + 1)
        print(f"streaming to {args.port} at {args.baud} baud (packet limit ~{max_fps:.1f} fps); Ctrl+C stops")
        sent = 0
        stats_started = time.monotonic()
        stats_base = 0
        try:
            for page in pages:
                started = time.monotonic()
                ser.write(packet_for_page(page))
                ser.flush()
                sent += 1
                if args.stats_every > 0 and sent % args.stats_every == 0:
                    now = time.monotonic()
                    if now > stats_started:
                        print(f"frame {sent:6d}  {(sent - stats_base) / (now - stats_started):5.1f} fps")
                    stats_started = now
                    stats_base = sent
                elapsed = time.monotonic() - started
                sleep_for = frame_interval - elapsed
                if sleep_for > 0:
                    time.sleep(sleep_for)
        except KeyboardInterrupt:
            pass
        finally:
            print(f"sent {sent} frame(s)")


def unpack_page_for_preview(page: bytes, *, swap_nibbles: bool = False) -> list[int]:
    indices = [0] * (LORES_W * LORES_H)
    for y in range(0, LORES_H, 2):
        row_base = text_page_offset(y // 2, 0)
        for x in range(LORES_W):
            value = page[row_base + x]
            if swap_nibbles:
                top = (value >> 4) & 0x0F
                bottom = value & 0x0F
            else:
                top = value & 0x0F
                bottom = (value >> 4) & 0x0F
            indices[y * LORES_W + x] = top
            indices[(y + 1) * LORES_W + x] = bottom
    return indices


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Stream 40x48 Apple II lo-res frames over serial.")
    parser.add_argument("port", nargs="?", help="serial port, for example COM3")
    parser.add_argument("--baud", type=int, default=115200, help="serial baud rate, default: 115200")
    parser.add_argument("--fps", type=float, default=8.0, help="target frames per second, default: 8")
    parser.add_argument("--frames", type=int, help="stop after this many frames")
    parser.add_argument("--duration", type=float, help="stop after this many seconds")
    parser.add_argument("--open-delay", type=float, default=1.0, help="seconds to wait after opening the port")
    parser.add_argument("--stats-every", type=int, default=30, help="print measured fps every N frames, 0 = off")

    source = parser.add_argument_group("source")
    source.add_argument("--demo", action="store_true", help="send a generated blocky test scene")
    source.add_argument("--image", type=Path, help="send one still image repeatedly")
    source.add_argument("--region", type=parse_region, help="screen capture region: left,top,width,height")
    source.add_argument("--window-title", help="capture the first visible Windows client area matching this text")
    source.add_argument("--monitor", type=int, default=1, help="mss monitor index when no region/window is given")
    source.add_argument("--fit", choices=("crop", "stretch", "letterbox"), default="crop")
    source.add_argument("--dither", action="store_true", help="Floyd-Steinberg dither the 16-color mapping")
    source.add_argument("--saturation", type=float, default=1.35, help="pre-quantization saturation, 1.0 = off")
    source.add_argument("--contrast", type=float, default=1.12, help="pre-quantization contrast, 1.0 = off")
    source.add_argument("--gamma", type=float, default=1.15, help="pre-quantization gamma lift, 1.0 = off")

    output = parser.add_argument_group("output")
    output.add_argument("--dry-run", action="store_true", help="make one packet locally instead of using serial")
    output.add_argument("--out-frame", type=Path, help="write the dry-run packet here")
    output.add_argument("--preview", type=Path, help="write a scaled PNG preview of the dry-run frame")
    output.add_argument("--swap-nibbles", action="store_true", help="swap top/bottom lo-res nibbles")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.demo and args.image:
        raise SystemExit("--demo and --image are mutually exclusive")
    if args.frames is not None and args.frames < 1:
        raise SystemExit("--frames must be positive")
    if args.duration is not None and args.duration <= 0:
        raise SystemExit("--duration must be positive")
    if args.fps < 0:
        raise SystemExit("--fps cannot be negative")

    try:
        stream(args)
    except ImportError as exc:
        missing = exc.name or str(exc)
        print(f"missing dependency: {missing}", file=sys.stderr)
        print("install with: python -m pip install -r requirements.txt", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
