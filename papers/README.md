# 📚 Academic Research & Publication Suite

This directory contains the complete academic publication package for the **AR Car Customizer & Smart Workshop Assistant** project. It divides the technical innovations into three distinct, non-overlapping journal manuscripts targeting top-tier IEEE, Elsevier, and Springer venues.

---

## 📑 The Three-Paper Portfolio Overview

| Paper | Domain | Working Title | Target Venues | Primary Codebase Anchors |
|---|---|---|---|---|
| **Paper 1** | Computer Graphics & Edge AI | *Real-Time On-Device Vehicle Sheet-Metal Segmentation and Dichromatic Paint Relighting for Mobile Augmented Reality* | *IEEE TVCG*, *Computers & Graphics (Elsevier)*, *Visual Informatics* | `ml/export_sentis_mask.py`<br>`Assets/Shaders/CarLivePaint.shader` |
| **Paper 2** | Computer Vision & Industrial AR | *Automated Vehicle Damage Assessment, Panel Localization, and Spatial 3D AR Anchoring for Smart Automotive Workshops* | *Computers in Industry*, *EAAI*, *Expert Systems with Applications* | `ml/damage_detector.py`<br>`Assets/Scripts/SpatialDamageAnchorManager.cs` |
| **Paper 3** | Software Systems & HCI | *A Unified Cross-Platform Architecture for Collaborative AR Vehicle Customization and Workshop Lifecycle Management* | *SoftwareX*, *J. Systems & Software*, *IEEE Access*, *IJHCS* | `client/`, `backend/`, `My project/`<br>Bridge & GraphQL Architecture |

---

## 📂 Directory Structure

```
papers/
├── README.md                                # Master guide (this file)
├── paper1_graphics_edge_ai/
│   ├── manuscript.tex                       # Complete LaTeX article manuscript
│   ├── references.bib                       # BibTeX citation library
│   └── benchmark_edge_ai.py                 # Automated benchmark script (latency, FPS, IoU)
├── paper2_vision_spatial_inspection/
│   ├── manuscript.tex                       # Complete LaTeX article manuscript
│   ├── references.bib                       # BibTeX citation library
│   └── benchmark_damage_pipeline.py         # Automated evaluation script (mAP, confusion matrix, MAE)
└── paper3_cross_platform_systems_hci/
    ├── manuscript.tex                       # Complete LaTeX article manuscript
    ├── references.bib                       # BibTeX citation library
    └── user_study_protocol.py               # Empirical evaluation script (SUS & NASA-TLX analyzer)
```

---

## 🚀 How to Run the Quantitative Benchmark Scripts

To generate the exact numerical results, tables, and statistics required by journal reviewers, run the Python scripts in each paper directory:

```bash
# 1. Benchmark Edge AI segmentation & shader compute profile:
python papers/paper1_graphics_edge_ai/benchmark_edge_ai.py

# 2. Benchmark damage detector, panel localization & cost estimation:
python papers/paper2_vision_spatial_inspection/benchmark_damage_pipeline.py

# 3. Analyze HCI user study metrics (SUS, NASA-TLX, and timing):
python papers/paper3_cross_platform_systems_hci/user_study_protocol.py
```

Each script outputs both terminal summaries and ready-to-paste **LaTeX tables (`table_*.tex`)** directly into the manuscripts!

---

## 🛠️ How to Compile the LaTeX Manuscripts

Each paper is formatted with standard `article` and standard mathematical packages (`amsmath`, `booktabs`, `graphicx`, `hyperref`, `algorithm2e`).

Compile with `pdflatex` and `bibtex` (or Overleaf):
```bash
cd papers/paper1_graphics_edge_ai
pdflatex manuscript.tex
bibtex manuscript
pdflatex manuscript.tex
pdflatex manuscript.tex
```
*(Repeat similarly for paper 2 and paper 3)*.
