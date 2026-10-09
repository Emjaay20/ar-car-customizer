"""Paint isolation for the AR car prototype.

YOLO-seg returns the whole car. This module then drops dark window pixels in the
upper band and dark wheel pixels in the lower band. Those thresholds are a
prototype, not a second trained model.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

WINDOW_LUMA = 48
WHEEL_LUMA = 36
WINDOW_BAND = 0.50
WHEEL_BAND = 0.35

Rgb = tuple[int, int, int]
Image = list[list[Rgb]]
Mask = list[list[int]]


def luma(pixel: Rgb) -> float:
    return (pixel[0] + pixel[1] + pixel[2]) / 3.0


def synthetic_scene() -> tuple[Image, Mask]:
    width, height = 80, 60
    background = (170, 172, 176)
    image = [[background for _ in range(width)] for _ in range(height)]
    mask = [[0 for _ in range(width)] for _ in range(height)]

    def paint(x: int, y: int, color: Rgb) -> None:
        image[y][x] = color
        mask[y][x] = 1

    for y in range(16, 51):
        for x in range(12, 68):
            paint(x, y, (220, 40, 40))
    for y in range(20, 31):
        for x in range(28, 51):
            paint(x, y, (18, 20, 28))

    def disc(cx: int, cy: int, radius: int, color: Rgb) -> None:
        for y in range(cy - radius, cy + radius + 1):
            for x in range(cx - radius, cx + radius + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius:
                    paint(x, y, color)

    disc(22, 46, 4, (6, 6, 6))
    disc(58, 46, 4, (6, 6, 6))
    return image, mask


def refine_paint_mask(image: Image, car_mask: Mask) -> tuple[Mask, list[dict]]:
    height = len(image)
    width = len(image[0]) if height else 0
    paint = [[0 for _ in range(width)] for _ in range(height)]
    if width == 0 or height == 0:
        return paint, []

    bounds = mask_bounds(car_mask)
    if bounds is None:
        return paint, []
    min_x, min_y, max_x, max_y = bounds
    bbox_h = max_y - min_y + 1
    window_limit = min_y + bbox_h * WINDOW_BAND
    wheel_limit = max_y - bbox_h * WHEEL_BAND

    wheel_pixels: list[tuple[int, int]] = []
    for y in range(height):
        for x in range(width):
            if not car_mask[y][x]:
                continue
            value = luma(image[y][x])
            in_window = y <= window_limit and value < WINDOW_LUMA
            in_wheel = y >= wheel_limit and value < WHEEL_LUMA
            if in_window or in_wheel:
                if in_wheel:
                    wheel_pixels.append((x, y))
                continue
            paint[y][x] = 1

    points = cluster_wheels(wheel_pixels, width, height)
    trunk = trunk_candidate(paint, width, height)
    if trunk is not None:
        points.append(trunk)
    return paint, points


def prove_synthetic() -> dict:
    image, car_mask = synthetic_scene()
    paint, points = refine_paint_mask(image, car_mask)

    if car_mask[25][40] != 1 or paint[25][40] != 0:
        raise AssertionError("window pixel was not excluded from the paint mask")
    if car_mask[46][22] != 1 or paint[46][22] != 0:
        raise AssertionError("wheel pixel was not excluded from the paint mask")
    if paint[36][18] != 1:
        raise AssertionError("body pixel was dropped from the paint mask")
    if car_mask[2][2] or paint[2][2]:
        raise AssertionError("background leaked into a mask")

    wheels = [point for point in points if point["name"] == "wheel"]
    if len(wheels) != 2:
        raise AssertionError(f"expected 2 wheel keypoints, got {wheels}")
    xs = sorted(point["x"] for point in wheels)
    if not (xs[0] < 0.4 and xs[1] > 0.6):
        raise AssertionError(f"wheel keypoints are not separated: {wheels}")

    trunks = [point for point in points if point["name"] == "trunk_candidate"]
    if len(trunks) != 1 or trunks[0]["x"] <= 0.7:
        raise AssertionError(f"trunk candidate is not on the rear/right edge: {trunks}")

    return {
        "width": len(image[0]),
        "height": len(image),
        "paintPixels": sum(sum(row) for row in paint),
        "points": points,
        "image": image,
        "paint": paint,
    }


def cluster_wheels(pixels: list[tuple[int, int]], width: int, height: int) -> list[dict]:
    if not pixels:
        return []
    ordered = sorted(pixels)
    clusters = [[ordered[0]]]
    for x, y in ordered[1:]:
        if x - clusters[-1][-1][0] > 8:
            clusters.append([])
        clusters[-1].append((x, y))

    points = []
    for cluster in clusters:
        if len(cluster) < 4:
            continue
        cx = sum(point[0] for point in cluster) / len(cluster)
        cy = sum(point[1] for point in cluster) / len(cluster)
        points.append({
            "name": "wheel",
            "x": round(cx / width, 4),
            "y": round(cy / height, 4),
        })
    return points


def trunk_candidate(paint: Mask, width: int, height: int) -> dict | None:
    bounds = mask_bounds(paint)
    if bounds is None:
        return None
    min_x, _min_y, max_x, _max_y = bounds
    slice_x = max_x - (max_x - min_x + 1) * 0.2
    best: tuple[int, int] | None = None
    for y in range(height):
        for x in range(width):
            if not paint[y][x] or x < slice_x:
                continue
            if best is None or y < best[1] or (y == best[1] and x > best[0]):
                best = (x, y)
    if best is None:
        return None
    return {
        "name": "trunk_candidate",
        "x": round(best[0] / width, 4),
        "y": round(best[1] / height, 4),
    }


def mask_bounds(mask: Mask) -> tuple[int, int, int, int] | None:
    height = len(mask)
    width = len(mask[0]) if height else 0
    min_x, min_y, max_x, max_y = width, height, -1, -1
    for y in range(height):
        for x in range(width):
            if not mask[y][x]:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < 0:
        return None
    return min_x, min_y, max_x, max_y


def write_png(path: Path, width: int, height: int, rows: list[bytes], color_type: int) -> None:
    if color_type not in (0, 2):
        raise ValueError("color_type must be 0 (gray) or 2 (rgb)")
    raw = b"".join(b"\x00" + row for row in rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(raw)) + _chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def read_png(path: Path) -> tuple[int, int, int, list[bytes]]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{path} is not a PNG")
    pos = 8
    width = height = color_type = None
    idat = b""
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        tag = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, bit_depth, color_type, *_rest = struct.unpack(">IIBBBBB", chunk)
            if bit_depth != 8:
                raise ValueError("only 8-bit PNG is supported")
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
    if width is None or height is None or color_type is None:
        raise ValueError("PNG is missing IHDR")
    channels = {0: 1, 2: 3, 6: 4}[color_type]
    raw = zlib.decompress(idat)
    rows = []
    stride = width * channels
    offset = 0
    for _ in range(height):
        if raw[offset] != 0:
            raise ValueError("only filter-none PNG rows are supported")
        offset += 1
        rows.append(raw[offset : offset + stride])
        offset += stride
    return width, height, color_type, rows


def gray_rows(mask: Mask) -> list[bytes]:
    return [bytes(255 if value else 0 for value in row) for row in mask]


def rgb_rows(image: Image) -> list[bytes]:
    return [bytes(channel for pixel in row for channel in pixel) for row in image]


def overlay_rows(image: Image, paint: Mask) -> list[bytes]:
    rows = []
    for y, row in enumerate(image):
        raw = bytearray()
        for x, pixel in enumerate(row):
            if paint[y][x]:
                raw.extend((
                    min(255, pixel[0] // 2 + 110),
                    pixel[1] // 2,
                    pixel[2] // 2,
                ))
            else:
                raw.extend(pixel)
        rows.append(bytes(raw))
    return rows


def _chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
