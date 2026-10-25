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

        # 15 core paintable sheet-metal panels + 2 side-mirror caps (gated against dark mirror glass)
        self.core_paint_indices = [0, 2, 4, 5, 8, 9, 14, 15, 18, 21, 22, 27, 28, 30, 31]
        self.mirror_indices = [13, 26]
        self.paint_indices = [0, 2, 4, 5, 8, 9, 13, 14, 15, 18, 21, 22, 26, 27, 28, 30, 31]
        # Low-body panels that cannot exist solely in the top 35% sky/background strip (prevents painting distant parked cars)
        self.low_body_set = {0, 2, 4, 8, 21, 15, 28}
        # Separated Non-Paint Cutout Groups for Tucked Vinyl Edge Physics:
        # Windows (6 classes): back-windshield, left/right back/front windows, windshield
        self.win_indices = [1, 7, 11, 20, 24, 32]
        # Wheels (4 classes): left/right back/front wheels
        self.wheel_indices = [6, 10, 19, 23]
        # Lamps, Grille & License Plate (6 classes): grille, headlights, taillights, license-plate
        self.other_np_indices = [3, 12, 16, 17, 25, 29]
        self.np_indices = [1, 3, 6, 7, 10, 11, 12, 16, 17, 19, 20, 23, 24, 25, 29, 32]

    def _eval_anchors_batched(
        self,
        main_2d: torch.Tensor,
        proto_flat: torch.Tensor,
        indices_1d: torch.Tensor,
        scores_1d: torch.Tensor,
        coeff_start: int,
        score_thresh: float,
        logit_thresh: float,
        reject_distant_top: bool = False,
    ) -> torch.Tensor:
        # indices_1d: [N], scores_1d: [N]
        gate = torch.clamp((scores_1d.view(1, -1, 1, 1) - score_thresh) * 10.0, 0.0, 1.0)
        anchor_cols = main_2d[:, indices_1d]  # [C, N] -> single ONNX Gather(axis=1)
        cx = anchor_cols[0:1, :].transpose(0, 1).view(1, -1, 1, 1)
        cy = anchor_cols[1:2, :].transpose(0, 1).view(1, -1, 1, 1)
        w = anchor_cols[2:3, :].transpose(0, 1).view(1, -1, 1, 1)
        h = anchor_cols[3:4, :].transpose(0, 1).view(1, -1, 1, 1)

        x1 = cx - 0.5 * w
        x2 = cx + 0.5 * w
        y1 = cy - 0.5 * h
        y2 = cy + 0.5 * h

        if reject_distant_top:
            # Distant background cars sit entirely in the upper 35% of the viewport (y2 < 135 in 384px space)
            fg_gate = torch.clamp((y2 - 135.0) * 0.10, 0.0, 1.0)
            gate = gate * fg_gate

        in_box_x = torch.clamp(self.gx - x1 + 0.5, 0.0, 1.0) * torch.clamp(x2 - self.gx + 0.5, 0.0, 1.0)
        in_box_y = torch.clamp(self.gy - y1 + 0.5, 0.0, 1.0) * torch.clamp(y2 - self.gy + 0.5, 0.0, 1.0)
        in_box = in_box_x * in_box_y  # [1, N, 96, 96]

        mc = anchor_cols[coeff_start : coeff_start + 32, :].transpose(0, 1).unsqueeze(0)  # [1, N, 32]
        raw_m = torch.bmm(mc, proto_flat).view(1, -1, 96, 96)
        prob_m = torch.clamp((raw_m - logit_thresh) * 1.5, 0.0, 1.0)
        masked = prob_m * in_box * gate  # [1, N, 96, 96]
        return masked.max(dim=1, keepdim=True)[0]  # [1, 1, 96, 96]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # 384x384 and 96x96 luminance for physical material/trim gating & edge-guided filtering
        luma_384 = 0.299 * x[:, 0:1, :, :] + 0.587 * x[:, 1:2, :, :] + 0.114 * x[:, 2:3, :, :]
        luma_96 = F.avg_pool2d(luma_384, kernel_size=4, stride=4)
        mirror_cap_gate = torch.clamp((luma_96 - 0.26) * 6.0, 0.0, 1.0)

        # 1. Primary Whole-Vehicle Silhouette (YOLOv8n-seg, primary foreground anchor only)
        car_preds = self.car_yolo(x)
        car_main = car_preds[0][0][0]  # [116, 3024]
        car_proto_flat = car_preds[0][1].view(1, 32, 96 * 96)

        car_cls = car_main[4:84, :]  # [80, 3024]
        veh_scores = (car_cls * self.veh_weights).max(dim=0)[0]  # [3024]
        top_veh_scores, top_veh_idx = torch.topk(veh_scores, k=2, dim=0)

        veh_presence = torch.clamp((top_veh_scores[0] - 0.20) * 10.0, 0.0, 1.0)

        car_silhouette = self._eval_anchors_batched(
            car_main,
            car_proto_flat,
            top_veh_idx[0:1],
            top_veh_scores[0:1],
            coeff_start=84,
            score_thresh=0.22,
            logit_thresh=0.18,
            reject_distant_top=True,
        )

        # 2. Per-Class Vehicle Parts (33 part classes, top-4 anchors per class for split lamps/windows)
        parts_preds = self.parts_yolo(x)
        parts_main = parts_preds[0][0][0]  # [69, 3024]
        parts_proto_flat = parts_preds[0][1].view(1, 32, 96 * 96)
        parts_cls = parts_main[4:37, :]  # [33, 3024]

        best_part_scores_k4, best_part_idx_k4 = torch.topk(parts_cls, k=4, dim=1)  # [33, 4]
        best_part_scores_k2 = best_part_scores_k4[:, 0:2]
        best_part_idx_k2 = best_part_idx_k4[:, 0:2]

        # 2a. Core paintable sheet-metal panels (split into low-body vs upper-body for distant-car rejection)
        low_indices = [c for c in self.core_paint_indices if c in self.low_body_set]
        upper_indices = [c for c in self.core_paint_indices if c not in self.low_body_set]

        paint_low = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k2[low_indices].reshape(-1),
            best_part_scores_k2[low_indices].reshape(-1),
            coeff_start=37,
            score_thresh=0.11,
            logit_thresh=0.06,
            reject_distant_top=True,
        )
        paint_upper = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k2[upper_indices].reshape(-1),
            best_part_scores_k2[upper_indices].reshape(-1),
            coeff_start=37,
            score_thresh=0.11,
            logit_thresh=0.06,
            reject_distant_top=False,
        )
        parts_paint = torch.maximum(paint_low, paint_upper)

        max_paint_score = best_part_scores_k4[self.core_paint_indices, 0].max()
        parts_presence = torch.clamp((max_paint_score - 0.20) * 8.0, 0.0, 1.0)
        car_presence = torch.maximum(veh_presence, parts_presence)

        # 2b. Side mirrors: paint outer housing
        mirror_paint = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k2[self.mirror_indices].reshape(-1),
            best_part_scores_k2[self.mirror_indices].reshape(-1),
            coeff_start=37,
            score_thresh=0.14,
            logit_thresh=0.10,
            reject_distant_top=False,
        )
        parts_paint = torch.maximum(parts_paint, mirror_paint * mirror_cap_gate)

        # 2c. Multi-Anchor Protected Cutouts (k=4 captures both inner & outer pieces of split taillights)
        win_raw = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k4[self.win_indices].reshape(-1),
            best_part_scores_k4[self.win_indices].reshape(-1),
            coeff_start=37,
            score_thresh=0.06,
            logit_thresh=0.08,
        )
        wheel_raw = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k4[self.wheel_indices].reshape(-1),
            best_part_scores_k4[self.wheel_indices].reshape(-1),
            coeff_start=37,
            score_thresh=0.12,
            logit_thresh=0.10,
        )
        grille_raw = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k4[[3]].reshape(-1),
            best_part_scores_k4[[3]].reshape(-1),
            coeff_start=37,
            score_thresh=0.18,
            logit_thresh=0.12,
        )
        lamps_plate_raw = self._eval_anchors_batched(
            parts_main,
            parts_proto_flat,
            best_part_idx_k4[[12, 16, 17, 25, 29]].reshape(-1),
            best_part_scores_k4[[12, 16, 17, 25, 29]].reshape(-1),
            coeff_start=37,
            score_thresh=0.18,
            logit_thresh=0.12,
        )

        # Tucked Vinyl Boundary Physics at 96x96 (Paint-Agnostic, no luminance suppression of dark sheet metal)
        # 1) Tight window sealing (narrow 7x7 local boundary, never 45x45 screen-wide dilation)
        win_frame_zone = F.max_pool2d(win_raw, kernel_size=7, stride=1, padding=3)
        win_sealed = torch.maximum(win_raw, win_frame_zone * 0.85)

        other_tucked = torch.maximum(grille_raw, lamps_plate_raw)
        cutout = torch.maximum(torch.maximum(win_sealed, wheel_raw), other_tucked)

        # 2) Morphological seam bridging (below roof crown)
        below_roof_crown = torch.clamp((self.gy - 44.0) * 0.10, 0.0, 1.0)
        closed_parts = 1.0 - F.max_pool2d(
            1.0 - F.max_pool2d(parts_paint, kernel_size=9, stride=1, padding=4),
            kernel_size=9,
            stride=1,
            padding=4,
        )
        bridged_parts = torch.maximum(parts_paint, closed_parts * below_roof_crown)

        # 3) Silhouette interior assist when vehicle envelope is present
        sil_eroded = 1.0 - F.max_pool2d(1.0 - car_silhouette, kernel_size=5, stride=1, padding=2)
        car_structure = torch.maximum(parts_paint, win_raw)
        structure_halo = F.max_pool2d(car_structure, kernel_size=25, stride=1, padding=12)
        sil_assist = sil_eroded * torch.clamp(structure_halo * 1.15, 0.0, 0.90) * below_roof_crown
        body = torch.maximum(bridged_parts, sil_assist)

        # 4) Ground plane rejection: zero out below wheel/ground contact line (gy > 350 in 384px space)
        ground_gate = torch.clamp((350.0 - self.gy) * 0.05, 0.0, 1.0)

        # Strict priority for protected cutouts (windows, split taillights, headlights, grille, wheels, plate)
        clean_body = torch.clamp(body - cutout * 1.45, 0.0, 1.0) * ground_gate

        # 5. In-Graph 384x384 Fast Edge-Guided Filter
        smooth_96 = F.avg_pool2d(clean_body, kernel_size=3, stride=1, padding=1)
        p = F.interpolate(smooth_96, size=(384, 384), mode="bilinear", align_corners=False)
        I = luma_384

        mean_I = F.avg_pool2d(I, kernel_size=9, stride=1, padding=4)
        mean_p = F.avg_pool2d(p, kernel_size=9, stride=1, padding=4)
        mean_Ip = F.avg_pool2d(I * p, kernel_size=9, stride=1, padding=4)
        mean_II = F.avg_pool2d(I * I, kernel_size=9, stride=1, padding=4)

        cov_Ip = mean_Ip - mean_I * mean_p
        var_I = torch.clamp(mean_II - mean_I * mean_I, min=0.0) + 0.0015
        a = cov_Ip / var_I
        b = mean_p - a * mean_I

        mean_a = F.avg_pool2d(a, kernel_size=9, stride=1, padding=4)
        mean_b = F.avg_pool2d(b, kernel_size=9, stride=1, padding=4)
        guided_384 = torch.clamp(mean_a * I + mean_b, 0.0, 1.0)

        sharp_metal = torch.clamp((guided_384 - 0.08) / 0.42, 0.0, 1.0)

        final_mask = torch.clamp(sharp_metal, 0.0, 1.0) * car_presence
        return torch.clamp(final_mask, 0.0, 1.0)


if __name__ == "__main__":
    ml_dir = Path(__file__).resolve().parent
    root_dir = ml_dir.parent
    car_pt = ml_dir / "yolov8n-seg.pt"
    parts_pt = ml_dir / "parts_segmentation.pt"
    out_onnx = root_dir / "My project" / "Assets" / "Resources" / "CarSegMask.onnx"
    out_onnx.parent.mkdir(parents=True, exist_ok=True)
    tmp_dir = root_dir / "scratch"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_onnx = tmp_dir / "CarSegMask_build.onnx"

    print(f"Loading {car_pt} and {parts_pt} into VehiclePaintMaskWrapper (384x384)...")
    wrapper = VehiclePaintMaskWrapper(str(car_pt), str(parts_pt))
    wrapper.eval()

    dummy_input = torch.randn(1, 3, 384, 384)
    print(f"Exporting to ONNX -> {tmp_onnx}...")
    torch.onnx.export(
        wrapper,
        dummy_input,
        str(tmp_onnx),
        input_names=["input"],
        output_names=["output"],
        opset_version=12,
        dynamo=False,
        do_constant_folding=True,
    )

    print("Inlining weights into self-contained single ONNX asset...")
    model_proto = onnx.load(str(tmp_onnx), load_external_data=True)
    onnx.save_model(model_proto, str(tmp_onnx), save_as_external_data=False)
    ext_data = Path(str(tmp_onnx) + ".data")
    if ext_data.exists():
        ext_data.unlink()

    import shutil
    shutil.copyfile(str(tmp_onnx), str(out_onnx))
    tuned_dup = out_onnx.parent / "CarSegMaskTuned.onnx"
    if tuned_dup.exists():
        tuned_dup.unlink()
    tuned_meta = out_onnx.parent / "CarSegMaskTuned.onnx.meta"
    if tuned_meta.exists():
        tuned_meta.unlink()

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
