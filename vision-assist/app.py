"""
Vision Assist — base service for blind users.
Ask if a named object is visible through the camera; get a text answer.

Detection strategy:
  - COCO-80 objects  →  YOLOv8n        (fast, offline)
  - Everything else  →  Grounding DINO  (open-vocabulary, any object in text)

Usage:
    python app.py                  # interactive loop, shows annotated window
    python app.py --no-window      # text-only (recommended for assistive use)
    python app.py --serve          # REST API server on port 5000
    python app.py --serve --port 8080  # REST API on a custom port
"""

import base64
import io
import sys
import time

import cv2
import torch
from PIL import Image
from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor
from ultralytics import YOLO

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
GDINO_MODEL_ID = "IDEA-Research/grounding-dino-tiny"
YOLO_CONF_THRESHOLD = 0.40   # minimum confidence to report a YOLO detection
GDINO_BOX_THRESHOLD = 0.35   # minimum box confidence for Grounding DINO
GDINO_TEXT_THRESHOLD = 0.25  # minimum text score for Grounding DINO
REANNOUNCE_EVERY = 5         # re-print status every N seconds even if unchanged

# ---------------------------------------------------------------------------
# Aliases — natural user phrases → COCO class name
# ---------------------------------------------------------------------------
ALIASES: dict[str, str] = {
    # Phone
    "phone":            "cell phone",
    "mobile":           "cell phone",
    "mobile phone":     "cell phone",
    "cellphone":        "cell phone",
    "smartphone":       "cell phone",
    "iphone":           "cell phone",
    "android":          "cell phone",
    # Computer / screen
    "computer":         "laptop",
    "notebook":         "laptop",
    "macbook":          "laptop",
    "monitor":          "tv",
    "television":       "tv",
    "screen":           "tv",
    # Furniture
    "sofa":             "couch",
    "settee":           "couch",
    "table":            "dining table",
    # Food / drink
    "mug":              "cup",
    "coffee cup":       "cup",
    "tea cup":          "cup",
    "glass":            "wine glass",
    "drinking glass":   "wine glass",
    "water bottle":     "bottle",
    "juice bottle":     "bottle",
    # Kitchen
    "fridge":           "refrigerator",
    "freezer":          "refrigerator",
    # Plants / misc
    "plant":            "potted plant",
    "flower pot":       "potted plant",
    "teddy":            "teddy bear",
    "stuffed animal":   "teddy bear",
    "hair dryer":       "hair drier",
    "dryer":            "hair drier",
    # Bags
    "bag":              "backpack",
    "rucksack":         "backpack",
    "school bag":       "backpack",
    "purse":            "handbag",
    "hand bag":         "handbag",
    "luggage":          "suitcase",
    "travel bag":       "suitcase",
    # Vehicles
    "bike":             "bicycle",
    "motorbike":        "motorcycle",
    "aeroplane":        "airplane",
    "plane":            "airplane",
    # People
    "people":           "person",
    "human":            "person",
    "man":              "person",
    "woman":            "person",
    "child":            "person",
    # Animals
    "kitty":            "cat",
    "kitten":           "cat",
    "puppy":            "dog",
    "pup":              "dog",
}

COCO_CLASSES: list[str] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
    "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
    "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
    "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
    "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
    "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv",
    "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush",
]


# ---------------------------------------------------------------------------
# Model loading
# ---------------------------------------------------------------------------
def get_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def load_models() -> tuple:
    """Load YOLOv8n and Grounding DINO. Returns (yolo, gdino_processor, gdino_model, device)."""
    print("Loading YOLOv8n...")
    yolo = YOLO("yolov8n.pt")

    device = get_device()
    print(f"Loading Grounding DINO  (device: {device}) — first run downloads ~700 MB...")
    processor = AutoProcessor.from_pretrained(GDINO_MODEL_ID)
    gdino = AutoModelForZeroShotObjectDetection.from_pretrained(GDINO_MODEL_ID).to(device)
    gdino.eval()

    return yolo, processor, gdino, device


# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------
def resolve_target(user_input: str) -> tuple[str, str]:
    """
    Returns (detector, target) where detector is "yolo" or "gdino".
    COCO-80 objects (including aliases) go to YOLO; everything else to Grounding DINO.
    """
    name = user_input.strip().lower()

    if name in COCO_CLASSES:
        return "yolo", name

    if name in ALIASES and ALIASES[name] in COCO_CLASSES:
        mapped = ALIASES[name]
        print(f"Understood '{user_input}' as '{mapped}'.")
        return "yolo", mapped

    # Single substring match against COCO (e.g. "cell" → "cell phone")
    substring_matches = [c for c in COCO_CLASSES if name in c]
    if len(substring_matches) == 1:
        print(f"Understood '{user_input}' as '{substring_matches[0]}'.")
        return "yolo", substring_matches[0]

    # Anything else → Grounding DINO (open vocabulary)
    print(f"'{user_input}' is not in the standard list — using open-vocabulary detector.")
    return "gdino", name


# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------
def detect_yolo(frame, target_class: str, yolo: YOLO) -> list[float]:
    """Returns confidence scores for all detections of target_class."""
    results = yolo(frame, verbose=False)
    return [
        float(box.conf[0])
        for result in results
        for box in result.boxes
        if yolo.names[int(box.cls[0])].lower() == target_class
        and float(box.conf[0]) >= YOLO_CONF_THRESHOLD
    ]


def detect_gdino(
    frame,
    target_text: str,
    processor: AutoProcessor,
    gdino,
    device: torch.device,
) -> tuple[list[float], list]:
    """
    Returns (confidence_scores, boxes_xyxy).
    Grounding DINO expects a period-terminated text prompt.
    """
    image = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
    prompt = target_text.rstrip(".") + "."

    inputs = processor(images=image, text=prompt, return_tensors="pt").to(device)
    with torch.no_grad():
        outputs = gdino(**inputs)

    h, w = frame.shape[:2]
    results = processor.post_process_grounded_object_detection(
        outputs,
        inputs.input_ids,
        box_threshold=GDINO_BOX_THRESHOLD,
        text_threshold=GDINO_TEXT_THRESHOLD,
        target_sizes=[(h, w)],
    )[0]

    scores = [float(s) for s in results["scores"]]
    boxes = [box.tolist() for box in results["boxes"]]
    return scores, boxes


def draw_gdino_boxes(frame, boxes: list, label: str, scores: list[float]):
    for box, score in zip(boxes, scores):
        x1, y1, x2, y2 = (int(v) for v in box)
        cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(
            frame,
            f"{label} {score:.0%}",
            (x1, max(y1 - 8, 0)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (0, 255, 0),
            2,
        )
    return frame


# ---------------------------------------------------------------------------
# Detection loop
# ---------------------------------------------------------------------------
def detect_loop(
    detector: str,
    target: str,
    cap: cv2.VideoCapture,
    yolo: YOLO,
    processor,
    gdino,
    device: torch.device,
    show_window: bool,
) -> None:
    print(f"\nLooking for: {target}  [{detector.upper()}]")
    print("Press Ctrl+C (or 'q' in the window) to search for a different object.\n")

    last_status: bool | None = None
    last_output_time: float = 0.0

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                print("Error: Could not read camera frame.")
                break

            now = time.time()

            if detector == "yolo":
                scores = detect_yolo(frame, target, yolo)
                found = bool(scores)
                annotated = yolo(frame, verbose=False)[0].plot() if show_window else None

            else:  # gdino
                scores, boxes = detect_gdino(frame, target, processor, gdino, device)
                found = bool(scores)
                if show_window:
                    annotated = frame.copy()
                    if found:
                        annotated = draw_gdino_boxes(annotated, boxes, target, scores)

            status_changed = found != last_status
            due_reannounce = (now - last_output_time) >= REANNOUNCE_EVERY

            if status_changed or due_reannounce:
                if found:
                    best = max(scores)
                    count = len(scores)
                    noun = f"{count} {target}(s)" if count > 1 else f"a {target}"
                    print(f"YES  —  I can see {noun} in view.  ({best:.0%} confidence)")
                else:
                    print(f"NO   —  {target} is not currently in view.")
                last_status = found
                last_output_time = now

            if show_window:
                cv2.imshow("Vision Assist  (press q to change object)", annotated)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

    except KeyboardInterrupt:
        pass


# ---------------------------------------------------------------------------
# REST API server  (python app.py --serve)
# ---------------------------------------------------------------------------
def run_server(port: int = 5000) -> None:
    """
    POST /detect
      Body (JSON): { "image": "<base64-encoded JPEG>", "target": "<object name>" }
      Response:    { "found": bool, "confidence": float|null, "count": int, "message": str }
    """
    from flask import Flask, jsonify, request as freq

    app = Flask(__name__)
    yolo, processor, gdino, device = load_models()
    print(f"\nVision Assist API ready on http://0.0.0.0:{port}\n")

    @app.route("/detect", methods=["POST"])
    def detect():
        data = freq.get_json(force=True)
        if not data or "image" not in data or "target" not in data:
            return jsonify({"error": "Provide 'image' (base64 JPEG) and 'target'"}), 400

        try:
            img_bytes = base64.b64decode(data["image"])
            pil_img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
            # Convert PIL → BGR numpy array for OpenCV/YOLO
            import numpy as np
            frame = np.array(pil_img)[:, :, ::-1].copy()
        except Exception as exc:
            return jsonify({"error": f"Could not decode image: {exc}"}), 400

        target_input: str = data["target"]
        detector, target = resolve_target(target_input)

        if detector == "yolo":
            scores = detect_yolo(frame, target, yolo)
        else:
            scores, _ = detect_gdino(frame, target, processor, gdino, device)

        found = bool(scores)
        confidence = round(max(scores), 4) if found else None
        count = len(scores)

        if found:
            noun = f"{count} {target}(s)" if count > 1 else f"a {target}"
            message = f"Yes, I can see {noun} in view."
            if confidence is not None:
                message += f" ({confidence:.0%} confidence)"
        else:
            message = f"No, {target} is not currently in view."

        return jsonify({
            "found": found,
            "confidence": confidence,
            "count": count,
            "message": message,
        })

    app.run(host="0.0.0.0", port=port, debug=False)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    if "--serve" in sys.argv:
        port = 5000
        if "--port" in sys.argv:
            idx = sys.argv.index("--port")
            try:
                port = int(sys.argv[idx + 1])
            except (IndexError, ValueError):
                pass
        run_server(port)
        return

    show_window = "--no-window" not in sys.argv

    print("=== Vision Assist ===")
    print("Tell me what object you are looking for, and I will tell you if it is in view.")
    if not show_window:
        print("Running in text-only mode.\n")

    yolo, processor, gdino, device = load_models()
    print("All models ready.\n")

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("Error: Could not open camera. Check that a camera is connected.")
        sys.exit(1)

    try:
        while True:
            print("-" * 40)
            user_input = input("What are you looking for? (or 'quit' to exit): ").strip()
            if not user_input:
                continue
            if user_input.lower() in ("quit", "exit", "q"):
                print("Goodbye.")
                break

            detector, target = resolve_target(user_input)
            detect_loop(detector, target, cap, yolo, processor, gdino, device, show_window)

    except (KeyboardInterrupt, EOFError):
        print("\nGoodbye.")
    finally:
        cap.release()
        if show_window:
            cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
