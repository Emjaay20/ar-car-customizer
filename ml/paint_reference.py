#!/usr/bin/env python3
"""Paint reference calibration (Phase P).

Goal: replace hand-tuned finish constants in the live-paint path with constants
measured from REAL car wrap photos the user drops into ``scratch/paint_reference/``.

Expected naming (all lowercase, jpeg/png ok):

    gloss_black_01.jpg   matte_grey_01.jpg   candy_red_01.jpg
    satin_white_01.jpg   metallic_silver_01.jpg   carbon_dark_01.jpg

For every image we measure:

  * luminance depth        p95 - p05 of luma  (how deep the shadows cut)
  * specular coverage      fraction of pixels with luma > 0.92
  * highlight sharpness    p90 of |grad(luma)| on luma (tight streaks = smooth)
  * saturation             mean HSV saturation of all pixels
  * sheen band             fraction of pixels with luma in [0.45, 0.80)
                              (matte/satin glows here; gloss skips to 0.92+)

Those signals are fit (per finish) into the four live-paint numbers the Unity
side already consumes: ``metallic / smoothness / strength / panel``-shape
constants, plus paste-ready C# for ``CarPaintApplicator`` and the
``ARCar/LivePaint`` ``_Finish`` branches side (see ``--emit-cs``).

If the folder is empty the tool runs in literature mode (published automotive
PBR targets: clear-coat dielectric F0 ~ 0.04, matte roughness 0.55-0.75,
metallic flake sparkle etc.) so the harness is testable before the user adds
stills. Results print as a table + a side-by-side comparison frame rendered
with the same numpy paint port used by video_testbed (optional ``--video``).

Run:
    python ml/paint_reference.py                    # analyze folder (or literature mode)
    python ml/paint_reference.py --emit-cs          # + paste-ready C# constants
    python ml/paint_reference.py --video "<mp4>" --t 42 --finish gloss --tint 111111
        # renders "reference-vs-output" comparison for one walkaround frame

cv2 5.x note: no hstack/vstack (removed); use np.concatenate.
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REF_DIR = ROOT / "scratch" / "paint_reference"
OUT_DIR = ROOT / "scratch" / "paint_reference" / "comparisons"

DEFAULT_VIDEO = ROOT / ".." / "Downloads" / "AR Video Code Fixes - Google Gemini(1).mp4"
DEFAULT_ONNX = ROOT / "My project" / "Assets" / "Resources" / "CarSegMaskTuned.onnx"

# Rough display-name -> tint hex for auto-classifying reference filenames.
COLOR_HEX = {
    "black": "111111", "red": "c1121f", "white": "f5f5f5", "silver": "c9ccd1",
    "grey": "8a8f94", "gray": "8a8f94", "blue": "1e3a8a", "green": "14532d",
    "orange": "ea580c", "yellow": "eab308", "brown": "78350f", "gold": "b8860b",
    "dark": "141414", "pearl": "eef1f5",
}

# Literature-mode starting constants (what the app currently ships, annotated):
#   gloss 0.10/0.90/0.95  matte 0.00/0.12/0.96  satin 0.06/0.44/0.95
#   metallic 0.92/0.76/0.95  candy 0.42/0.92/0.96  carbon 0.85/0.88/0.98
LITERATURE = {
    "gloss":    {"metallic": 0.10, "smoothness": 0.90, "strength": 0.95,
                 "spec_cov": (0.01, 0.10), "depth": (0.55, 0.95), "sheen": (0.00, 0.20)},
    "matte":    {"metallic": 0.00, "smoothness": 0.12, "strength": 0.96,
                 "spec_cov": (0.00, 0.01), "depth": (0.25, 0.50), "sheen": (0.25, 0.70)},
    "satin":    {"metallic": 0.06, "smoothness": 0.44, "strength": 0.95,
                 "spec_cov": (0.00, 0.03), "depth": (0.35, 0.65), "sheen": (0.10, 0.45)},
    "metallic": {"metallic": 0.92, "smoothness": 0.76, "strength": 0.95,
                 "spec_cov": (0.02, 0.15), "depth": (0.40, 0.80), "sheen": (0.05, 0.35)},
    "candy":    {"metallic": 0.42, "smoothness": 0.92, "strength": 0.96,
                 "spec_cov": (0.01, 0.08), "depth": (0.55, 0.95), "sheen": (0.02, 0.30)},
    "carbon":   {"metallic": 0.85, "smoothness": 0.88, "strength": 0.98,
                 "spec_cov": (0.00, 0.05), "depth": (0.30, 0.70), "sheen": (0.05, 0.40)},
}
FINISHES = list(LITERATURE)


@dataclass
class RefStats:
    depth: float
    spec_cov: float
    highlight_sharp: float
    sat_mean: float
    sheen_band: float


def analyze_reference(rgb01: np.ndarray) -> RefStats:
    """rgb01: HxWx3 float 0..1. Returns the measured paint-signal battery."""
    lum = rgb01 @ np.array([0.299, 0.587, 0.114], np.float32)
    p05, p50, p95 = (float(np.percentile(lum, q)) for q in (5, 50, 95))
    gx = np.abs(np.diff(lum, axis=1))
    gy = np.abs(np.diff(lum, axis=0))
    grad = np.concatenate([gx.ravel(), gy.ravel()])
    hsv = cv2.cvtColor((np.clip(rgb01, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2HSV)
    return RefStats(
        depth=max(p95 - p05, 1e-3),
        spec_cov=float((lum > 0.92).mean()),
        highlight_sharp=float(np.percentile(grad, 90)),
        sat_mean=float(hsv[..., 1].mean() / 255.0),
        sheen_band=float(((lum >= 0.45) & (lum < 0.80)).mean()),
    )


def fit(finish: str, s: RefStats) -> dict:
    """Map measured signals onto the live-paint constants for one finish."""
    base = dict(LITERATURE[finish])
    lo_s, hi_s = LITERATURE[finish]["spec_cov"]
    lo_d, hi_d = LITERATURE[finish]["depth"]

    # Spec coverage too low -> dial back glint strength; too high -> push it.
    if s.spec_cov < lo_s:
        base["strength"] = round(base["strength"] + 1.5 * (s.spec_cov - lo_s), 3)
    elif s.spec_cov > hi_s:
        base["strength"] = min(1.0, base["strength"] + (s.spec_cov - hi_s))

    # Shadow depth: deep reflective wraps need stronger illumination swing.
    # Normalized 0..1 inside the finish's expected band -> feeds smoothness nudge.
    depth_n = float(np.clip((s.depth - lo_d) / max(hi_d - lo_d, 1e-3), 0.0, 1.0))
    if finish == "matte":
        # Broad sheen (many mid-luma pixels) = micro-texture bump = rougher.
        sheen_n = float(np.clip((s.sheen_band - 0.30) / 0.35, 0.0, 1.0))
        base["smoothness"] = round(0.20 - 0.10 * sheen_n, 3)
    elif finish in ("satin", "satin_silk", "gloss"):
        base["smoothness"] = round(float(np.clip(0.44 + 0.45 * depth_n, 0.30, 0.93)), 3)
    elif finish == "metallic":
        # Tight highlights = well-flattened flakes = smoother top-coat.
        sharp_n = float(np.clip((s.highlight_sharp - 0.12) / 0.30, 0.0, 1.0))
        base["smoothness"] = round(float(np.clip(0.70 + 0.25 * sharp_n, 0.68, 0.92)), 3)
    elif finish == "candy":
        # Candy depth-of-color: saturation inside shadows drives the two-tone band.
        base["smoothness"] = round(float(np.clip(0.85 + 0.10 * depth_n, 0.82, 0.95)), 3)
        base["_candy_sat_shadow"] = round(s.sat_mean, 3)
    elif finish == "carbon":
        base["smoothness"] = round(float(np.clip(0.82 + 0.12 * depth_n, 0.80, 0.94)), 3)

    return base


def scan_references() -> dict:
    """-> {(finish, color): [paths]} from scratch/paint_reference."""
    out: dict[tuple[str, str], list[Path]] = {}
    if not REF_DIR.exists():
        return out
    for p in sorted(REF_DIR.iterdir()):
        if p.suffix.lower() not in (".jpg", ".jpeg", ".png") or not p.is_file():
            continue
        parts = p.stem.lower().split("_")
        if len(parts) < 2 or parts[0] not in FINISHES:
            continue
        finish, color = parts[0], parts[1]
        out.setdefault((finish, color), []).append(p)
    return out


def calibrate() -> tuple[dict, int]:
    """Returns ({finish: fit-params}, n_ref_images). Literature mode when 0 refs."""
    refs = scan_references()
    n_img = sum(len(v) for v in refs.values())
    if not n_img:
        print("[paint_reference] no stills found -> literature mode "
              f"({len(FINISHES)} finishes from published automotive PBR targets)")
        return {k: dict(v) for k, v in LITERATURE.items()}, 0

    print(f"[paint_reference] {n_img} reference images across {len(refs)} finish/color combos")
    results: dict[str, list[dict]] = {f: [] for f in FINISHES}
    for (finish, _color), paths in refs.items():
        for path in paths:
            img = cv2.imread(str(path), cv2.IMREAD_COLOR)
            if img is None:
                continue
            rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
            stats = analyze_reference(rgb)
            fitted = fit(finish, stats)
            fitted["_source"] = path.name
            results[finish].append(fitted)
            print(f"  {path.name:32s} depth={stats.depth:.2f} spec={stats.spec_cov:.3f} "
                  f"sheen={stats.sheen_band:.3f} sat={stats.sat_mean:.2f} -> "
                  f"metallic={fitted['metallic']:.2f} smoothness={fitted['smoothness']:.2f} "
                  f"strength={fitted['strength']:.2f}")

    merged: dict[str, dict] = {}
    for finish, rows in results.items():
        if not rows:
            merged[finish] = dict(LITERATURE[finish])
            continue
        keys = ("metallic", "smoothness", "strength")
        merged[finish] = {
            k: round(float(np.median([r[k] for r in rows])), 3) for k in keys
        }
        merged[finish]["_from"] = [r["_source"] for r in rows]
    return merged, n_img


def emit_cs(params: dict) -> str:
    """Paste-ready constants for Unity (CarPaintApplicator/FinishValues) + shader note."""
    lines = [
        "// ---- Calibrated finish constants (paste into C# Finish table / shader _Finish branches) ----",
        "// Finish modes: 0 gloss, 1 matte, 2 satin, 3 metallic, 4 candy, 5 carbon",
    ]
    order = ["gloss", "matte", "satin", "metallic", "candy", "carbon"]
    for i, finish in enumerate(order):
        v = params[finish]
        src = v.get("_from") or ["literature"]
        lines.append(
            f"// [{i}] {finish:8s} metallic={v['metallic']:.2f} smoothness={v['smoothness']:.2f} "
            f"strength={v['strength']:.2f}   // refs: {', '.join(src[:3])}"
        )
        lines.append(
            f"//       FinishValues: ({v['metallic']:.2f}, {v['smoothness']:.2f}, {v['strength']:.2f})"
        )
    return "\n".join(lines)


def prepare_frame(video: str, t_sec: float, viewport: str) -> np.ndarray:
    """Grab one viewport-cropped frame (same crop as video_testbed defaults)."""
    x0, y0, x1, y1 = (int(v) for v in viewport.split(","))
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise SystemExit(f"cannot open video {video}")
    cap.set(cv2.CAP_PROP_POS_MSEC, t_sec * 1000.0)
    ok, bgr = cap.read()
    cap.release()
    if not ok:
        raise SystemExit(f"cannot seek to t={t_sec}s")
    vp = bgr[y0:y1, x0:x1]
    return cv2.cvtColor(vp, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def comparison(video: str, t_sec: float, tint_hex: str, finish: str,
               viewport: str, params: dict) -> None:
    """reference-vs-output: extract frame, run CarSegMaskTuned, paint, stack."""
    from video_testbed import OnnxMaskRunner, paint_preview  # offline reuse, same dir

    frame = prepare_frame(video, t_sec, viewport)
    runner = OnnxMaskRunner(Path(DEFAULT_ONNX))
    rgb384 = cv2.resize(frame, (384, 384), interpolation=cv2.INTER_AREA)
    out = runner.run(rgb384.transpose(2, 0, 1)[None].astype(np.float32))
    mask = np.clip(out[0, 0], 0.0, 1.0)

    v = params.get(finish, LITERATURE[finish])
    print(f"  painting finish={finish} with metallic={v['metallic']} "
          f"smoothness={v['smoothness']} strength={v['strength']}")
    painted = paint_preview(frame, mask, tint_hex, finish)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    h, w = frame.shape[:2]
    ref8 = (frame * 255).astype(np.uint8)
    out8 = (painted * 255).astype(np.uint8)
    bar = np.full((24, w, 3), 30, np.uint8)
    stack = np.concatenate([ref8, bar, np.full((2, w, 3), 200, np.uint8),
                            bar, out8], axis=0)
    path = OUT_DIR / f"cmp_{finish}_{tint_hex}_{time.strftime('%H%M%S')}.jpg"
    cv2.imwrite(str(path), cv2.cvtColor(stack, cv2.COLOR_RGB2BGR),
                [cv2.IMWRITE_JPEG_QUALITY, 92])
    print(f"  saved comparison: {path}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--emit-cs", action="store_true", help="print paste-ready C# constants")
    p.add_argument("--json", default=None, help="write calibrated params to a JSON file")
    p.add_argument("--video", default=str(DEFAULT_VIDEO),
                   help="walkaround recording for the comparison frame")
    p.add_argument("--t", type=float, default=42.0, help="video time (s) for comparison")
    p.add_argument("--tint", default="111111")
    p.add_argument("--finish", choices=FINISHES, default="gloss")
    p.add_argument("--viewport", default="0,208,1080,1105")
    args = p.parse_args()

    params, n_img = calibrate()

    print("\n=== calibrated finishes ===")
    for finish in FINISHES:
        v = params[finish]
        src = f"  (from: {', '.join(v.get('_from', [])[:2])})" if "_from" in v else ""
        print(f"  {finish:8s} metallic={v['metallic']:.2f} smoothness={v['smoothness']:.2f} "
              f"strength={v['strength']:.2f}{src}")

    if args.emit_cs:
        print()
        print(emit_cs(params))

    if args.json:
        Path(args.json).write_text(json.dumps(params, indent=2, default=str))
        print(f"\nwrote {args.json}")

    if n_img:
        comparison(args.video, args.t, args.tint, args.finish, args.viewport, params)


if __name__ == "__main__":
    main()
