# Live CV and supervised improvement workflow

## What is implemented

The app performs real neural-network inference using pretrained vehicle-instance
and 33-part segmentation networks. `CarSegMaskGuarded.onnx` adds single-instance
selection, spatial mask constraints and an exterior-evidence guard. It is now
preferred by Unity. This is a graph/postprocessing refinement of pretrained models,
not a claim that their weights were retrained on every test vehicle.

Unsupported or uncertain views abstain. In particular, tight glass/roof-only crops
may need a wider view containing a wheel or lamp. Empty masks do not prove that
there is no vehicle, so the UI describes an unreliable exterior mask.

The live preview still uses approximate camera-pose compensation, not a recovered
3D surface or a fully validated optical-flow tracker. Physical phone validation
remains necessary for motion, thermal behaviour, timing and shader output.

## Local active learning

The school icon in the customizer controls local collection:

- Tap: enable/disable collecting hard examples (off by default).
- Hold: save the last analysed input and prediction for manual review.
- Samples stay in `Application.persistentDataPath/learning_queue`.
- Automatic collection is throttled to one sample per 15 seconds and capped at
  100 sample directories. It collects empty/unsupported and very large masks.
- A prediction is explicitly marked **not ground truth**. No automatic uploads,
  on-phone training, model downloads or hot-swapping occur.

Transfer that directory to a workstation for review. Reassign scene groups when
several sessions show the same vehicle/view; do not split adjacent frames between
training and validation.

## Annotation contract

`image.png` is the original analysed RGB frame; `prediction.png` is only a hint.
Create a same-size, single-channel `labels.png`:

| Value | Meaning |
|---|---|
| 0 | Background |
| 1 | Paintable exterior body |
| 2 | Protected part or unsupported interior |
| 255 | Unreviewed/ignored pixel |

Review the actual image, not just the predicted mask. Include dark, bright,
reflective and damaged cars, close-ups, multiple cars, interiors, walls and roads.
Record attribution/usage permission for externally sourced samples.

## Executable commands

From the repository root:

```powershell
python ml/active_learning.py --queue scratch/learning_queue stats
python ml/active_learning.py --queue scratch/learning_queue collect --image SOURCE.png --scene car-session-a --reason missed-panel --model CarSegMaskGuarded-v1
python ml/active_learning.py --queue scratch/learning_queue approve --sample SAMPLE_ID --mask CORRECTED_LABELS.png --reviewer REVIEWER_NAME --scene car-session-a --split train
python ml/active_learning.py --queue scratch/learning_queue train --out scratch/candidate-v2 --epochs 20 --baseline "My project/Assets/Resources/CarSegMaskGuarded.onnx"
```

The real training implementation optimizes a small three-class semantic model
using cross-entropy and AdamW, evaluates held-out labelled pixels against the
baseline, and exports a single-body-mask ONNX candidate. It requires at least two
training scenes and two separate validation scenes. It rejects split leakage and
changed annotations. Export alone never authorizes release.

This student is an experimental architecture, not a substitute for the current
pretrained networks without evidence. Full annotations, representative data,
boundary/instance checks and device profiling are required before promotion.
Keep the previous model and compare body IoU and protected-part spill, not coverage
alone. Sparse-label metrics must not be described as whole-image accuracy.

## Current training experiment

Six images received explicit **assistant-reviewed sparse interior annotations**;
they are not human-certified full masks. Three scenes were used for student
training and three different scenes for development validation. The small student
failed the baseline comparison and was **not activated**. Artifacts:
`scratch/learning-candidate/evaluation.json` and `scratch/learning_queue`.

This demonstrates an actual collect/review/train/evaluate/reject cycle. It does not
demonstrate that collecting more frames automatically improves the product. These
development scenes were previously inspected during engineering; they are not an
independent benchmark for the whole project.

## Reproduction and device gate

```powershell
python ml/export_guarded_mask.py
python ml/render_diversity_video.py --model scratch/guarded-live/CarSegMaskGuarded.onnx --out scratch/guarded-live
python -m unittest discover -s ml -p test_active_learning.py -v
python -m unittest discover -s ml -p test_mask_quality.py -v
```

`ValidateGuardedModel.Run` is an Editor-only batch entry point executing exact
binary tensor fixtures in Unity CPU. It compares the actual Unity runtime with
ONNX Runtime rather than relying on successful model import alone.

Before phone release: re-export Unity; deploy the updated Python worker; test the
Android graphics backend, moving camera, loss/reacquisition, all supported framing
modes and cold/warm inference. The old resource model is retained for rollback;
prune unused baseline resources for a release build once rollback is managed
outside the APK. Do not install the rejected student candidate.
