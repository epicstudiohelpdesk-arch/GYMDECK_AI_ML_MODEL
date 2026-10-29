import torch
import torch.nn as nn
from torchvision import transforms, models
from PIL import Image


DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

_transform = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
])


def load_model(path: str):
    ckpt = torch.load(path, map_location=DEVICE)
    classes = ckpt["classes"]

    model = models.efficientnet_b0(weights=None)
    model.classifier = nn.Sequential(
        nn.Dropout(0.4),
        nn.Linear(model.classifier[1].in_features, len(classes)),
    )
    model.load_state_dict(ckpt["model_state_dict"])
    model.to(DEVICE).eval()
    return model, classes


CONFIDENCE_THRESHOLD = 50.0


def predict(image: Image.Image, model: nn.Module, classes: list) -> dict:
    tensor = _transform(image.convert("RGB")).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        probs = torch.softmax(model(tensor), dim=1)[0]
    idx = probs.argmax().item()
    confidence = round(probs[idx].item() * 100, 2)
    if confidence < CONFIDENCE_THRESHOLD:
        return {"label": "unknown", "confidence": confidence}
    return {"label": classes[idx], "confidence": confidence}
