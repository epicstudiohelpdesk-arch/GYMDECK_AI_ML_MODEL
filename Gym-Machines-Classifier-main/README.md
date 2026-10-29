# Gym Machine Classifier & Video Tutorial Provider

A deep-learning service that identifies gym machines and free weights from a single photo, then returns a matching video tutorial on how to use the equipment.

Upload one image → get back the predicted equipment name, the model's confidence, and a link to a curated tutorial video.

---

## Features

- Classifies **16 categories** of gym equipment from a single image.
- Built on a fine-tuned **EfficientNet-B0** CNN using transfer learning.
- Returns a **confidence score**; predictions below 40% are reported as `unknown` instead of a wrong guess.
- Fetches a matching tutorial URL from a local **SQLite** database.
- Served through a **FastAPI** application and packaged as a **Docker** container — no external database required.

---

## Tech Stack

| Component        | Technology            |
| ---------------- | --------------------- |
| ML framework     | PyTorch + torchvision |
| Model            | EfficientNet-B0       |
| API              | FastAPI               |
| Server           | Uvicorn (ASGI)        |
| Image processing | Pillow (PIL)          |
| Database         | SQLite                |
| Deployment       | Docker                |

---

## Model

**Architecture.** EfficientNet-B0 backbone (pre-trained on ImageNet) with the original head replaced by a custom classifier:

```
Dropout(p=0.4) → Linear(1280 → 16)
```

| Component               | Parameters | Notes                          |
| ----------------------- | ---------- | ------------------------------ |
| EfficientNet-B0 backbone| 4,007,548  | Pre-trained; frozen in Phase 1 |
| Custom classifier head  | 20,496     | Trained from scratch           |
| **Total**               | **4,028,044** | Final checkpoint: 15.6 MB   |

**Why EfficientNet-B0.** Best accuracy-to-size ratio for the task — near-ResNet-50 accuracy (~77% on ImageNet) with only ~4M parameters, runs on CPU, and the exported model is small enough to bundle inside the container.

**Training.** Two-phase fine-tuning:

| Phase | Epochs | Layers trained     | Learning rate | Backbone   |
| ----- | ------ | ------------------ | ------------- | ---------- |
| 1     | 1–10   | Classifier head    | 1e-3          | Frozen     |
| 2     | 11–30  | All layers         | 1e-4          | Unfrozen   |

- **Optimizer:** Adam
- **Loss:** Weighted Cross-Entropy (with label smoothing 0.1)
- **Best checkpoint** saved on highest validation accuracy.

**Reducing overfitting.** Transfer learning (frozen backbone), heavy data augmentation, `Dropout(0.4)`, label smoothing, and early best-checkpoint selection.

---

## Dataset

16 classes, **~1,082 images** total, split **80% train / 20% validation** (stratified, fixed seed).

<details>
<summary>Class list</summary>

`Ab_Crunch_Machine`, `Assisted_Pullup_Dip`, `Back_Extension`, `Cable_Crossover`, `Lat_Pulldown`, `Leg_Extension`, `Lying_Leg_Curl`, `Pec_Deck`, `Seated_Cable_Row`, `Shoulder_Press`, `Sitting_Calf_Raise`, `Barbell`, `Dumbbell`, `Kettlebell`, `Leg_Press`, `Roller_Abs`
</details>

**Class imbalance** (33–100 images per class) is handled with a `WeightedRandomSampler` plus a weighted loss, so every class gets balanced exposure during training.

**Augmentation** (training only): resize + random crop (256 → 224), horizontal flip, color jitter, random rotation (±20°), affine translation, random grayscale (p=0.05), random erasing (p=0.2), and ImageNet normalization.

---

## Results

| Metric                    | Value          |
| ------------------------- | -------------- |
| Best validation accuracy  | **83.87%**     |
| Macro-average F1          | **0.84**       |
| Total epochs              | 30             |
| Checkpoint size           | 15.6 MB        |

Per-class F1 ranges from 0.56 (`Lying_Leg_Curl`, visually similar to `Leg_Extension`) to 1.00 (`Back_Extension`, `Kettlebell`). Full per-class table is in [`docs/`](docs/).

---

## Getting Started

### Run with Docker (recommended)

```bash
docker build -t gym-classifier .
docker run -p 8000:8000 gym-classifier
```

Then open `http://localhost:8000`.

### Run locally

```bash
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000
```

---

## API

| Method | Route      | Description                                            |
| ------ | ---------- | ----------------------------------------------------- |
| GET    | `/`        | Web UI (self-contained HTML page)                     |
| GET    | `/health`  | Server status and number of loaded classes            |
| GET    | `/classes` | Full list of the 16 class names                       |
| POST   | `/predict` | Accepts an image upload; returns label, confidence, and video URL |

### Example

```bash
curl -X POST "http://localhost:8000/predict" \
     -F "file=@lat_pulldown.jpg"
```

```json
{
  "label": "Lat_Pulldown",
  "confidence": 0.91,
  "video_url": "https://youtube.com/watch?v=..."
}
```

If confidence is below 0.40, `label` is `"unknown"` and `video_url` is `null`.

---

## Project Structure

```
.
├── app.py                # FastAPI application (routes + web UI)
├── gym_classifier.py     # Model loading and inference
├── database.py           # SQLite tutorial-URL store (init + lookup)
├── gym_classifier.pth    # Trained model checkpoint (15.6 MB)
├── requirements.txt
├── Dockerfile
└── docs/                 # Documentation, results, confusion matrix
```

---

## How It Works

```
Image upload → preprocess (resize 224×224, normalize)
             → EfficientNet-B0 forward pass
             → softmax confidence check (threshold 0.40)
             → SQLite lookup for tutorial URL
             → JSON response
```

---

## Team

Part of the **Bonyaan – AI Lifestyle Assistant** graduation project.
Faculty of Engineering, Mansoura University · Computer and Control Systems Engineering · 2024/2025.

## License

This project is for academic purposes as part of a graduation project.
