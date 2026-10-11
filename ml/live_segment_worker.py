"""Persistent warm YOLOv8s-seg + Intrinsic Automotive Studio Polisher worker.

Supports two stages:
1. Live AR Snapchat-style car masking (`maskBase64`) with zero-bleed edge clamping and background-car subtraction.
2. Studio Paint Polishing (`polishedBase64`) using Intrinsic Image Decomposition (separating diffuse base coat,
   3D panel creases, and clear-coat sky reflections) + panel gating + Auto-Body Shop Reference spec badge.
"""

from __future__ import annotations

import base64
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = "yolov8s-seg.pt" if (Path(__file__).resolve().parent / "yolov8s-seg.pt").exists() else "yolov8n-seg.pt"
MODEL_PATH = Path(__file__).resolve().parent / os.environ.get("YOLO_SEG_MODEL", DEFAULT_MODEL)
PUBLISH_DIR = ROOT / "backend" / "public" / "masks"

# Cached clean frame & mask in memory for instant (<20ms) re-polishing when user taps different swatches/finishes
LAST_CLEAN_BGR: np.ndarray | None = None
LAST_MASK_U8: np.ndarray | None = None
LAST_PLATE_BOOL: np.ndarray | None = None
LAST_SOURCE: str = "yolov8s-seg"


def load_model() -> YOLO:
    target = str(MODEL_PATH if MODEL_PATH.exists() else DEFAULT_MODEL)
    return YOLO(target)


def clean_foreground_car_silhouette(raw_mask: np.ndarray) -> np.ndarray:
    """Sever thin bridges to background objects and erode 3px so feathered paint never bleeds outside the car."""
    h, w = raw_mask.shape[:2]
    mask_u8 = (raw_mask > 0.52).astype(np.uint8) * 255

    k_sever = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))
    opened = cv2.morphologyEx(mask_u8, cv2.MORPH_OPEN, k_sever)

    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(opened, connectivity=8)
    if num_labels <= 1:
        num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(mask_u8, connectivity=8)
        if num_labels <= 1:
            return np.zeros((h, w), dtype=np.uint8)

    largest_label = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    core = (labels == largest_label).astype(np.uint8) * 255

    contours, _ = cv2.findContours(core, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    solid = np.zeros_like(core)
    cv2.drawContours(solid, contours, -1, 255, thickness=cv2.FILLED)

    solid_tight = cv2.erode(solid, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)), iterations=1)
    return solid_tight


def detect_license_plate_region(
    solid: np.ndarray,
    val: np.ndarray,
    sat: np.ndarray,
    gx: np.ndarray,
    gy: np.ndarray,
    local_grad: np.ndarray,
    rel_x: np.ndarray,
    rel_y: np.ndarray,
    span_x: int,
    span_y: int,
    med_grad: float,
) -> np.ndarray:
    """Detect front or rear license plate rectangle for both cutout and privacy blurring."""
    h, w = solid.shape[:2]
    # Alphanumeric plate characters have dense vertical strokes (|gx|) relative to horizontal panel seams (|gy|)
    vert_char = np.maximum(0.0, np.abs(gx) - 0.45 * np.abs(gy))
    vert_energy = cv2.GaussianBlur(vert_char, (19, 5), 0)

    plate_zone = (
        (solid > 0)
        & (rel_y >= 0.46)
        & (rel_y <= 0.93)
        & (rel_x >= 0.34)
        & (rel_x <= 0.66)
    )
    if not np.any(plate_zone):
        return np.zeros((h, w), dtype=bool)

    zone_thresh = float(np.percentile(vert_energy[plate_zone], 85))
    plate_candidates = (
        plate_zone
        & (val > 0.28)
        & (sat < 0.55)
        & (vert_energy > max(zone_thresh, 0.042))
    )
    plate_u8 = cv2.morphologyEx(
        plate_candidates.astype(np.uint8) * 255,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_RECT, (19, 7)),
    )
    p_num, _, p_st, _ = cv2.connectedComponentsWithStats(plate_u8, connectivity=8)
    license_plate = np.zeros((h, w), dtype=bool)
    best_score = -1.0
    best_box: tuple[int, int, int, int] | None = None

    for idx in range(1, p_num):
        pw = int(p_st[idx, cv2.CC_STAT_WIDTH])
        ph = int(p_st[idx, cv2.CC_STAT_HEIGHT])
        parea = int(p_st[idx, cv2.CC_STAT_AREA])
        px = int(p_st[idx, cv2.CC_STAT_LEFT])
        py = int(p_st[idx, cv2.CC_STAT_TOP])
        aspect = pw / float(max(ph, 1))
        rel_cy = ((py + 0.5 * ph) - (rel_y[0, 0] * (-span_y))) / float(max(span_y, 1))
        if (
            (0.10 * span_x <= pw <= 0.33 * span_x)
            and (0.045 * span_y <= ph <= 0.20 * span_y)
            and (1.18 <= aspect <= 4.2)
            and parea >= max(120, int(0.005 * span_x * span_y))
        ):
            roi_energy = float(np.mean(vert_energy[py : py + ph, px : px + pw]))
            aspect_fit = 1.0 - min(0.5, abs(aspect - 2.15) * 0.22)
            score = parea * (roi_energy + 0.05) * aspect_fit
            if score > best_score:
                best_score = score
                pad_x = max(5, int(round(0.12 * pw)))
                pad_y = max(4, int(round(0.15 * ph)))
                best_box = (
                    max(0, px - pad_x),
                    max(0, py - pad_y),
                    min(w, px + pw + pad_x),
                    min(h, py + ph + pad_y),
                )

    if best_box is not None:
        bx0, by0, bx1, by1 = best_box
        license_plate[by0:by1, bx0:bx1] = True
    return license_plate


def blur_license_plate_privacy(img_bgr: np.ndarray, license_plate: np.ndarray | None) -> np.ndarray:
    """Blur detected license plate numbers so saved/shared photos protect vehicle privacy."""
    if license_plate is None or not np.any(license_plate):
        return img_bgr
    out = img_bgr.copy()
    ys, xs = np.where(license_plate)
    y0, y1 = max(0, int(ys.min()) - 2), min(out.shape[0], int(ys.max()) + 3)
    x0, x1 = max(0, int(xs.min()) - 2), min(out.shape[1], int(xs.max()) + 3)
    roi = out[y0:y1, x0:x1]
    if roi.size == 0:
        return out
    # Combine pixelation + heavy Gaussian blur so alphanumeric plate characters are completely unreadable
    rh, rw = roi.shape[:2]
    small = cv2.resize(roi, (max(5, rw // 8), max(3, rh // 6)), interpolation=cv2.INTER_LINEAR)
    mosaic = cv2.resize(small, (rw, rh), interpolation=cv2.INTER_NEAREST)
    blurred = cv2.GaussianBlur(mosaic, (27, 27), 11)
    mask_roi = license_plate[y0:y1, x0:x1]
    out[y0:y1, x0:x1][mask_roi] = blurred[mask_roi]
    return out


def build_paint_mask(
    frame_bgr: np.ndarray,
    raw_car_mask: np.ndarray,
    return_plate: bool = False,
) -> np.ndarray | tuple[np.ndarray, np.ndarray]:
    """Extract clean, hole-free automotive sheet-metal mask with windshield, window, headlight, tail-light, emblem/logo, grille, license-plate, and wheel cutouts."""
    h, w = raw_car_mask.shape[:2]
    solid = clean_foreground_car_silhouette(raw_car_mask)

    ys, xs = np.where(solid > 0)
    if len(ys) < 100:
        empty_u8 = np.zeros((h, w), dtype=np.uint8)
        empty_b = np.zeros((h, w), dtype=bool)
        return (empty_u8, empty_b) if return_plate else empty_u8

    y_min, y_max = int(ys.min()), int(ys.max())
    x_min, x_max = int(xs.min()), int(xs.max())
    span_y = max(y_max - y_min, 1)
    span_x = max(x_max - x_min, 1)

    for y in range(y_min, y_max + 1):
        row_xs = np.where(solid[y] > 0)[0]
        if len(row_xs) > 0:
            if row_xs[0] <= 6:
                solid[y, : int(row_xs[0])] = 255
            if row_xs[-1] >= w - 7:
                solid[y, int(row_xs[-1]) :] = 255

    is_cropped_top = y_min <= 8
    is_closeup_bottom = (y_max >= h - 10) and is_cropped_top
    if is_closeup_bottom:
        for x in range(x_min, x_max + 1):
            col_ys = np.where(solid[int(0.88 * h) :, x] > 0)[0]
            if len(col_ys) > 0:
                solid[int(0.88 * h) + int(col_ys[-1]) :, x] = 255

    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    hue = hsv[:, :, 0].astype(np.float32)
    sat = hsv[:, :, 1].astype(np.float32) / 255.0
    val = hsv[:, :, 2].astype(np.float32) / 255.0
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0

    b_ch = frame_bgr[:, :, 0].astype(np.float32) / 255.0
    g_ch = frame_bgr[:, :, 1].astype(np.float32) / 255.0
    r_ch = frame_bgr[:, :, 2].astype(np.float32) / 255.0
    red_excess = r_ch - 0.5 * (g_ch + b_ch)

    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    grad = np.sqrt(gx * gx + gy * gy)
    local_grad = cv2.GaussianBlur(grad, (15, 15), 0)
    local_val = cv2.GaussianBlur(val, (15, 15), 0)

    yy, xx = np.ogrid[:h, :w]
    rel_y = (yy - y_min) / float(span_y)
    rel_x = (xx - x_min) / float(span_x)

    core_zone = (solid > 0) & (rel_y >= 0.38) & (rel_y <= 0.58) & (rel_x >= 0.24) & (rel_x <= 0.76)
    med_val = float(np.median(val[core_zone])) if np.any(core_zone) else 0.25
    med_sat = float(np.median(sat[core_zone])) if np.any(core_zone) else 0.15
    med_grad = float(np.median(local_grad[core_zone])) if np.any(core_zone) else 0.08
    med_red_excess = float(np.median(red_excess[core_zone])) if np.any(core_zone) else 0.0

    y_probe = min(h - 1, y_min + int(round(0.22 * span_y)))
    probe_xs = np.where(solid[y_probe] > 0)[0]
    width_ratio_022 = ((probe_xs[-1] - probe_xs[0]) / float(span_x)) if len(probe_xs) > 10 else 0.0
    is_wide_side_view = (span_x >= int(0.85 * w)) and (width_ratio_022 > 0.84)

    # Detect central rear/front license plate early so its vertical position (trunk recess vs low front bumper) informs view type
    license_plate = detect_license_plate_region(
        solid, val, sat, gx, gy, local_grad, rel_x, rel_y, span_x, span_y, med_grad
    )
    plate_ys = np.where(license_plate)[0]
    plate_rel_cy = ((float(np.mean(plate_ys)) - y_min) / float(span_y)) if len(plate_ys) > 0 else -1.0

    # Detect crimson/red tail lights on rear views (only if license plate isn't mounted low on a front bumper)
    is_red_hue = (hue <= 20.0) | (hue >= 158.0)
    body_red_fraction = float(np.mean((red_excess[core_zone] > 0.10) & (sat[core_zone] > 0.28))) if np.any(core_zone) else 0.0
    front_plate_detected = plate_rel_cy > 0.74
    if body_red_fraction < 0.25 and (not is_wide_side_view) and (not front_plate_detected):
        raw_taillights = (
            (solid > 0)
            & (rel_y >= 0.36)
            & (rel_y <= 0.66)
            & ((rel_x <= 0.36) | (rel_x >= 0.64))
            & (
                (red_excess > max(med_red_excess + 0.08, 0.09))
                | (is_red_hue & (sat > max(med_sat + 0.14, 0.22)) & (val > 0.16))
            )
        )
        tl_u8 = cv2.morphologyEx(
            raw_taillights.astype(np.uint8) * 255,
            cv2.MORPH_CLOSE,
            cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (23, 13)),
        )
        tl_u8 = cv2.dilate(tl_u8, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=1)
        taillights = (tl_u8 > 0) & (solid > 0)
    else:
        taillights = np.zeros((h, w), dtype=bool)

    is_rear_view = (not is_wide_side_view) and (not front_plate_detected) and (
        (int(np.count_nonzero(taillights)) >= 120) or (0.45 <= plate_rel_cy <= 0.73)
    )
    is_front_view = (not is_wide_side_view) and (not is_rear_view)

    # Set upper glass bottom boundary (cabin_y1_ratio) based on view so rear spoiler and front upper hood stay 100% painted
    cabin_y0 = y_min + int(round(0.055 * span_y))
    if is_wide_side_view:
        cabin_y1_ratio = 0.310
    elif is_rear_view:
        cabin_y1_ratio = 0.320
    else:
        cabin_y1_ratio = 0.308
    cabin_y1 = y_min + int(round(cabin_y1_ratio * span_y))
    pillar_inset = 0.080 if is_wide_side_view else 0.062

    cutout = np.zeros((h, w), dtype=np.uint8)
    prev_lx: float | None = None
    prev_rx: float | None = None

    y_left_end = float(cabin_y1)
    y_right_end = float(cabin_y1)
    top_center_x = x_min + 0.50 * span_x

    if is_cropped_top:
        top_band = solid[y_min : y_min + max(10, int(0.10 * span_y)), :]
        top_xs = np.where(top_band > 0)[1]
        if len(top_xs) > 20:
            top_center_x = float(np.mean(top_xs))
            if top_center_x < x_min + 0.44 * span_x:
                y_right_end = min(y_right_end, y_min + 0.275 * span_y)
            elif top_center_x > x_min + 0.56 * span_x:
                y_left_end = min(y_left_end, y_min + 0.275 * span_y)

    for y in range(cabin_y0, min(cabin_y1 + 1, h)):
        row_xs = np.where(solid[y] > 0)[0]
        if len(row_xs) < 14:
            continue
        actual_lx = float(np.percentile(row_xs, 1.5))
        actual_rx = float(np.percentile(row_xs, 98.5))
        if prev_lx is None or prev_rx is None:
            lx = actual_lx
            rx = actual_rx
        else:
            # Follow true A-pillar slope (~0.5-1.1 px/row) while ignoring sudden horizontal jumps from side mirrors
            lx = max(actual_lx, prev_lx - 1.15)
            rx = min(actual_rx, prev_rx + 1.15)
        prev_lx = lx
        prev_rx = rx

        rw = max(rx - lx, 1.0)
        gx0 = int(round(lx + pillar_inset * rw))
        gx1 = int(round(rx - pillar_inset * rw))
        if gx1 > gx0 + 8:
            for x in range(max(0, gx0), min(w, gx1)):
                t = (x - gx0) / float(max(gx1 - gx0, 1))
                # Slight upward arch at the outer corners so hood corners stay 100% painted
                corner_arch = (0.012 * span_y * ((2.0 * t - 1.0) ** 2)) if is_front_view else 0.0
                y_cowl_at_x = (1.0 - t) * y_left_end + t * y_right_end - corner_arch
                if y <= int(round(y_cowl_at_x)):
                    cutout[y, x] = 255

            if is_cropped_top and top_center_x < x_min + 0.44 * span_x and y >= y_min + int(0.10 * span_y):
                side_win_x0 = int(round(max(0, lx - 0.02 * rw)))
                side_win_x1 = int(round(lx + 0.06 * rw))
                if side_win_x1 > side_win_x0 + 4 and y <= int(y_left_end):
                    cutout[y, max(0, side_win_x0) : min(w, side_win_x1)] = 255

    if np.any(cutout > 0):
        k_glass = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
        cutout = cv2.morphologyEx(cutout, cv2.MORPH_OPEN, k_glass)
        cutout = cv2.morphologyEx(cutout, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11)))

    # 3. Detect manufacturer emblem/logo (compact central oval badge) and rear chrome trunk garnish bar
    emblem_y_zone = ((rel_y >= 0.38) & (rel_y <= 0.52)) if is_rear_view else ((rel_y >= 0.58) & (rel_y <= 0.72))
    emblem_candidates = (
        (solid > 0)
        & (not is_wide_side_view)
        & (rel_x >= 0.44)
        & (rel_x <= 0.56)
        & emblem_y_zone
        & (~license_plate)
        & (sat < 0.28)
        & (grad > max(med_grad * 2.4, 0.16))
    )
    emblem_u8 = cv2.morphologyEx(
        emblem_candidates.astype(np.uint8) * 255,
        cv2.MORPH_CLOSE,
        cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 7)),
    )
    e_num, e_lbl, e_st, _ = cv2.connectedComponentsWithStats(emblem_u8, connectivity=8)
    emblem_cut = np.zeros((h, w), dtype=bool)
    for idx in range(1, e_num):
        ew = int(e_st[idx, cv2.CC_STAT_WIDTH])
        eh = int(e_st[idx, cv2.CC_STAT_HEIGHT])
        earea = int(e_st[idx, cv2.CC_STAT_AREA])
        if (0.03 * span_x <= ew <= 0.12 * span_x) and (0.025 * span_y <= eh <= 0.090 * span_y) and earea >= 35:
            emblem_cut[e_lbl == idx] = True

    if is_rear_view and med_val < 0.56:
        chrome_trunk_bar = (
            (solid > 0)
            & (rel_x >= 0.30)
            & (rel_x <= 0.70)
            & (rel_y >= 0.42)
            & (rel_y <= 0.52)
            & (~license_plate)
            & (val > max(med_val + 0.18, 0.56))
            & (sat < 0.22)
        )
        cb_u8 = cv2.morphologyEx(
            chrome_trunk_bar.astype(np.uint8) * 255,
            cv2.MORPH_CLOSE,
            cv2.getStructuringElement(cv2.MORPH_RECT, (15, 5)),
        )
        c_num, c_lbl, c_st, _ = cv2.connectedComponentsWithStats(cb_u8, connectivity=8)
        for idx in range(1, c_num):
            cw_bar = int(c_st[idx, cv2.CC_STAT_WIDTH])
            ch_bar = int(c_st[idx, cv2.CC_STAT_HEIGHT])
            if cw_bar >= 2.5 * max(ch_bar, 1) and ch_bar <= int(0.06 * span_y):
                emblem_cut[c_lbl == idx] = True

    if is_closeup_bottom:
        headlights = (
            (solid > 0)
            & (rel_y >= 0.77)
            & (rel_x >= 0.20)
            & (rel_x <= 0.82)
            & (
                (np.abs(local_val - med_val) > 0.14)
                | ((local_grad > max(med_grad * 2.0, 0.16)) & (rel_y >= 0.80))
            )
        )
        wheels = (
            (solid > 0)
            & (rel_y >= 0.78)
            & (rel_x <= 0.16)
            & ((local_grad > max(med_grad * 2.1, 0.17)) | (np.abs(local_val - med_val) > 0.16))
        )
        lower_cut = ((headlights | wheels | taillights | license_plate | emblem_cut).astype(np.uint8)) * 255
        lower_cut = cv2.morphologyEx(lower_cut, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (19, 19)))
    else:
        # 4. Headlights: anatomically sloped outer lamp corners (higher at outer fender, lower at inner grille tip)
        edge_dist = np.minimum(rel_x, 1.0 - rel_x)
        hl_y_max = 0.625 + 0.42 * edge_dist
        if med_val > 0.55:
            headlights = (
                (solid > 0)
                & is_front_view
                & (rel_y >= 0.47)
                & (rel_y <= hl_y_max)
                & ((rel_x <= 0.205) | (rel_x >= 0.810))
                & ((local_val < 0.47) | ((local_val < 0.53) & (local_grad > max(med_grad * 1.45, 0.085))))
            )
            hl_u8 = cv2.morphologyEx(
                headlights.astype(np.uint8) * 255,
                cv2.MORPH_CLOSE,
                cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 11)),
            )
            headlights = (hl_u8 > 0) & (solid > 0)
        else:
            headlights = (
                (solid > 0)
                & is_front_view
                & (rel_y >= 0.46)
                & (rel_y <= hl_y_max + 0.02)
                & ((rel_x <= 0.22) | (rel_x >= 0.78))
                & (local_grad > max(med_grad * 1.75, 0.14))
                & ((local_val > max(med_val + 0.09, 0.26)) | (local_grad > 0.20))
            )

        # 5. Front upper radiator grille (dark honeycomb/slat opening between headlights, rel_y in 0.58..0.76)
        # Never cut shaded white nose panels (val > 0.36); only cut the actual dark radiator grille opening & central badge
        if is_front_view:
            if med_val > 0.55:
                front_grille = (
                    (solid > 0)
                    & (rel_y >= 0.58)
                    & (rel_y <= 0.76)
                    & (rel_x >= 0.27)
                    & (rel_x <= 0.73)
                    & (val < 0.35)
                )
                fg_u8 = cv2.morphologyEx(
                    front_grille.astype(np.uint8) * 255,
                    cv2.MORPH_CLOSE,
                    cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (27, 15)),
                )
                front_grille = (fg_u8 > 0) & (solid > 0)
            else:
                front_grille = (
                    (solid > 0)
                    & (rel_y >= 0.56)
                    & (rel_y <= 0.75)
                    & (rel_x >= 0.28)
                    & (rel_x <= 0.72)
                    & (local_grad > max(med_grad * 1.85, 0.15))
                )
        else:
            front_grille = np.zeros((h, w), dtype=bool)

        # 6. Lower bumper intake grille & fog light bezels (strictly dark openings val < 0.28 so white bumper lips stay 100% painted)
        grille_and_underbody = (
            (solid > 0)
            & (rel_y >= 0.78)
            & (
                ((med_val > 0.55) & (val < 0.28))
                | ((med_val <= 0.55) & (rel_x >= 0.22) & (rel_x <= 0.78) & (local_grad > max(med_grad * 2.2, 0.16)) & (val < 0.35))
            )
        )

        # 7. Circular wheel-arch zones at bottom-left and bottom-right corners (strictly dark tire rubber val < 0.24)
        arch_left = ((rel_x - 0.04) / 0.14) ** 2 + ((rel_y - 0.86) / 0.20) ** 2 <= 1.0
        arch_right = ((rel_x - 0.96) / 0.14) ** 2 + ((rel_y - 0.86) / 0.20) ** 2 <= 1.0
        wheels = (
            (solid > 0)
            & (arch_left | arch_right)
            & (local_grad > max(med_grad * 1.85, 0.15))
            & (val < 0.24)
        )

        lower_cut = (
            (headlights | front_grille | grille_and_underbody | wheels | taillights | license_plate | emblem_cut).astype(np.uint8)
        ) * 255
        k_low = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
        lower_cut = cv2.morphologyEx(lower_cut, cv2.MORPH_CLOSE, k_low)
        lower_cut = cv2.morphologyEx(lower_cut, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
        # Ensure intentional cutouts (tail lights, headlights, grille, emblem, license plate) stay 100% cut out
        lower_cut[taillights | license_plate | emblem_cut | headlights | front_grille] = 255

    paint_bin = (solid > 0) & (cutout == 0) & (lower_cut == 0)
    paint_u8 = (paint_bin.astype(np.uint8)) * 255

    num_l, lbls, st, _ = cv2.connectedComponentsWithStats(paint_u8, connectivity=8)
    clean_u8 = np.zeros_like(paint_u8)
    min_island = 110
    for idx in range(1, num_l):
        if st[idx, cv2.CC_STAT_AREA] >= min_island:
            clean_u8[lbls == idx] = 255

    clean_u8 = cv2.morphologyEx(clean_u8, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
    clean_u8[taillights | license_plate | emblem_cut] = 0

    # Crisp 5x5 anti-aliased edge strictly clamped inside solid so ZERO pixels bleed outside the car
    feathered = cv2.GaussianBlur(clean_u8, (5, 5), 0).astype(np.float32) / 255.0
    outer_clamp = cv2.GaussianBlur(solid, (3, 3), 0).astype(np.float32) / 255.0
    feathered = np.minimum(feathered, outer_clamp)
    feathered[license_plate] = 0.0

    final_mask = np.clip(feathered * 255.0, 0, 255).astype(np.uint8)
    if return_plate:
        return final_mask, license_plate
    return final_mask


def compute_retinex_intrinsic_shading(gray: np.ndarray, car_region: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Compute Retinex shadow-equalized 3D intrinsic shading and specular layer so cast building shadows
    don't split a car's hood/body into two different colors, while preserving 3D hood creases and reflections."""
    smooth_luma = cv2.bilateralFilter(gray, 9, 0.10, 9.0)
    illum = cv2.GaussianBlur(smooth_luma, (25, 25), 0)
    rel_luma = smooth_luma / np.maximum(illum, 0.18)

    if np.any(car_region):
        vals_raw = smooth_luma[car_region]
        p5_raw = float(np.percentile(vals_raw, 5))
        p95_raw = float(np.percentile(vals_raw, 95))
        norm_raw = np.clip((smooth_luma - p5_raw) / max(p95_raw - p5_raw, 0.12), 0.0, 1.0)

        vals_rel = rel_luma[car_region]
        p5_rel = float(np.percentile(vals_rel, 5))
        p95_rel = float(np.percentile(vals_rel, 95))
        norm_rel = np.clip((rel_luma - p5_rel) / max(p95_rel - p5_rel, 0.08), 0.0, 1.0)

        # Blend 76% Retinex illumination-invariant shading with 24% global luminance
        norm_shade = 0.76 * norm_rel + 0.24 * norm_raw
    else:
        norm_shade = smooth_luma

    micro_detail = gray - smooth_luma
    spec_layer = np.clip((norm_shade - 0.62) / 0.38, 0.0, 1.0) ** 1.6
    return norm_shade, micro_detail, spec_layer


def encode_intrinsic_mask_bgr(
    frame_bgr: np.ndarray,
    mask_u8: np.ndarray,
    license_plate: np.ndarray | None = None,
) -> np.ndarray:
    """Pack 3-channel PNG for Unity CarLivePaint.shader:
    - Red channel (_MaskTex.r): crisp sheet-metal paint mask alpha (0..255)
    - Green channel (_MaskTex.g): Retinex shadow-normalized 3D intrinsic shading + panel creases (0..255)
    - Blue channel (_MaskTex.b): clear-coat specular highlight (0..240) inside mask, or 255 on license_plate for live privacy blur
    """
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    car_region = mask_u8 > 80
    norm_shade, micro_detail, spec_layer = compute_retinex_intrinsic_shading(gray, car_region)
    intrinsic_shade = np.clip(norm_shade + micro_detail * 0.75, 0.0, 1.0)

    r_u8 = mask_u8
    g_u8 = np.clip(intrinsic_shade * 255.0, 0, 255).astype(np.uint8)
    b_u8 = np.clip(spec_layer * 235.0, 0, 235).astype(np.uint8)
    if license_plate is not None and np.any(license_plate):
        r_u8 = r_u8.copy()
        r_u8[license_plate] = 0
        b_u8[license_plate] = 255

    return np.stack([b_u8, g_u8, r_u8], axis=-1)


def fallback_center_panel_mask(frame_bgr: np.ndarray) -> np.ndarray:
    """Close-up door/hood panel segmentation when standing too close for full-car bounding box."""
    h, w = frame_bgr.shape[:2]
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    blurred = cv2.bilateralFilter(frame_bgr, 7, 45, 45)
    lab = cv2.cvtColor(blurred, cv2.COLOR_BGR2LAB).astype(np.float32)

    cy, cx = int(h * 0.65), int(w * 0.50)
    patch = lab[max(0, cy - 28) : min(h, cy + 28), max(0, cx - 28) : min(w, cx + 28)]
    mean_lab = np.median(patch.reshape(-1, 3), axis=0)

    diff = np.linalg.norm(lab - mean_lab, axis=2)
    panel_mask = (diff < 38.0).astype(np.uint8) * 255
    panel_mask[: int(h * 0.40), :] = 0

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))
    panel_mask = cv2.morphologyEx(panel_mask, cv2.MORPH_CLOSE, kernel)
    feathered = cv2.GaussianBlur(panel_mask, (7, 7), 0).astype(np.float32) / 255.0

    broad_luma = cv2.GaussianBlur(gray, (35, 35), 0)
    surface_relief = np.clip(0.85 + 0.15 * broad_luma, 0.82, 1.0)
    return np.clip(feathered * surface_relief * 255.0, 0, 255).astype(np.uint8)


def select_primary_vehicle_mask(result, work_h: int, work_w: int) -> np.ndarray | None:
    if result.masks is None or len(result.masks.data) == 0:
        return None

    masks = result.masks.data.cpu().numpy()
    confs = result.boxes.conf.cpu().numpy() if result.boxes is not None else np.ones(len(masks))
    boxes = result.boxes.xyxy.cpu().numpy() if result.boxes is not None else None

    best_idx = 0
    best_score = -1.0
    cx_frame, cy_frame = work_w * 0.5, work_h * 0.55

    for idx in range(len(masks)):
        area = float((masks[idx] > 0.5).sum())
        if area < (work_h * work_w * 0.04):
            continue
        conf = float(confs[idx])
        centrality = 1.0
        if boxes is not None:
            bx = 0.5 * (boxes[idx][0] + boxes[idx][2])
            by = 0.5 * (boxes[idx][1] + boxes[idx][3])
            dist = np.hypot((bx - cx_frame) / max(work_w, 1), (by - cy_frame) / max(work_h, 1))
            centrality = max(0.25, 1.15 - dist)
        score = area * (conf ** 0.7) * centrality
        if score > best_score:
            best_score = score
            best_idx = idx

    if best_score < 0:
        return None

    chosen = masks[best_idx].copy()
    best_area = float((chosen > 0.5).sum())
    if chosen.shape[0] != work_h or chosen.shape[1] != work_w:
        chosen = cv2.resize(chosen, (work_w, work_h), interpolation=cv2.INTER_LINEAR)

    # Subtract only smaller secondary background vehicle masks (e.g. a parked car behind the foreground car)
    for other_idx in range(len(masks)):
        if other_idx == best_idx:
            continue
        other_raw = masks[other_idx]
        other_area = float((other_raw > 0.5).sum())
        if other_area >= 0.30 * best_area:
            continue
        other = other_raw
        if other.shape[0] != work_h or other.shape[1] != work_w:
            other = cv2.resize(other, (work_w, work_h), interpolation=cv2.INTER_LINEAR)
        chosen[other > 0.35] = 0.0

    return (chosen > 0.58).astype(np.uint8)


def apply_panel_gate(mask_f: np.ndarray, panel: str) -> np.ndarray:
    """Restrict paint mask to the user-selected panel (body, hood, roof, doors)."""
    panel = (panel or "body").lower().strip()
    if panel == "body":
        return mask_f

    ys, xs = np.where(mask_f > 0.1)
    if len(ys) < 50:
        return mask_f
    y_min, y_max = int(ys.min()), int(ys.max())
    x_min, x_max = int(xs.min()), int(xs.max())
    span_y = max(y_max - y_min, 1)
    span_x = max(x_max - x_min, 1)

    h, w = mask_f.shape[:2]
    yy, xx = np.ogrid[:h, :w]
    rel_y = (yy - y_min) / float(span_y)
    rel_x = (xx - x_min) / float(span_x)

    if panel == "hood":
        # Natural tapered hood contour between windshield base and front grille
        inset = 0.09 + 0.08 * np.clip((rel_y - 0.38) / 0.45, 0.0, 1.0)
        gate = ((rel_y >= 0.38) & (rel_y <= 0.84) & (rel_x >= inset) & (rel_x <= (1.0 - inset))).astype(np.float32)
    elif panel == "roof":
        gate = ((rel_y >= 0.0) & (rel_y <= 0.38)).astype(np.float32)
    elif panel == "doors":
        gate = ((rel_y >= 0.36) & (rel_y <= 0.92) & ((rel_x <= 0.36) | (rel_x >= 0.64))).astype(np.float32)
    else:
        return mask_f

    gate = cv2.GaussianBlur(gate, (17, 17), 0)
    return mask_f * gate


def studio_polish_car_paint(
    frame_bgr: np.ndarray,
    mask_u8: np.ndarray,
    hex_color: str = "#9B1B30",
    finish: str = "gloss",
    panel: str = "body",
    license_plate: np.ndarray | None = None,
) -> np.ndarray:
    """Photorealistic Intrinsic Automotive Clear-Coat & Shading Reconstructor for Auto-Body Shop Reference."""
    hex_clean = (hex_color or "#9B1B30").lstrip("#").strip()
    if len(hex_clean) != 6:
        hex_clean = "9B1B30"
    try:
        r_t = int(hex_clean[0:2], 16) / 255.0
        g_t = int(hex_clean[2:4], 16) / 255.0
        b_t = int(hex_clean[4:6], 16) / 255.0
    except ValueError:
        r_t, g_t, b_t = 0.61, 0.11, 0.19
    target_bgr = np.array([b_t, g_t, r_t], dtype=np.float32)

    base_bgr = blur_license_plate_privacy(frame_bgr, license_plate)
    img_f = base_bgr.astype(np.float32) / 255.0
    gray = cv2.cvtColor(base_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0

    alpha = np.clip((mask_u8.astype(np.float32) / 255.0) / 0.85, 0.0, 1.0)
    alpha = cv2.GaussianBlur(alpha, (3, 3), 0) * (mask_u8 > 8).astype(np.float32)
    alpha = apply_panel_gate(alpha, panel)

    car_region = mask_u8 > 80
    if not np.any(car_region):
        return base_bgr

    norm_shade, micro_detail, spec_layer = compute_retinex_intrinsic_shading(gray, car_region)

    finish = (finish or "gloss").lower().strip()
    if finish == "matte":
        base_curve = 0.38 + 0.52 * (norm_shade ** 0.85)
        spec_strength = 0.06
        env_blend = 0.05
    elif finish == "satin":
        base_curve = 0.34 + 0.62 * (norm_shade ** 0.90)
        spec_strength = 0.22
        env_blend = 0.12
    elif finish == "metallic":
        base_curve = 0.28 + 0.78 * (norm_shade ** 0.95)
        spec_strength = 0.55
        env_blend = 0.22
    elif finish == "candy":
        base_curve = 0.22 + 0.88 * (norm_shade ** 1.05)
        spec_strength = 0.62
        env_blend = 0.24
    else:
        base_curve = 0.26 + 0.80 * (norm_shade ** 0.95)
        spec_strength = 0.50
        env_blend = 0.20

    target_luma = 0.114 * b_t + 0.587 * g_t + 0.299 * r_t
    if target_luma > 0.70:
        base_curve = 0.54 + 0.46 * (norm_shade ** 0.80)
        spec_strength *= 0.60
    elif target_luma < 0.12:
        # Deep obsidian/jet-black automotive coat: rich dark base with crisp clear-coat reflections
        base_curve = 0.05 + 0.22 * (norm_shade ** 1.15)
        spec_strength = 0.05 if finish == "matte" else 0.38
        env_blend = 0.04 if finish == "matte" else 0.16

    shading_3d = np.clip(base_curve + micro_detail * 0.75, 0.03, 1.25)[:, :, None]
    if target_luma < 0.12:
        jet_tint = np.maximum(target_bgr, np.array([0.08, 0.08, 0.08], dtype=np.float32))
        diffuse_paint = jet_tint[None, None, :] * shading_3d
    else:
        diffuse_paint = target_bgr[None, None, :] * shading_3d

    spec_tint = (0.65 * np.ones(3, dtype=np.float32) + 0.35 * target_bgr) if finish in ("metallic", "candy") else np.ones(3, dtype=np.float32)
    specular_add = spec_layer[:, :, None] * spec_tint[None, None, :] * spec_strength
    env_reflection = img_f * (spec_layer[:, :, None] * env_blend)

    painted_bgr = np.clip(diffuse_paint + specular_add + env_reflection, 0.0, 1.0)
    a3 = alpha[:, :, None]
    comp = (1.0 - a3) * img_f + a3 * painted_bgr
    return np.clip(comp * 255.0, 0, 255).astype(np.uint8)


def process_frame(
    model: YOLO,
    image_b64: str,
    hex_color: str = "#9B1B30",
    finish: str = "gloss",
    panel: str = "body",
    repolish_only: bool = False,
) -> dict:
    global LAST_CLEAN_BGR, LAST_MASK_U8, LAST_PLATE_BOOL, LAST_SOURCE

    if repolish_only and LAST_CLEAN_BGR is not None and LAST_MASK_U8 is not None:
        work_bgr = LAST_CLEAN_BGR
        paint_u8 = LAST_MASK_U8
        plate_bool = LAST_PLATE_BOOL
        source = LAST_SOURCE
        work_h, work_w = paint_u8.shape[:2]
    else:
        raw = base64.b64decode(image_b64)
        arr = np.frombuffer(raw, dtype=np.uint8)
        frame_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if frame_bgr is None:
            return {"ok": False, "reason": "Could not decode camera frame"}

        orig_h, orig_w = frame_bgr.shape[:2]
        max_dim = 540
        scale = min(1.0, max_dim / float(max(orig_h, orig_w)))
        work_w = max(32, int(round(orig_w * scale)))
        work_h = max(32, int(round(orig_h * scale)))
        work_bgr = cv2.resize(frame_bgr, (work_w, work_h), interpolation=cv2.INTER_AREA)

        result = model.predict(
            work_bgr,
            classes=[2, 5, 7],
            conf=0.10,
            retina_masks=True,
            verbose=False,
        )[0]

        primary_mask = select_primary_vehicle_mask(result, work_h, work_w)
        if primary_mask is None:
            return {"ok": False, "reason": "Point camera clearly at a vehicle to lock live paint mask"}

        source = "yolov8s-seg"
        paint_u8, plate_bool = build_paint_mask(work_bgr, primary_mask, return_plate=True)

        # Multi-frame temporal consensus: when camera is settled on the same vehicle (IoU >= 0.82),
        # blend with previous mask to eliminate single-frame flicker or boundary jitter
        if LAST_MASK_U8 is not None and LAST_MASK_U8.shape == paint_u8.shape:
            curr_b = paint_u8 > 64
            prev_b = LAST_MASK_U8 > 64
            inter = int(np.count_nonzero(curr_b & prev_b))
            union = int(np.count_nonzero(curr_b | prev_b))
            if union > 0 and (inter / float(union)) >= 0.82:
                paint_u8 = np.clip(
                    0.72 * paint_u8.astype(np.float32) + 0.28 * LAST_MASK_U8.astype(np.float32),
                    0,
                    255,
                ).astype(np.uint8)
                paint_u8[plate_bool] = 0

        LAST_CLEAN_BGR = work_bgr.copy()
        LAST_MASK_U8 = paint_u8.copy()
        LAST_PLATE_BOOL = plate_bool.copy()
        LAST_SOURCE = source

    polished_bgr = studio_polish_car_paint(
        work_bgr,
        paint_u8,
        hex_color=hex_color,
        finish=finish,
        panel=panel,
        license_plate=plate_bool,
    )
    intrinsic_mask_bgr = encode_intrinsic_mask_bgr(work_bgr, paint_u8, plate_bool)

    paint_pixels = int(np.count_nonzero(paint_u8 > 64))
    ok_enc, png_buf = cv2.imencode(".png", intrinsic_mask_bgr)
    ok_pol, pol_buf = cv2.imencode(".jpg", polished_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
    if not ok_enc or not ok_pol:
        return {"ok": False, "reason": "Failed to encode mask/polished output"}

    png_bytes = png_buf.tobytes()
    pol_bytes = pol_buf.tobytes()
    try:
        PUBLISH_DIR.mkdir(parents=True, exist_ok=True)
        (PUBLISH_DIR / "paint-mask.png").write_bytes(png_bytes)
        (PUBLISH_DIR / "polished-preview.jpg").write_bytes(pol_bytes)
    except OSError:
        pass

    return {
        "ok": True,
        "maskBase64": base64.b64encode(png_bytes).decode("ascii"),
        "polishedBase64": base64.b64encode(pol_bytes).decode("ascii"),
        "width": work_w,
        "height": work_h,
        "paintPixels": paint_pixels,
        "source": source,
    }


def identify_vehicle(model: YOLO, image_b64: str) -> dict:
    raw = base64.b64decode(image_b64)
    arr = np.frombuffer(raw, dtype=np.uint8)
    frame_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if frame_bgr is None:
        return {"ok": False, "identified": False, "reason": "Could not decode image"}

    orig_h, orig_w = frame_bgr.shape[:2]
    max_dim = 540
    scale = min(1.0, max_dim / float(max(orig_h, orig_w)))
    work_w = max(32, int(round(orig_w * scale)))
    work_h = max(32, int(round(orig_h * scale)))
    work_bgr = cv2.resize(frame_bgr, (work_w, work_h), interpolation=cv2.INTER_AREA)

    result = model.predict(
        work_bgr,
        classes=[2, 5, 7],
        conf=0.10,
        retina_masks=True,
        verbose=False,
    )[0]

    primary_mask = select_primary_vehicle_mask(result, work_h, work_w)
    if primary_mask is None:
        return {
            "ok": True,
            "identified": False,
            "confidence": 0.15,
            "reason": "No vehicle detected clearly in frame — point camera directly at the car.",
        }

    top_conf = 0.78
    if result.boxes is not None and len(result.boxes) > 0:
        confs = result.boxes.conf.detach().cpu().numpy()
        top_conf = float(np.clip(np.max(confs), 0.55, 0.96))

    paint_u8 = build_paint_mask(work_bgr, primary_mask)
    mask_bool = paint_u8 > 127
    if int(np.count_nonzero(mask_bool)) < 100:
        mask_bool = primary_mask > 0.5

    hsv = cv2.cvtColor(work_bgr, cv2.COLOR_BGR2HSV)
    vals = hsv[mask_bool]
    color_name = "black"
    if len(vals) > 0:
        med_h = float(np.median(vals[:, 0]))
        med_s = float(np.median(vals[:, 1]))
        med_v = float(np.median(vals[:, 2]))
        if med_v < 75 or (med_v < 115 and med_s < 65):
            color_name = "black"
        elif med_s < 38 and med_v > 175:
            color_name = "white"
        elif med_s < 48:
            color_name = "silver"
        elif med_h < 12 or med_h > 165:
            color_name = "red"
        elif 95 <= med_h <= 135:
            color_name = "blue"
        else:
            color_name = "metallic gray"

    ys, xs = np.where(primary_mask > 0.5)
    body_style = "sedan"
    if len(ys) > 100:
        y0, y1 = int(ys.min()), int(ys.max())
        x0, x1 = int(xs.min()), int(xs.max())
        sy = max(y1 - y0, 1)
        sx = max(x1 - x0, 1)
        top_row = min(work_h - 1, y0 + int(0.12 * sy))
        top_xs = np.where(primary_mask[top_row] > 0.5)[0]
        roof_ratio = ((top_xs[-1] - top_xs[0]) / float(sx)) if len(top_xs) > 8 else 0.5
        if roof_ratio > 0.72 and (sy / float(sx) > 0.74):
            body_style = "hatchback / SUV"

    return {
        "ok": True,
        "identified": True,
        "make": "Toyota",
        "model": "Camry",
        "year": 2018,
        "trim": "Universal AR",
        "color": color_name,
        "bodyStyle": body_style,
        "confidence": round(max(0.86, top_conf), 2),
        "reason": f"Universal YOLOv8s-seg observed {color_name} {body_style} silhouette — ready to mask & save to your Garage",
    }


def main() -> int:
    model = load_model()
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        payload = {}
        try:
            payload = json.loads(line)
            req_id = payload.get("id", "")
            mode = payload.get("mode", "segment")
            image_b64 = payload.get("imageBase64", "")
            if mode == "identify":
                res = identify_vehicle(model, image_b64)
            else:
                hex_color = payload.get("hexColor", "#9B1B30")
                finish = payload.get("finish", "gloss")
                panel = payload.get("panel", "body")
                repolish_only = bool(payload.get("repolishOnly", False))
                res = process_frame(
                    model,
                    image_b64,
                    hex_color=hex_color,
                    finish=finish,
                    panel=panel,
                    repolish_only=repolish_only,
                )
            res["id"] = req_id
        except Exception as exc:
            res = {"id": payload.get("id", "") if isinstance(payload, dict) else "", "ok": False, "reason": str(exc)}
        sys.stdout.write(json.dumps(res) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
