"""Prove car-paint isolation, then hand the mask to Unity.

Synthetic mode needs only the Python standard library:

    python ml/segment_car.py --self-test
    python ml/segment_car.py --synthetic --publish

Real video needs the optional packages in ml/requirements.txt. YOLOv8-seg
isolates the car instance. Window and wheel pixels are then removed by the
heuristic in car_segment.py. Keypoints are geometric estimates, not a pose net.

    python ml/segment_car.py --video path/to/car.mp4 --publish

--publish copies the first frame to backend/public/masks so the Flutter client
can ask Unity to tint that mask. A synthetic publish is a test rectangle, not
a real car.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from car_segment import gray_rows, overlay_rows, prove_synthetic, read_png, refine_paint_mask, rgb_rows, write_png

ROOT = Path(__file__).resolve().parents[1]
PUBLISH_DIR = ROOT / "backend" / "public" / "masks"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Isolate car paint pixels and estimate part keypoints.")
    parser.add_argument("--self-test", action="store_true", help="Run the synthetic isolation checks and exit")
    parser.add_argument("--synthetic", action="store_true", help="Write a synthetic car frame and its paint mask")
    parser.add_argument("--image", help="Run YOLO segmentation on one image")
    parser.add_argument("--video", help="Run YOLO segmentation on a video")
    parser.add_argument("--out", default=str(ROOT / "ml" / "out"))
    parser.add_argument("--every", type=int, default=15, help="Use every Nth video frame")
    parser.add_argument("--max-frames", type=int, default=30)
    parser.add_argument("--model", default=os.environ.get("YOLO_SEG_MODEL", "yolov8n-seg.pt"))
    parser.add_argument("--publish", action="store_true", help="Copy the first mask into backend/public/masks")
    args = parser.parse_args(argv)

    if args.self_test and not (args.synthetic or args.image or args.video):
        summary = prove_synthetic()
        print(f"synthetic isolation ok: {summary['paintPixels']} paint pixels, {len(summary['points'])} keypoints")
        return 0

    if not (args.synthetic or args.image or args.video):
        parser.print_help()
        return 2

    out_dir = Path(args.out)
    frames = []
    if args.synthetic:
        frames.append(synthetic_frame())
    if args.image or args.video:
        frames.extend(yolo_frames(args))

    if not frames:
        print("No car instance was found.", file=sys.stderr)
        return 1

    write_frames(out_dir, frames)
    if args.publish:
        publish(frames[0])
    print(f"Wrote {len(frames)} frame(s) to {out_dir}")
    print(frames[0]["note"])
    return 0


def synthetic_frame() -> dict:
    summary = prove_synthetic()
    return {
        "image": summary["image"],
        "paint": summary["paint"],
        "points": summary["points"],
        "width": summary["width"],
        "height": summary["height"],
        "note": "synthetic: test rectangle, not a real car. Keypoints are geometric estimates.",
        "source": "synthetic",
    }


def yolo_frames(args: argparse.Namespace) -> list[dict]:
    try:
        import cv2
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit(
            "Real segmentation needs opencv-python and ultralytics. "
            "Install ml/requirements.txt or run --synthetic."
        ) from error

    model = YOLO(args.model)
    paths = [args.image] if args.image else video_samples(args.video, args.every, args.max_frames, cv2)
    frames = []
    for index, item in enumerate(paths):
        frame = item if args.image is None else cv2.imread(item)
        if frame is None:
            print(f"Could not read {item}", file=sys.stderr)
            continue
        converted = segment_bgr(frame, model, cv2)
        if converted is None:
            continue
        image, car_mask = converted
        paint, points = refine_paint_mask(image, car_mask)
        frames.append({
            "image": image,
            "paint": paint,
            "points": points,
            "width": len(image[0]),
            "height": len(image),
            "note": "YOLO instance mask with heuristic window/wheel removal. Keypoints are geometric estimates, not a pose network.",
            "source": str(item if args.image else index),
        })
    return frames


def video_samples(path: str, every: int, max_frames: int, cv2) -> list:
    capture = cv2.VideoCapture(path)
    if not capture.isOpened():
        raise SystemExit(f"Could not open video {path}")
    frames = []
    index = 0
    while len(frames) < max_frames:
        ok, frame = capture.read()
        if not ok:
            break
        if index % max(every, 1) == 0:
            frames.append(frame)
        index += 1
    capture.release()
    return frames


def segment_bgr(frame_bgr, model, cv2):
    height, width = frame_bgr.shape[:2]
    max_width = 640
    if width > max_width:
        scale = max_width / width
        frame_bgr = cv2.resize(frame_bgr, (max_width, int(height * scale)))
        height, width = frame_bgr.shape[:2]

    result = model.predict(frame_bgr, classes=[2, 5, 7], conf=0.10, verbose=False)[0]
    if result.masks is None or len(result.masks.data) == 0:
        return None

    areas = result.masks.data.sum(dim=(1, 2))
    chosen = int(areas.argmax())
    mask = result.masks.data[chosen].cpu().numpy()
    resized = cv2.resize(mask, (width, height), interpolation=cv2.INTER_LINEAR)
    binary = resized > 0.5

    image = []
    car_mask = []
    for y in range(height):
        colors = []
        row_mask = []
        for x in range(width):
            blue, green, red = frame_bgr[y, x]
            colors.append((int(red), int(green), int(blue)))
            row_mask.append(1 if binary[y, x] else 0)
        image.append(colors)
        car_mask.append(row_mask)
    return image, car_mask


def write_frames(out_dir: Path, frames: list[dict]) -> None:
    mask_dir = out_dir / "masks"
    mask_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for index, frame in enumerate(frames):
        stem = f"{index:05d}"
        mask_path = mask_dir / f"{stem}.png"
        overlay_path = out_dir / f"overlay-{stem}.png"
        write_png(mask_path, frame["width"], frame["height"], gray_rows(frame["paint"]), 0)
        write_png(overlay_path, frame["width"], frame["height"], overlay_rows(frame["image"], frame["paint"]), 2)
        record = bridge_record(frame, str(mask_path.resolve()))
        records.append(record)
        (out_dir / f"bridge-{stem}.json").write_text(json.dumps(record), encoding="utf-8")

    with (out_dir / "bridge.jsonl").open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    (out_dir / "summary.json").write_text(
        json.dumps({"frames": len(records), "first": records[0]}, indent=2),
        encoding="utf-8",
    )


def bridge_record(frame: dict, mask_path: str) -> dict:
    return {
        "maskPng": mask_path,
        "points": frame["points"],
        "width": frame["width"],
        "height": frame["height"],
        "paintPixels": sum(sum(row) for row in frame["paint"]),
        "note": frame["note"],
        "source": frame["source"],
    }


def publish(frame: dict) -> None:
    PUBLISH_DIR.mkdir(parents=True, exist_ok=True)
    mask_path = PUBLISH_DIR / "paint-mask.png"
    write_png(mask_path, frame["width"], frame["height"], gray_rows(frame["paint"]), 0)
    overlay_path = PUBLISH_DIR / "overlay.png"
    write_png(overlay_path, frame["width"], frame["height"], overlay_rows(frame["image"], frame["paint"]), 2)
    record = bridge_record(frame, "/masks/paint-mask.png")
    (PUBLISH_DIR / "bridge-frame.json").write_text(json.dumps(record), encoding="utf-8")
    width, height, color_type, rows = read_png(mask_path)
    if color_type != 0 or width != frame["width"] or height != frame["height"] or not rows:
        raise SystemExit("Published mask PNG could not be read back")
    print(f"Published {mask_path} and {PUBLISH_DIR / 'bridge-frame.json'}")
    print("Phone URL path: /masks/paint-mask.png")


if __name__ == "__main__":
    raise SystemExit(main())
