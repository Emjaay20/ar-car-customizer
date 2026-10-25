"""Acceptance fixture for the Abuja Corolla walkaround.

Crops the camera viewport out of the screen recording, hides the Flutter
chrome the phone model never sees, and runs the same live mask path as
ml/live_segment_worker.py. Writes a contact sheet per angle:

    original | raw car mask | paint mask | gloss black | candy red

This is a test, not a training set. One clip must not be used to fit a model.
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np

ML_DIR = Path(__file__).resolve().parent
if str(ML_DIR) not in sys.path:
    sys.path.insert(0, str(ML_DIR))

from live_segment_worker import (  # noqa: E402
    build_paint_mask,
    select_primary_vehicle_mask,
    studio_polish_car_paint,
    blur_license_plate_privacy,
)

# 1080x2340 screen recording. Camera viewport sits under the app bar and
# above the paint tray. Measured from the second walkaround clip.
VIEW_Y0 = 252
VIEW_Y1 = 1260

# UI rectangles in viewport coordinates. The phone's Unity capture does not
# contain these; they are Flutter widgets drawn on top of the recording.
PILL = (16, 0, 1064, 140)
BUTTONS = (12, 880, 1068, 1008)

# Angles that actually show the car, plus one empty wall as a negative.
FRAMES = [
    ("rear", 4.0),
    ("rear-quarter", 22.0),
    ("front", 42.0),
    ("hood", 52.0),
    ("wall", 62.0),
    ("rear-glass", 74.0),
    ("side-glass", 86.0),
    ("front-quarter", 98.0),
    ("rear-wide", 112.0),
]


def crop_camera(frame: np.ndarray) -> np.ndarray:
    return frame[VIEW_Y0:VIEW_Y1, :].copy()


def hide_flutter_chrome(crop: np.ndarray) -> np.ndarray:
    """Inpaint the status pill and the button row so the model sees a camera frame."""
    mask = np.zeros(crop.shape[:2], dtype=np.uint8)
    for x0, y0, x1, y1 in (PILL, BUTTONS):
        cv2.rectangle(mask, (x0, y0), (x1, y1), 255, thickness=-1)
    # Feather the rectangle edges so inpaint does not leave a hard box.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    mask = cv2.dilate(mask, kernel, iterations=1)
    return cv2.inpaint(crop, mask, 5, cv2.INPAINT_TELEA)


def overlay(image: np.ndarray, mask_u8: np.ndarray, color: tuple[int, int, int]) -> np.ndarray:
    out = image.copy()
    if mask_u8 is None or mask_u8.size == 0:
        return out
    m = mask_u8
    if m.ndim == 3:
        m = m[:, :, 0]
    if m.shape[:2] != out.shape[:2]:
        m = cv2.resize(m, (out.shape[1], out.shape[0]), interpolation=cv2.INTER_NEAREST)
    binary = m > 40
    tint = np.zeros_like(out)
    tint[:] = color
    blended = cv2.addWeighted(out, 0.45, tint, 0.55, 0)
    out[binary] = blended[binary]
    contours, _ = cv2.findContours((binary.astype(np.uint8) * 255), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(out, contours, -1, color, 2)
    return out


def label(image: np.ndarray, text: str) -> np.ndarray:
    out = image.copy()
    cv2.rectangle(out, (0, 0), (out.shape[1], 36), (12, 16, 20), thickness=-1)
    cv2.putText(out, text, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (240, 245, 248), 2, cv2.LINE_AA)
    return out


def fit(image: np.ndarray, width: int = 360) -> np.ndarray:
    h, w = image.shape[:2]
    height = max(1, int(round(h * (width / float(w)))))
    return cv2.resize(image, (width, height), interpolation=cv2.INTER_AREA)


def run_frame(model, crop: np.ndarray) -> dict:
    work = cv2.resize(crop, (540, 504), interpolation=cv2.INTER_AREA)
    result = model.predict(
        work,
        classes=[2, 5, 7],
        conf=0.08,
        retina_masks=True,
        verbose=False,
    )[0]
    raw = select_primary_vehicle_mask(result, work.shape[0], work.shape[1])
    boxes = 0 if result.boxes is None else len(result.boxes)
    top_conf = 0.0
    if result.boxes is not None and len(result.boxes) > 0:
        top_conf = float(result.boxes.conf.max().cpu().numpy())
    if raw is None:
        paint = np.zeros(work.shape[:2], dtype=np.uint8)
        plate = np.zeros(work.shape[:2], dtype=bool)
        gloss = work
        candy = work
        source = "no-vehicle"
    else:
        paint, plate = build_paint_mask(work, raw, return_plate=True, panel="body", full_coverage=False)
        gloss = studio_polish_car_paint(work, paint, hex_color="#111111", finish="gloss", panel="body", license_plate=plate, solid_silhouette=raw)
        candy = studio_polish_car_paint(work, paint, hex_color="#D0122D", finish="candy", panel="body", license_plate=plate, solid_silhouette=raw)
        source = "yolov8s-seg"
    return {
        "work": work,
        "raw": raw if raw is not None else np.zeros(work.shape[:2], dtype=np.uint8),
        "paint": paint,
        "plate": plate,
        "gloss": gloss,
        "candy": candy,
        "boxes": boxes,
        "top_conf": top_conf,
        "source": source,
        "paint_frac": float(np.count_nonzero(paint > 64)) / float(paint.size),
    }


def privacy(image: np.ndarray, plate: np.ndarray | None) -> np.ndarray:
    if plate is None or image is None:
        return image
    if plate.shape[:2] != image.shape[:2]:
        plate = cv2.resize(plate.astype(np.uint8), (image.shape[1], image.shape[0]), interpolation=cv2.INTER_NEAREST) > 0
    return blur_license_plate_privacy(image, plate)


def main() -> int:
    video = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(r"C:\Users\USER\Downloads\AR Video Code Fixes - Google Gemini(1).mp4")
    out_dir = ML_DIR / "out" / "corolla-abuja"
    out_dir.mkdir(parents=True, exist_ok=True)
    if not video.exists():
        print(f"missing video: {video}")
        return 1

    from ultralytics import YOLO

    model_path = ML_DIR / "yolov8s-seg.pt"
    print(f"loading {model_path.name}")
    model = YOLO(str(model_path))

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        print(f"could not open {video}")
        return 1

    sheets = []
    for name, seconds in FRAMES:
        cap.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000.0)
        ok, frame = cap.read()
        if not ok or frame is None:
            print(f"MISS {name} @ {seconds:.0f}s")
            continue
        crop = hide_flutter_chrome(crop_camera(frame))
        print(f"segment {name} @ {seconds:.0f}s ...", flush=True)
        got = run_frame(model, crop)
        plate = got["plate"]
        raw_u8 = got["raw"]
        if raw_u8.dtype != np.uint8:
            raw_u8 = (raw_u8 > 0.4).astype(np.uint8) * 255
        elif raw_u8.max() <= 1:
            raw_u8 = raw_u8 * 255

        panels = [
            label(privacy(got["work"], plate), f"{name}  {got['source']}  conf {got['top_conf']:.2f}"),
            label(privacy(overlay(got["work"], raw_u8, (40, 220, 80)), plate), "raw car mask"),
            label(privacy(overlay(got["work"], got["paint"], (40, 180, 255)), plate), f"paint mask  {got['paint_frac'] * 100:.1f}%"),
            label(privacy(got["gloss"], plate), "gloss black"),
            label(privacy(got["candy"], plate), "candy red"),
        ]
        row = np.hstack([fit(p) for p in panels])
        cv2.imwrite(str(out_dir / f"{name}.jpg"), row, [int(cv2.IMWRITE_JPEG_QUALITY), 90])
        sheets.append(row)
        print(
            f"  {name}: boxes={got['boxes']} conf={got['top_conf']:.2f} "
            f"paint={got['paint_frac'] * 100:.1f}% source={got['source']}"
        )

    cap.release()
    if sheets:
        width = min(s.shape[1] for s in sheets)
        stacked = np.vstack([cv2.resize(s, (width, int(s.shape[0] * width / s.shape[1]))) for s in sheets])
        cv2.imwrite(str(out_dir / "contact.jpg"), stacked, [int(cv2.IMWRITE_JPEG_QUALITY), 86])
        print(f"wrote {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
