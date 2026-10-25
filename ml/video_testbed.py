"""
Video Testbed: offline mask tuner mirroring the on-device Sentis pipeline.

Purpose
-------
Feed a recorded walkaround video (e.g. the white Corolla screen recording) through the
*exact* on-device segmentation path (same crop -> same 384x384 resize -> CarSegMask.onnx),
render debug views, and measure mask quality per frame. Tuned thresholds are then
ported back into ml/export_sentis_mask.py and re-exported for Unity.

Pipeline fidelity notes (mirrors My project/Assets/Scripts/SentisCarSegmenter.cs):
  * The phone 1:1 blits its camera viewport into the 384x384 model input (stretch mode).
  * Output [1,1,384,384] probability is used directly as the paint mask (shader gates at 0.16,
    alpha ramp 0.06-0.16).

Usage
-----
  python ml/video_testbed.py                                   # baseline run (baked ONNX thresholds)
  python ml/video_testbed.py --twin --presence 0.22 --paint-score 0.08 ...   # tuning run
  python ml/video_testbed.py --export-onnx --out-name CarSegMaskTuned       # re-export tuned model

Outputs (under scratch/corolla_testbed/<run>/):
  frames/rNNN.jpg   side-by-side: input | mask debug | paint preview
  triplet.mp4       assembled video
  metrics.json      per-frame + summary stats
  config.json       run configuration for reproducibility
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_VIDEO = r"C:\Users\USER\Downloads\AR Video Code Fixes - Google Gemini(1).mp4"
DEFAULT_ONNX = ROOT / "My project" / "Assets" / "Resources" / "CarSegMask.onnx"
OUT_ROOT = ROOT / "scratch" / "corolla_testbed"

# Unity camera viewport inside the app screen recording (x0, y0, x1, y1 of a 1080x2340 frame).
DEFAULT_VIEWPORT = (0, 208, 1080, 1105)


# ---------------------------------------------------------------------------
# Threshold configuration (mirrors ml/export_sentis_mask.py VehiclePaintMaskWrapper)
# ---------------------------------------------------------------------------
@dataclass
class MaskThresholds:
    presence: float = 0.32      # car_presence gate: (top_score - v) * 5
    sil_score: float = 0.20     # vehicle silhouette anchor gate (YOLOv8n-seg)
    sil_logit: float = 0.10
    paint_score: float = 0.12   # 17 paintable panel anchor gate
    paint_logit: float = 0.08
    cut_score: float = 0.15     # 16 non-paint cutout gate
    cut_logit: float = 0.15
    sharp_lo: float = 0.24      # final sharp-metal curve: clamp((x - lo)/span)
    sharp_span: float = 0.35
    sil_weight: float = 0.0     # silhouette assist weight (1.0 = original full union)
    parts_presence: float = 0.35  # presence gate on best paintable-parts score
    parts_gain: float = 8.0     # gate slope for parts presence
    boost: float = 1.0          # post-threshold gain (applied in twin/export path)

    def overrides_from(args, base: "MaskThresholds | None" = None) -> "MaskThresholds":
        cfg = MaskThresholds() if base is None else base
        for name in vars(cfg):
            cli_val = getattr(args, name, None)
            if cli_val is not None:
                setattr(cfg, name, cli_val)
        return cfg


# ---------------------------------------------------------------------------
# On-device proxy: run the exported ONNX exactly as the phone would
# ---------------------------------------------------------------------------
class OnnxMaskRunner:
    def __init__(self, onnx_path: Path):
        import onnxruntime as ort
        self.sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])

    def run(self, inp: np.ndarray) -> np.ndarray:
        return self.sess.run(None, {"input": inp})[0]


# ---------------------------------------------------------------------------
# Tunable twin: same graph in torch with adjustable gates (for threshold search)
# Built from VehiclePaintMaskWrapper so _eval_anchor stays a single source of truth.
# ---------------------------------------------------------------------------
class TunableMaskRunner:
    def __init__(self, thr: MaskThresholds, car_pt: Path, parts_pt: Path):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from export_sentis_mask import VehiclePaintMaskWrapper  # noqa: E402

        import torch  # noqa: E402
        self.torch = torch
        self.thr = thr
        self.net = VehiclePaintMaskWrapper(str(car_pt), str(parts_pt))
        self.net.eval()

    def run(self, inp: np.ndarray) -> np.ndarray:
        torch = self.torch
        with torch.no_grad():
            x = torch.from_numpy(inp)
            # Mirror VehiclePaintMaskWrapper.forward with tuned gates
            car_preds = self.net.car_yolo(x)
            car_main = car_preds[0][0][0]
            car_proto_flat = car_preds[0][1].view(1, 32, 96 * 96)

            car_cls = car_main[4:84, :]
            import torch.nn.functional as F
            veh_weights = getattr(self.net, "veh_weights")
            veh_scores = (car_cls * veh_weights).max(dim=0)[0]
            top_scores, top_idx = torch.topk(veh_scores, k=3, dim=0)

            T = self.thr
            presence = torch.clamp((top_scores[0] - T.presence) * 5.0, 0.0, 1.0)

            silhouette = torch.zeros(1, 1, 96, 96)
            for i in range(3):
                m = self.net._eval_anchor(car_main, car_proto_flat, top_idx[i:i + 1],
                                          top_scores[i:i + 1], coeff_start=84,
                                          score_thresh=T.sil_score, logit_thresh=T.sil_logit)
                silhouette = torch.maximum(silhouette, m)

            parts_preds = self.net.parts_yolo(x)
            parts_main = parts_preds[0][0][0]
            parts_proto_flat = parts_preds[0][1].view(1, 32, 96 * 96)
            parts_cls = parts_main[4:37, :]
            best_scores, best_idx = torch.topk(parts_cls, k=1, dim=1)

            # Presence from the parts network: close-up sheet metal makes the COCO
            # whole-vehicle score collapse (<0.1) exactly when painting matters most.
            paint_best_scores = best_scores[self.net.paint_indices, :].max()
            presence_parts = torch.clamp((paint_best_scores - T.parts_presence) * T.parts_gain,
                                         0.0, 1.0)
            presence = torch.maximum(presence, presence_parts)

            paint = torch.zeros(1, 1, 96, 96)
            for c in self.net.paint_indices:
                m = self.net._eval_anchor(parts_main, parts_proto_flat, best_idx[c], best_scores[c],
                                          coeff_start=37, score_thresh=T.paint_score,
                                          logit_thresh=T.paint_logit)
                paint = torch.maximum(paint, m)

            cutout = torch.zeros(1, 1, 96, 96)
            for c in self.net.np_indices:
                m = self.net._eval_anchor(parts_main, parts_proto_flat, best_idx[c], best_scores[c],
                                          coeff_start=37, score_thresh=T.cut_score,
                                          logit_thresh=T.cut_logit)
                cutout = torch.maximum(cutout, m)

            body = torch.maximum(paint, silhouette * self.thr.sil_weight)
            clean = torch.clamp(body - cutout, 0.0, 1.0)
            clean384 = F.interpolate(clean, size=(384, 384), mode="bilinear", align_corners=False)
            sharp = torch.clamp((clean384 - T.sharp_lo) / T.sharp_span, 0.0, 1.0)
            if T.boost != 1.0:
                sharp = torch.clamp(sharp * T.boost, 0.0, 1.0)
            final = torch.clamp(sharp * presence, 0.0, 1.0)

            out = final.numpy().astype(np.float32)
        return out


# ---------------------------------------------------------------------------
# Paint preview (numpy port of ARCar/LivePaint ShadePaint, gloss branch simplified)
# ---------------------------------------------------------------------------
def paint_preview(rgb01: np.ndarray, mask01: np.ndarray, tint_hex: str, finish: str) -> np.ndarray:
    t = np.array([int(tint_hex[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255.0
    lum = rgb01 @ np.array([0.299, 0.587, 0.114], np.float32)
    shade = np.clip((lum - 0.06) / 0.84, 0.0, 1.0)
    tint_lum = float(t @ np.array([0.299, 0.587, 0.114], np.float32))
    painted: np.ndarray
    if finish == "matte":
        illum = np.clip(0.70 + 0.30 * shade, 0.65, 1.05)[..., None]
        body = t * illum
        sheen = np.clip(shade, 0, 1)[..., None] * 0.04
        painted = body + sheen
    else:  # gloss
        illum = np.clip(0.40 + 0.65 * shade, 0.38, 1.15)[..., None]
        base = t * illum
        glint = np.clip((lum - 0.72) / 0.28, 0.0, 1.0) ** 3
        painted = base + glint[..., None] * 0.65
        if tint_lum < 0.12:  # gloss black special case: dark base + scene mirror
            black = np.array([0.012, 0.012, 0.016], np.float32) * np.clip(
                0.5 + 0.8 * shade, 0, 1.3)[..., None]
            mirror = rgb01 * np.clip(lum * 1.15, 0, 1)[..., None] ** 1.6 * 0.85
            painted = black + mirror
    alpha = np.clip((mask01 - 0.06) / 0.10, 0.0, 1.0)
    solid = (mask01 > 0.16).astype(np.float32)
    alpha = np.maximum(alpha * 0.65, solid)
    return rgb01 * (1 - alpha[..., None]) + np.clip(painted, 0, 1) * alpha[..., None]


def render_triplet(inp_rgb: np.ndarray, mask01: np.ndarray, tint_hex: str, finish: str) -> np.ndarray:
    h, w = inp_rgb.shape[:2]
    mask01_full = cv2.resize(mask01, (w, h), interpolation=cv2.INTER_LINEAR)

    inp8 = (inp_rgb * 255).astype(np.uint8)

    # Mask debug: green overlay where binary coverage fires
    cov = (mask01_full > 0.16).astype(np.float32)
    green = np.array([80, 240, 90], np.float32)
    debug_bin = (inp8 * (1 - cov[..., None]) + green * cov[..., None]).astype(np.uint8)
    gray_mask = np.clip((mask01_full - 0.06) / 0.10, 0, 1)
    gray_bgr = (gray_mask * 255).astype(np.uint8)
    gray_vis = cv2.cvtColor(gray_bgr, cv2.COLOR_GRAY2BGR)

    painted = (paint_preview(inp_rgb, mask01_full, tint_hex, finish) * 255).astype(np.uint8)
    trip = np.concatenate([debug_bin, gray_vis, painted], axis=1)
    return trip


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--video", default=DEFAULT_VIDEO)
    p.add_argument("--out-name", default=None, help="subfolder name under scratch/corolla_testbed")
    p.add_argument("--onnx", default=str(DEFAULT_ONNX))
    p.add_argument("--start", type=float, default=None, help="start time (seconds)")
    p.add_argument("--end", type=float, default=None, help="end time (seconds)")
    p.add_argument("--stride", type=int, default=3, help="process every Nth frame")
    p.add_argument("--max-frames", type=int, default=400)
    p.add_argument("--viewport", default="0,208,1080,1105", help="x0,y0,x1,y1 of Unity viewport in recording")
    p.add_argument("--mode", choices=["stretch", "square"], default="stretch",
                   help="stretch = phone's 1:1 blit (exact); square = center-crop letterbox")
    p.add_argument("--tint", default="111111")
    p.add_argument("--finish", choices=["gloss", "matte"], default="gloss")
    p.add_argument("--twin", action="store_true", help="run tunable torch twin instead of baked ONNX")
    p.add_argument("--car-pt", default=str(ROOT / "ml" / "yolov8n-seg.pt"))
    p.add_argument("--parts-pt", default=str(ROOT / "ml" / "parts_segmentation.pt"))
    p.add_argument("--export-onnx", metavar="NAME", default=None,
                   help="after a twin run: export tuned wrapper to Assets/Resources/NAME.onnx")
    # threshold overrides
    for name in ("presence", "sil_score", "sil_logit", "paint_score", "paint_logit",
                 "cut_score", "cut_logit", "sharp_lo", "sharp_span", "sil_weight",
                 "parts_presence", "parts_gain", "boost"):
        p.add_argument(f"--{name.replace('_', '-')}", type=float, default=None, dest=name)
    args = p.parse_args()

    x0, y0, x1, y1 = (int(v) for v in args.viewport.split(","))
    thr = MaskThresholds()
    for name in vars(thr):
        cli_val = getattr(args, name, None)
        if cli_val is not None:
            setattr(thr, name, cli_val)

    run_dir = OUT_ROOT / (args.out_name or time.strftime("run_%H%M%S"))
    frames_dir = run_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "config.json").write_text(json.dumps({
        "video": args.video, "viewport": [x0, y0, x1, y1], "mode": args.mode,
        "start": args.start, "end": args.end, "stride": args.stride,
        "thresholds": asdict(thr), "twin": args.twin,
    }, indent=2))

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit(f"cannot open video {args.video}")
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0

    if args.twin:
        runner = TunableMaskRunner(thr, Path(args.car_pt), Path(args.parts_pt))
        backend = "torch twin (tunable)"
    else:
        runner = OnnxMaskRunner(Path(args.onnx))
        backend = "baked CarSegMask.onnx (phone proxy)"

    t0 = time.time()
    idx = proc = empty = 0
    coverages: list[float] = []
    frame_paths: list[str] = []

    if args.start is not None:
        cap.set(cv2.CAP_PROP_POS_MSEC, args.start * 1000.0)

    while True:
        if args.end is not None:
            cur_msec = cap.get(cv2.CAP_PROP_POS_MSEC)
            if cur_msec > 0 and cur_msec >= args.end * 1000.0:
                break
        ok, bgr = cap.read()
        if not ok:
            break
        if idx % args.stride != 0:
            idx += 1
            continue
        if proc >= args.max_frames:
            break
        idx += 1

        vp = bgr[y0:y1, x0:x1]
        if args.mode == "square":
            hh, ww = vp.shape[:2]
            side = min(hh, ww)
            vp = vp[(hh - side) // 2:(hh + side) // 2, (ww - side) // 2:(ww + side) // 2]
        rgb384 = cv2.cvtColor(cv2.resize(vp, (384, 384), interpolation=cv2.INTER_AREA),
                              cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        inp = rgb384.transpose(2, 0, 1)[None]
        out = runner.run(inp)
        mask01 = np.clip(out[0, 0], 0.0, 1.0)

        cov = float((mask01 > 0.16).mean())
        coverages.append(cov)
        if cov < 0.02:
            empty += 1

        vp_rgb = cv2.cvtColor(vp, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        trip = render_triplet(vp_rgb, mask01, args.tint, args.finish)
        tw, th = int(trip.shape[1] * 0.55), int(trip.shape[0] * 0.55)
        trip = cv2.resize(trip, (tw - (tw % 2), th - (th % 2)))
        ph = frames_dir / f"r{proc:04d}.jpg"
        cv2.imwrite(str(ph), trip, [cv2.IMWRITE_JPEG_QUALITY, 92])
        frame_paths.append(str(ph.name))
        proc += 1

    cap.release()

    metrics = {
        "backend": backend, "frames": proc, "empty_frames": empty,
        "src_fps": src_fps, "elapsed_s": round(time.time() - t0, 1),
        "coverage_mean": float(np.mean(coverages)) if coverages else 0.0,
        "coverage_min": float(np.min(coverages)) if coverages else 0.0,
        "coverage_max": float(np.max(coverages)) if coverages else 0.0,
        "coverage_std": float(np.std(coverages)) if coverages else 0.0,
    }
    (run_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))
    (run_dir / "frames.txt").write_text("\n".join(frame_paths))

    if proc:
        import subprocess
        out_mp4 = run_dir / "triplet.mp4"
        subprocess.run([
            ffmpeg_bin(), "-y", "-v", "error",
            "-r", "8", "-i", str(frames_dir / "r%04d.jpg"),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22", str(out_mp4),
        ], check=True)

    if args.export_onnx:
        out_onnx = export_tuned_onnx(thr, args.export_onnx, Path(args.car_pt), Path(args.parts_pt))
        import onnxruntime as ort
        import onnx  # noqa: F401
        sess = ort.InferenceSession(str(out_onnx), providers=["CPUExecutionProvider"])
        zeros = np.zeros((1, 3, 384, 384), dtype=np.float32)
        zm = sess.run(None, {"input": zeros})[0]
        assert zm.max() == 0.0, f"baseline leakage! max={zm.max()}"
        print("Blank-frame validation: OK (max=0.0)")
        # Spot-check: tuned ONNX must match the twin on key frames
        cap = cv2.VideoCapture(args.video)
        for t in ("36.7", "50.4", "86.4", "104.0"):
            cap.set(cv2.CAP_PROP_POS_MSEC, float(t) * 1000)
            ok, bgr = cap.read()
            if not ok:
                continue
            vp = bgr[y0:y1, x0:x1]
            inp = (cv2.cvtColor(cv2.resize(vp, (384, 384)), cv2.COLOR_BGR2RGB)
                   .astype(np.float32) / 255).transpose(2, 0, 1)[None]
            onnx_out = sess.run(None, {"input": inp})[0][0, 0]
            twin_out = runner.run(inp)[0, 0]
            diff = float(np.abs(onnx_out - twin_out).max())
            print(f"  t={t}: onnx_cov={float((onnx_out > 0.16).mean()):.3f} "
                  f"twin_cov={float((twin_out > 0.16).mean()):.3f} maxdiff={diff:.5f}")
        cap.release()

    print(json.dumps(metrics, indent=2))
    print(f"-> {run_dir}")


def export_tuned_onnx(thr: MaskThresholds, name: str, car_pt: Path, parts_pt: Path) -> Path:
    """Bake tuned thresholds + parts-based presence into a fresh self-contained ONNX."""
    import torch
    import torch.nn.functional as F
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from export_sentis_mask import VehiclePaintMaskWrapper

    class TunablePaintMask(VehiclePaintMaskWrapper):
        def __init__(self, car_pt: str, parts_pt: str, thr: MaskThresholds):
            super().__init__(car_pt, parts_pt)
            self.t = thr

        def forward(self, x):
            T = self.t
            car_preds = self.car_yolo(x)
            car_main = car_preds[0][0][0]
            car_proto_flat = car_preds[0][1].view(1, 32, 96 * 96)

            car_cls = car_main[4:84, :]
            veh_scores = (car_cls * self.veh_weights).max(dim=0)[0]
            top_scores, top_idx = torch.topk(veh_scores, k=3, dim=0)

            presence = torch.clamp((top_scores[0] - T.presence) * 5.0, 0.0, 1.0)

            silhouette = torch.zeros(1, 1, 96, 96, device=x.device)
            for i in range(3):
                m = self._eval_anchor(car_main, car_proto_flat, top_idx[i:i + 1],
                                      top_scores[i:i + 1], coeff_start=84,
                                      score_thresh=T.sil_score, logit_thresh=T.sil_logit)
                silhouette = torch.maximum(silhouette, m)

            parts_preds = self.parts_yolo(x)
            parts_main = parts_preds[0][0][0]
            parts_proto_flat = parts_preds[0][1].view(1, 32, 96 * 96)
            parts_cls = parts_main[4:37, :]
            best_scores, best_idx = torch.topk(parts_cls, k=1, dim=1)

            paint_idx = torch.tensor(self.paint_indices, device=x.device)
            paint_best_scores = torch.index_select(best_scores, 0, paint_idx).max()
            presence_parts = torch.clamp((paint_best_scores - T.parts_presence) * T.parts_gain,
                                         0.0, 1.0)
            presence = torch.maximum(presence, presence_parts)

            paint = torch.zeros(1, 1, 96, 96, device=x.device)
            for c in self.paint_indices:
                m = self._eval_anchor(parts_main, parts_proto_flat, best_idx[c], best_scores[c],
                                      coeff_start=37, score_thresh=T.paint_score,
                                      logit_thresh=T.paint_logit)
                paint = torch.maximum(paint, m)

            cutout = torch.zeros(1, 1, 96, 96, device=x.device)
            for c in self.np_indices:
                m = self._eval_anchor(parts_main, parts_proto_flat, best_idx[c], best_scores[c],
                                      coeff_start=37, score_thresh=T.cut_score,
                                      logit_thresh=T.cut_logit)
                cutout = torch.maximum(cutout, m)

            body = torch.maximum(paint, silhouette * T.sil_weight)
            clean = torch.clamp(body - cutout, 0.0, 1.0)
            clean384 = F.interpolate(clean, size=(384, 384), mode="bilinear", align_corners=False)
            sharp = torch.clamp((clean384 - T.sharp_lo) / T.sharp_span, 0.0, 1.0)
            final = torch.clamp(sharp * presence * T.boost, 0.0, 1.0)
            return final

    import onnx
    out_onnx = ROOT / "My project" / "Assets" / "Resources" / f"{name}.onnx"
    out_onnx.parent.mkdir(parents=True, exist_ok=True)
    print(f"Loading tuned twin -> exporting {out_onnx} ...")
    module = TunablePaintMask(str(car_pt), str(parts_pt), thr)
    module.eval()
    dummy = torch.randn(1, 3, 384, 384)
    torch.onnx.export(module, dummy, str(out_onnx), input_names=["input"], output_names=["output"],
                      opset_version=12, dynamo=False, do_constant_folding=True)
    proto = onnx.load(str(out_onnx), load_external_data=True)
    onnx.save_model(proto, str(out_onnx), save_as_external_data=False)
    ext = Path(str(out_onnx) + ".data")
    if ext.exists():
        ext.unlink()
    print("Op types:", sorted({n.op_type for n in proto.graph.node}))
    return out_onnx


def ffmpeg_bin() -> str:
    import shutil
    ff = shutil.which("ffmpeg")
    if ff is None:
        raise SystemExit("ffmpeg not found on PATH")
    return ff


if __name__ == "__main__":
    main()
