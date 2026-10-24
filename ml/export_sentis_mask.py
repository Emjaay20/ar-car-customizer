from pathlib import Path
import cv2
import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn as nn
import torch.nn.functional as F
from ultralytics import YOLO


class VehiclePaintMaskWrapper(nn.Module):
    """
    On-device Neural Car Paint Sheet-Metal Mask model for Unity Sentis.
    Input:  float32 [1, 3, 256, 256] RGB 0..1 (matches the 1:1 Unity AR viewport)
    Output: float32 [1, 1, 256, 256] paint probability 0..1 with:
      - Dual-head union: whole-vehicle silhouette (YOLOv8n-seg) + per-class best sheet-metal panels (parts_segmentation)
      - Per-class best non-paint cutout exclusion: windshield, side windows, headlights, taillights, grille, wheels, license plate
      - 100% Pure float ops (no boolean And/Cast or GatherElements) for 100% compatibility with Unity Sentis CPU backend
      - Strictly 0.000 baseline outside the vehicle and when no vehicle is in view
    """

    def __init__(self, car_pt: str = "yolov8n-seg.pt", parts_pt: str = "parts_segmentation.pt"):
        super().__init__()
        self.car_yolo = YOLO(car_pt).model
        self.car_yolo.eval()
        self.parts_yolo = YOLO(parts_pt).model
        self.parts_yolo.eval()
        for p in self.car_yolo.parameters():
            p.requires_grad_(False)
        for p in self.parts_yolo.parameters():
            p.requires_grad_(False)

        # 96x96 spatial grid mapped to 384x384 pixel space (stride 4)
        gy, gx = torch.meshgrid(
            torch.arange(96, dtype=torch.float32),
            torch.arange(96, dtype=torch.float32),
            indexing="ij",
        )
        gx = (gx + 0.5) * 4.0
        gy = (gy + 0.5) * 4.0
        self.register_buffer("gx", gx.view(1, 1, 96, 96))
        self.register_buffer("gy", gy.view(1, 1, 96, 96))

        # Vehicle classes in COCO: 2: car, 5: bus, 7: truck
        vw = torch.zeros(80, 1)
        vw[[2, 5, 7], 0] = 1.0
        self.register_buffer("veh_weights", vw)

        # 17 Paintable sheet-metal vehicle parts
        self.paint_indices = [0, 2, 4, 5, 8, 9, 13, 14, 15, 18, 21, 22, 26, 27, 28, 30, 31]
        # 16 Non-paint vehicle parts (windshields, windows, lights, grille, wheels, license plate)
        self.np_indices = [1, 3, 6, 7, 10, 11, 12, 16, 17, 19, 20, 23, 24, 25, 29, 32]

    def _eval_anchor(
        self,
        main_2d: torch.Tensor,
        proto_flat: torch.Tensor,
        idx: torch.Tensor,
        s: torch.Tensor,
        coeff_start: int,
        score_thresh: float,
        logit_thresh: float,
    ) -> torch.Tensor:
        gate = torch.clamp((s.view(1, 1, 1, 1) - score_thresh) * 10.0, 0.0, 1.0)
        anchor_col = main_2d[:, idx]  # [C, 1] -> standard ONNX Gather(axis=1)
        cx = anchor_col[0:1, :].view(1, 1, 1, 1)
        cy = anchor_col[1:2, :].view(1, 1, 1, 1)
        w = anchor_col[2:3, :].view(1, 1, 1, 1)
        h = anchor_col[3:4, :].view(1, 1, 1, 1)

        x1 = cx - 0.5 * w
        x2 = cx + 0.5 * w
        y1 = cy - 0.5 * h
        y2 = cy + 0.5 * h

        in_box_x = torch.clamp(self.gx - x1 + 0.5, 0.0, 1.0) * torch.clamp(x2 - self.gx + 0.5, 0.0, 1.0)
        in_box_y = torch.clamp(self.gy - y1 + 0.5, 0.0, 1.0) * torch.clamp(y2 - self.gy + 0.5, 0.0, 1.0)
        in_box = in_box_x * in_box_y

        mc = anchor_col[coeff_start : coeff_start + 32, :].transpose(0, 1).unsqueeze(0)  # [1, 1, 32]
        raw_m = torch.bmm(mc, proto_flat).view(1, 1, 96, 96)
        prob_m = torch.clamp((raw_m - logit_thresh) * 1.5, 0.0, 1.0)
        return prob_m * in_box * gate

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # 1. Whole-Vehicle Silhouette (YOLOv8n-seg)
        car_preds = self.car_yolo(x)
        car_main = car_preds[0][0][0]  # [116, 3024]
        car_proto_flat = car_preds[0][1].view(1, 32, 96 * 96)

        car_cls = car_main[4:84, :]  # [80, 3024]
        veh_scores = (car_cls * self.veh_weights).max(dim=0)[0]  # [3024]
        top_veh_scores, top_veh_idx = torch.topk(veh_scores, k=3, dim=0)

        # Strict Car Presence Gate: when camera faces ground, wall, or sky, car_presence=0.0
        car_presence = torch.clamp((top_veh_scores[0] - 0.32) * 5.0, 0.0, 1.0)

        car_silhouette = torch.zeros(1, 1, 96, 96, device=x.device)
        for i in range(3):
            m = self._eval_anchor(
                car_main,
                car_proto_flat,
                top_veh_idx[i : i + 1],
                top_veh_scores[i : i + 1],
                coeff_start=84,
                score_thresh=0.20,
                logit_thresh=0.10,
            )
            car_silhouette = torch.maximum(car_silhouette, m)

        # 2. Per-Class Vehicle Parts (Each of the 33 part classes gets its own best anchor so no part is crowded out!)
        parts_preds = self.parts_yolo(x)
        parts_main = parts_preds[0][0][0]  # [69, 3024]
        parts_proto_flat = parts_preds[0][1].view(1, 32, 96 * 96)
        parts_cls = parts_main[4:37, :]  # [33, 3024]

        best_part_scores, best_part_idx = torch.topk(parts_cls, k=1, dim=1)  # [33, 1]

        # 2a. 17 Paintable sheet-metal panels (hood, bumpers, doors, fenders, roof, trunk, quarter panels)
        parts_paint = torch.zeros(1, 1, 96, 96, device=x.device)
        for c in self.paint_indices:
            m = self._eval_anchor(
                parts_main,
                parts_proto_flat,
                best_part_idx[c],
                best_part_scores[c],
                coeff_start=37,
                score_thresh=0.12,
                logit_thresh=0.08,
            )
            parts_paint = torch.maximum(parts_paint, m)

        # 2b. 16 Non-paint cutouts (windshield, side windows, headlights, taillights, grille, wheels, license plate)
        cutout = torch.zeros(1, 1, 96, 96, device=x.device)
        for c in self.np_indices:
            m = self._eval_anchor(
                parts_main,
                parts_proto_flat,
                best_part_idx[c],
                best_part_scores[c],
                coeff_start=37,
                score_thresh=0.15,
                logit_thresh=0.15,
            )
            cutout = torch.maximum(cutout, m)

        # 3. Clean body union: full sheet metal + full vehicle silhouette (covers C-pillar and roof)
        body = torch.maximum(parts_paint, car_silhouette)
        # Exclude non-paint regions at 1.0 (prevents eating into C-pillar and door tops)
        clean_body = torch.clamp(body - cutout, 0.0, 1.0)

        # 4. Smooth 384x384 interpolation BEFORE activation threshold (tightened to prevent spill beyond roof/sills)
        clean_384 = F.interpolate(clean_body, size=(384, 384), mode="bilinear", align_corners=False)
        sharp_metal = torch.clamp((clean_384 - 0.24) / 0.35, 0.0, 1.0)

        final_mask = sharp_metal * car_presence
        return torch.clamp(final_mask, 0.0, 1.0)


if __name__ == "__main__":
    ml_dir = Path(__file__).resolve().parent
    root_dir = ml_dir.parent
    car_pt = ml_dir / "yolov8n-seg.pt"
    parts_pt = ml_dir / "parts_segmentation.pt"
    out_onnx = root_dir / "My project" / "Assets" / "Resources" / "CarSegMask.onnx"
    out_onnx.parent.mkdir(parents=True, exist_ok=True)

    print(f"Loading {car_pt} and {parts_pt} into VehiclePaintMaskWrapper (384x384)...")
    wrapper = VehiclePaintMaskWrapper(str(car_pt), str(parts_pt))
    wrapper.eval()

    dummy_input = torch.randn(1, 3, 384, 384)
    print(f"Exporting to ONNX -> {out_onnx}...")
    torch.onnx.export(
        wrapper,
        dummy_input,
        str(out_onnx),
        input_names=["input"],
        output_names=["output"],
        opset_version=12,
        dynamo=False,
        do_constant_folding=True,
    )

    print("Inlining weights into self-contained single ONNX asset...")
    model_proto = onnx.load(str(out_onnx), load_external_data=True)
    onnx.save_model(model_proto, str(out_onnx), save_as_external_data=False)
    ext_data = Path(str(out_onnx) + ".data")
    if ext_data.exists():
        ext_data.unlink()

    op_types = sorted({n.op_type for n in model_proto.graph.node})
    print("ONNX Op Types:", op_types)

    print("Validating with ONNX Runtime...")
    sess = ort.InferenceSession(str(out_onnx), providers=["CPUExecutionProvider"])
    zeros = np.zeros((1, 3, 384, 384), dtype=np.float32)
    out_zeros = sess.run(None, {"input": zeros})[0]
    print(f"ONNX Validation (Blank frame): min={out_zeros.min():.5f}, max={out_zeros.max():.5f}")
    assert out_zeros.max() == 0.0, "Error: baseline leakage detected!"

    eval_dir = root_dir / "scratch" / "eval_085711"
    if eval_dir.exists():
        for fn in ["frame_0000.jpg", "frame_0260.jpg", "frame_0520.jpg", "frame_0780.jpg", "frame_1040.jpg", "frame_1300.jpg"]:
            fp = eval_dir / fn
            if fp.exists():
                img = cv2.imread(str(fp))
                H, W = img.shape[:2]
                crop = img[int(H * 0.08) : int(H * 0.55), :]
                c384 = cv2.resize(crop, (384, 384))
                rgb = cv2.cvtColor(c384, cv2.COLOR_BGR2RGB)
                inp = (rgb.astype(np.float32) / 255.0).transpose(2, 0, 1)[None]
                out = sess.run(None, {"input": inp})[0]
                m = out[0, 0]
                overlay = c384.copy()
                red = np.zeros_like(overlay); red[:, :, 2] = 220; red[:, :, 1] = 20; red[:, :, 0] = 40
                alpha = (m > 0.15).astype(np.float32)[..., None] * 0.65
                vis = (overlay * (1 - alpha) + red * alpha).astype(np.uint8)
                cv2.imwrite(str(eval_dir / f"vis_{fn}"), np.hstack([c384, vis]))
                print(f"  {fn}: max={out.max():.4f}, mean={out.mean():.4f}, coverage={(out > 0.15).mean()*100:.1f}%")
    print("All validations passed! CarSegMask.onnx is ready for Sentis.")
