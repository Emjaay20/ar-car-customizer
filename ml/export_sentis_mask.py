import os
from pathlib import Path
import cv2
import numpy as np
import onnx
import torch
import torch.nn as nn
import torch.nn.functional as F
from ultralytics import YOLO


class YoloMaskWrapper(nn.Module):
    """
    On-device 256x256 sheet-metal paint mask model for Unity Sentis.
    Input:  float32 [1, 3, 256, 256] RGB 0..1 (row 0 = top of screen, row 255 = bottom)
    Output: float32 [1, 1, 256, 256] paint probability 0..1 with:
      - Foreground car selection (center + area weighted)
      - Bounding-box clamping (zero prototype bleed outside the car)
      - In-graph windshield / side-window cabin cutout
      - In-graph headlight / chrome / wheel cutout
    """

    def __init__(self, model_path: str = "yolov8n-seg.pt"):
        super().__init__()
        self.yolo = YOLO(model_path).model
        self.yolo.eval()
        for p in self.yolo.parameters():
            p.requires_grad_(False)

        gy, gx = torch.meshgrid(
            torch.arange(256, dtype=torch.float32),
            torch.arange(256, dtype=torch.float32),
            indexing="ij",
        )
        self.register_buffer("gx", gx.view(1, 1, 256, 256))
        self.register_buffer("gy", gy.view(1, 1, 256, 256))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        preds = self.yolo(x)
        main_out = preds[0][0]  # [1, 116, 1344]
        proto = preds[0][1]     # [1, 32, 64, 64]

        bx = main_out[:, 0, :]
        by = main_out[:, 1, :]
        bw = main_out[:, 2, :]
        bh = main_out[:, 3, :]

        # Class 2 = car (index 6), Class 7 = truck/SUV (index 11)
        car_scores = main_out[:, 6, :]
        truck_scores = main_out[:, 11, :] * 0.90
        vehicle_scores = torch.maximum(car_scores, truck_scores)

        # Favor the primary foreground vehicle (large area + near center of camera view)
        area_norm = torch.clamp((bw * bh) / (256.0 * 256.0), 0.0, 0.65)
        dist2 = ((bx - 128.0) / 128.0) ** 2 + ((by - 128.0) / 128.0) ** 2
        center_weight = 1.0 / (1.0 + 0.85 * dist2)
        rank_score = vehicle_scores * center_weight * (0.55 + area_norm)

        best_idx = torch.argmax(rank_score, dim=1)  # [1]
        best_conf = main_out[:, 6, best_idx].clamp(min=truck_scores[:, best_idx]).view(1, 1, 1, 1)
        conf_gate = torch.sigmoid((best_conf - 0.20) * 40.0)

        cx = bx[:, best_idx].view(1, 1, 1, 1)
        cy = by[:, best_idx].view(1, 1, 1, 1)
        w = torch.clamp(bw[:, best_idx].view(1, 1, 1, 1), min=16.0)
        h = torch.clamp(bh[:, best_idx].view(1, 1, 1, 1), min=16.0)

        x1 = cx - 0.5 * w
        y1 = cy - 0.5 * h
        x2 = cx + 0.5 * w
        y2 = cy + 0.5 * h

        mask_coeffs = main_out[:, 84:, best_idx].squeeze(2)  # [1, 32]
        proto_flat = proto.view(1, 32, -1)                   # [1, 32, 4096]
        raw_mask = torch.bmm(mask_coeffs.unsqueeze(1), proto_flat).view(1, 1, 64, 64)
        car_prob = torch.sigmoid(raw_mask)
        car_prob = F.interpolate(car_prob, size=(256, 256), mode="bilinear", align_corners=False)

        # 1. Strict bounding-box clamp so prototype activations outside the car box are zeroed
        in_box_x = torch.sigmoid((self.gx - x1) * 1.5) * torch.sigmoid((x2 - self.gx) * 1.5)
        in_box_y = torch.sigmoid((self.gy - y1) * 1.5) * torch.sigmoid((y2 - self.gy) * 1.5)
        car_silhouette = car_prob * in_box_x * in_box_y * conf_gate

        # Soft threshold + 1px morphological erosion (-max_pool2d) to prevent outer edge bleed
        car_binary = torch.sigmoid((car_silhouette - 0.48) * 18.0)
        car_eroded = -F.max_pool2d(-car_binary, kernel_size=3, stride=1, padding=1)

        rel_x = (self.gx - x1) / w
        rel_y = (self.gy - y1) / h
        dx = torch.abs(rel_x - 0.5)

        # 2. Cabin / Windshield / Side-Windows Cutout (tracks box dynamically as camera moves)
        cabin_half_w = 0.27 + 0.36 * torch.clamp(rel_y - 0.06, 0.0, 0.40)
        in_cabin_y = torch.sigmoid((rel_y - 0.075) * 45.0) * torch.sigmoid((0.415 - rel_y) * 40.0)
        in_cabin_x = torch.sigmoid((cabin_half_w - dx) * 35.0)
        cabin_cutout = in_cabin_y * in_cabin_x

        # 3. Headlights, Chrome Emblem & Bright Glare Cutout from RGB input
        r = x[:, 0:1, :, :]
        g = x[:, 1:2, :, :]
        b = x[:, 2:3, :, :]
        luma = 0.299 * r + 0.587 * g + 0.114 * b
        cmax = torch.maximum(r, torch.maximum(g, b))
        cmin = torch.minimum(r, torch.minimum(g, b))
        sat = (cmax - cmin) / (cmax + 1e-4)

        headlight_cutout = (
            torch.sigmoid((rel_y - 0.43) * 30.0)
            * torch.sigmoid((luma - 0.72) * 25.0)
            * torch.sigmoid((0.26 - sat) * 20.0)
        )

        # 4. Lower Wheel-Wells & Tire Cutout
        wheel_cutout = torch.sigmoid((rel_y - 0.75) * 35.0) * torch.sigmoid((dx - 0.30) * 30.0)
        underbody_cutout = torch.sigmoid((rel_y - 0.90) * 45.0)

        total_cutout = torch.clamp(
            cabin_cutout + headlight_cutout + wheel_cutout + underbody_cutout,
            0.0,
            1.0,
        )

        paint_mask = car_eroded * (1.0 - total_cutout)
        paint_mask = F.avg_pool2d(paint_mask, kernel_size=3, stride=1, padding=1)
        return torch.clamp(paint_mask, 0.0, 1.0)


if __name__ == "__main__":
    ml_dir = Path(__file__).resolve().parent
    root_dir = ml_dir.parent
    model_pt = ml_dir / "yolov8n-seg.pt"
    if not model_pt.exists():
        model_pt = root_dir / "yolov8n-seg.pt"

    wrapper = YoloMaskWrapper(str(model_pt))
    wrapper.eval()

    # Quick forward sanity check on real car image if present
    sample_img = ml_dir / "car.jpg"
    if sample_img.exists():
        bgr = cv2.imread(str(sample_img))
        rgb = cv2.cvtColor(cv2.resize(bgr, (256, 256)), cv2.COLOR_BGR2RGB)
        inp = torch.from_numpy(rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0
        with torch.no_grad():
            out_mask = wrapper(inp)
        active_px = int((out_mask > 0.35).sum().item())
        print(f"Sanity check on car.jpg: active sheet-metal pixels = {active_px} / 65536")

    dummy_input = torch.randn(1, 3, 256, 256)
    out_onnx = root_dir / "My project" / "Assets" / "Resources" / "CarSegMask.onnx"
    torch.onnx.export(
        wrapper,
        dummy_input,
        str(out_onnx),
        input_names=["input"],
        output_names=["output"],
        opset_version=17,
        do_constant_folding=True,
    )

    # Inline external weights so CarSegMask.onnx is a single self-contained file for Unity Sentis
    model_proto = onnx.load(str(out_onnx), load_external_data=True)
    onnx.save_model(model_proto, str(out_onnx), save_as_external_data=False)
    ext_data = Path(str(out_onnx) + ".data")
    if ext_data.exists():
        ext_data.unlink()

    print(f"Exported self-contained CarSegMask.onnx to {out_onnx} ({out_onnx.stat().st_size} bytes)")
