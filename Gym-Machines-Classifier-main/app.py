import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from PIL import Image
import io

from gym_classifier import load_model, predict
from database import init_db, get_video_url

MODEL_PATH = os.environ.get(
    "MODEL_PATH",
    os.path.join(os.path.dirname(__file__), "gym_classifier.pth"),
)

model = None
classes = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, classes
    if not os.path.exists(MODEL_PATH):
        raise RuntimeError(f"Model file not found: {MODEL_PATH}")
    model, classes = load_model(MODEL_PATH)
    print(f"Model loaded — {len(classes)} classes")
    init_db()
    print("Database ready")
    yield
    model = None
    classes = None


app = FastAPI(
    title="Gym Machine Classifier",
    description="Upload a gym equipment image and get the top predicted classes.",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/", response_class=HTMLResponse)
def index():
    return """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Gym Machine Classifier</title>
  <style>
    body { font-family: sans-serif; max-width: 520px; margin: 60px auto; padding: 0 16px; }
    h1   { font-size: 1.5rem; margin-bottom: 4px; }
    p    { color: #555; margin-bottom: 24px; }
    input[type=file] { display: block; margin-bottom: 12px; }
    button { padding: 8px 20px; background: #2563eb; color: #fff; border: none; border-radius: 6px; cursor: pointer; }
    button:hover { background: #1d4ed8; }
    #preview { max-width: 100%; margin-top: 16px; border-radius: 8px; display: none; }
    #result  { margin-top: 20px; }
    .card    { background: #f1f5f9; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; display: flex; justify-content: space-between; }
    .label   { font-weight: 600; }
    .conf    { color: #2563eb; }
  </style>
</head>
<body>
  <h1>Gym Machine Classifier</h1>
  <p>Upload a gym equipment photo to identify it.</p>
  <input type="file" id="fileInput" accept="image/*">
  <img id="preview">
  <button onclick="classify()">Classify</button>
  <div id="result"></div>

  <script>
    document.getElementById('fileInput').addEventListener('change', function() {
      const file = this.files[0];
      if (!file) return;
      const preview = document.getElementById('preview');
      preview.src = URL.createObjectURL(file);
      preview.style.display = 'block';
      document.getElementById('result').innerHTML = '';
    });

    async function classify() {
      const file = document.getElementById('fileInput').files[0];
      if (!file) { alert('Please select an image first.'); return; }
      const form = new FormData();
      form.append('file', file);
      const res = await fetch('/predict', { method: 'POST', body: form });
      const data = await res.json();
      if (!res.ok) { document.getElementById('result').innerHTML = '<p style="color:red">' + (data.detail || 'Error') + '</p>'; return; }
      const link = data.video_url
        ? '<a href="' + data.video_url + '" target="_blank">Watch tutorial</a>'
        : '<span style="color:#888">No video available</span>';
      document.getElementById('result').innerHTML =
        '<div class="card"><span class="label">' + data.label + '</span><span class="conf">' + data.confidence + '%</span></div>' +
        '<div style="margin-top:8px">' + link + '</div>';
    }
  </script>
</body>
</html>
"""


@app.get("/health")
def health():
    return {"status": "ok", "classes_loaded": len(classes) if classes else 0}


@app.get("/classes")
def get_classes():
    return {"classes": classes}


@app.post("/predict")
async def predict_image(file: UploadFile = File(...)):
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Uploaded file must be an image.")

    contents = await file.read()
    try:
        image = Image.open(io.BytesIO(contents))
    except Exception:
        raise HTTPException(status_code=400, detail="Could not decode image.")

    result = predict(image, model, classes)
    result["video_url"] = get_video_url(result["label"]) if result["label"] != "unknown" else None
    return JSONResponse(result)
