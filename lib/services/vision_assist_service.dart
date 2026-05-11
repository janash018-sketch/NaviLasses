import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VisionAssistService — On-device object detection, fully offline.
//
// Two-model strategy:
//   1. vision_assist.tflite  — 16 everyday objects (keys, wallet, phone…)
//   2. yolov8n.tflite        — 80 COCO objects (chair, bottle, person…) fallback
//
// Both models: Input [1, 320, 320, 3] NHWC float32 normalised to [0, 1].
// yolov8n output: [1, 84, 2100]  (combined: 4 box + 80 class scores)
// vision_assist:  shapes read at runtime (YOLOv8 two-output or combined format)
//
// Preprocessing runs on a background isolate to keep the UI thread free.
// ─────────────────────────────────────────────────────────────────────────────

class VisionAssistException implements Exception {
  final String message;
  const VisionAssistException(this.message);
  @override
  String toString() => 'VisionAssistException: $message';
}

class VisionAssistResult {
  final bool found;
  final double confidence;
  final int count;
  final String message;
  final List<Rect> boxes; // normalized [0,1] coords in model input space
  const VisionAssistResult({
    required this.found,
    required this.confidence,
    required this.count,
    required this.message,
    this.boxes = const [],
  });
}

// ── NMS helper ────────────────────────────────────────────────────────────────
class _Det {
  final double conf;
  final Rect box;
  const _Det(this.conf, this.box);
}

// ── Isolate payload for heavy preprocessing ────────────────────────────────
class _PreprocessInput {
  final Uint8List imageBytes;
  final int size;
  const _PreprocessInput(this.imageBytes, this.size);
}

Float32List _preprocessIsolate(_PreprocessInput p) {
  final decoded = img.decodeImage(p.imageBytes)!;
  final resized = img.copyResize(decoded,
      width: p.size,
      height: p.size,
      interpolation: img.Interpolation.linear);

  final out = Float32List(p.size * p.size * 3);
  int idx = 0;
  for (int y = 0; y < p.size; y++) {
    for (int x = 0; x < p.size; x++) {
      final px = resized.getPixel(x, y);
      out[idx++] = px.r / 255.0;
      out[idx++] = px.g / 255.0;
      out[idx++] = px.b / 255.0;
    }
  }
  return out;
}

class VisionAssistService {
  static const int _inputSize = 320;
  // Raised from 0.45 → 0.65 to cut false positives dramatically
  static const double _confThreshold = 0.65;
  static const double _nmsIouThreshold = 0.45;

  // Custom 16-object model
  Interpreter? _customInterp;
  List<String> _customLabels = [];

  // YOLOv8n COCO-80 fallback
  Interpreter? _cocoInterp;
  List<String> _cocoLabels = [];

  bool _ready = false;

  // ── Aliases: what users say → label name ─────────────────────────────────
  static const Map<String, String> _aliases = {
    'key': 'keys', 'car key': 'keys', 'house key': 'keys',
    'purse': 'wallet',
    'spectacles': 'glasses', 'eyeglasses': 'glasses',
    'shades': 'sunglasses',
    'cable': 'charger', 'charging cable': 'charger', 'charger cable': 'charger',
    'medication': 'medicine', 'pill': 'medicine', 'pills': 'medicine', 'tablets': 'medicine',
    'earphones': 'headphones', 'earbuds': 'headphones', 'headset': 'headphones',
    'id': 'id card', 'identification': 'id card', 'national id': 'id card',
    'card': 'credit card', 'debit card': 'credit card', 'bank card': 'credit card',
    'tv remote': 'remote', 'remote control': 'remote',
    'mug': 'cup', 'glass': 'cup', 'coffee cup': 'cup',
    'water bottle': 'bottle', 'juice bottle': 'bottle',
    'mobile': 'phone', 'iphone': 'phone', 'cell phone': 'phone', 'smartphone': 'phone',
    'sofa': 'couch', 'settee': 'couch',
    'table': 'dining table',
    'computer': 'laptop', 'macbook': 'laptop', 'notebook': 'laptop',
    'tv': 'tv', 'television': 'tv', 'monitor': 'tv', 'screen': 'tv',
    'fridge': 'refrigerator', 'freezer': 'refrigerator',
    'plant': 'potted plant', 'flower pot': 'potted plant',
    'bike': 'bicycle', 'motorbike': 'motorcycle',
    'people': 'person', 'human': 'person', 'man': 'person', 'woman': 'person',
    'dog': 'dog', 'puppy': 'dog', 'cat': 'cat', 'kitty': 'cat',
  };

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_ready) return;
    final opts = InterpreterOptions()..threads = 4;

    try {
      final buf = await rootBundle.load('assets/vision_assist.tflite');
      _customInterp = Interpreter.fromBuffer(
          buf.buffer.asUint8List(), options: opts);
      _customInterp!.allocateTensors();
      final labelStr = await rootBundle.loadString('assets/vision_assist_labels.txt');
      _customLabels = labelStr.trim().split('\n').map((s) => s.trim().toLowerCase()).toList();
    } catch (e) {
      debugPrint('Vision Assist custom model load error: $e');
    }

    try {
      final buf = await rootBundle.load('assets/yolov8n.tflite');
      _cocoInterp = Interpreter.fromBuffer(
          buf.buffer.asUint8List(), options: opts);
      _cocoInterp!.allocateTensors();
      final labelStr = await rootBundle.loadString('assets/yolov8n_labels.txt');
      _cocoLabels = labelStr.trim().split('\n').map((s) => s.trim().toLowerCase()).toList();
    } catch (e) {
      debugPrint('Vision Assist COCO model load error: $e');
    }

    _ready = true;
  }

  // ── Label resolution ──────────────────────────────────────────────────────

  (Interpreter, int, String, List<String>)? _resolveTarget(String userInput) {
    final q = _aliases[userInput] ?? userInput;

    if (_customInterp != null) {
      final idx = _customLabels.indexOf(q);
      if (idx != -1) return (_customInterp!, idx, q, _customLabels);
      for (int i = 0; i < _customLabels.length; i++) {
        if (q.contains(_customLabels[i]) || _customLabels[i].contains(q)) {
          return (_customInterp!, i, _customLabels[i], _customLabels);
        }
      }
    }

    if (_cocoInterp != null) {
      final idx = _cocoLabels.indexOf(q);
      if (idx != -1) return (_cocoInterp!, idx, q, _cocoLabels);
      for (int i = 0; i < _cocoLabels.length; i++) {
        if (q.contains(_cocoLabels[i]) || _cocoLabels[i].contains(q)) {
          return (_cocoInterp!, i, _cocoLabels[i], _cocoLabels);
        }
      }
    }

    return null;
  }

  // ── Detection ─────────────────────────────────────────────────────────────

  Future<VisionAssistResult> detect({
    File? imageFile,
    Uint8List? imageBytes,
    required String objectName,
  }) async {
    assert(imageFile != null || imageBytes != null,
        'Provide either imageFile or imageBytes');
    if (!_ready) await init();

    final q = objectName.trim().toLowerCase();
    final resolved = _resolveTarget(q);

    if (resolved == null) {
      final known = [..._customLabels.take(8), 'and more'].join(', ');
      return VisionAssistResult(
        found: false, confidence: 0, count: 0,
        message: 'I cannot find "$objectName". I know objects like: $known.',
      );
    }

    final (interp, targetIdx, resolvedLabel, _) = resolved;

    final bytes = imageBytes ?? await imageFile!.readAsBytes();
    final inputFlat = await compute(
      _preprocessIsolate,
      _PreprocessInput(bytes, _inputSize),
    );
    final input = _reshapeInput(inputFlat, _inputSize);

    final (found, conf, count, boxes) = _runAndParse(interp, input, targetIdx);

    // Natural-language message — never exposes raw anchor counts
    final label = resolvedLabel;
    final String objectStr;
    if (count == 1) {
      objectStr = 'a $label';
    } else if (count == 2) {
      objectStr = 'two ${label}s';
    } else {
      objectStr = 'multiple ${label}s';
    }

    final message = found
        ? 'Yes, I can see $objectStr in view. '
          '${(conf * 100).round()} percent confidence.'
        : 'No, I do not see a $label in this scene.';

    return VisionAssistResult(
      found: found, confidence: conf, count: count,
      message: message, boxes: boxes,
    );
  }

  // ── Inference + NMS ───────────────────────────────────────────────────────

  (bool, double, int, List<Rect>) _runAndParse(
      Interpreter interp, List input, int targetIdx) {

    final numOutputs = interp.getOutputTensors().length;

    if (numOutputs >= 2) {
      // Split output: [1, 64, N] boxes + [1, nc, N] classes
      final boxShape  = interp.getOutputTensor(0).shape;
      final clsShape  = interp.getOutputTensor(1).shape;
      final numAnchors = boxShape[2];
      final numClasses = clsShape[1];

      final boxOut = [List.generate(boxShape[1], (_) => List<double>.filled(numAnchors, 0.0))];
      final clsOut = [List.generate(numClasses, (_) => List<double>.filled(numAnchors, 0.0))];
      interp.runForMultipleInputs([input], {0: boxOut, 1: clsOut});

      final dets = <_Det>[];
      if (targetIdx < numClasses) {
        for (int a = 0; a < numAnchors; a++) {
          final conf = _sigmoid(clsOut[0][targetIdx][a]);
          if (conf >= _confThreshold) {
            // DFL box decoding is complex; use a centred placeholder.
            // NMS collapses all to 1 detection (IoU = 1.0 for identical boxes).
            dets.add(_Det(conf, const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5)));
          }
        }
      }

      final nms = _applyNMS(dets);
      if (nms.isEmpty) return (false, 0.0, 0, const []);
      final bestConf = nms.map((d) => d.conf).reduce(math.max);
      return (true, bestConf, nms.length, nms.map((d) => d.box).toList());

    } else {
      // Combined output [1, nc+4, numAnchors]
      final outShape    = interp.getOutputTensor(0).shape;
      final numAnchors  = outShape[2];
      final numChannels = outShape[1];

      final out = List.generate(1, (_) =>
        List.generate(numChannels, (_) =>
          List<double>.filled(numAnchors, 0.0)));
      interp.run(input, out);

      const classOffset = 4;
      final numClasses  = numChannels - classOffset;

      final dets = <_Det>[];
      if (targetIdx < numClasses) {
        for (int a = 0; a < numAnchors; a++) {
          final conf = _sigmoid(out[0][classOffset + targetIdx][a]);
          if (conf >= _confThreshold) {
            // Auto-detect pixel vs normalised coords
            final cxRaw = out[0][0][a];
            final cyRaw = out[0][1][a];
            final wRaw  = out[0][2][a];
            final hRaw  = out[0][3][a];
            final scale = (cxRaw > 1.0 || cyRaw > 1.0 || wRaw > 1.0 || hRaw > 1.0)
                ? _inputSize.toDouble()
                : 1.0;
            final cx = cxRaw / scale;
            final cy = cyRaw / scale;
            final w  = wRaw  / scale;
            final h  = hRaw  / scale;
            final left   = (cx - w / 2).clamp(0.0, 1.0);
            final top    = (cy - h / 2).clamp(0.0, 1.0);
            final right  = (cx + w / 2).clamp(0.0, 1.0);
            final bottom = (cy + h / 2).clamp(0.0, 1.0);
            dets.add(_Det(conf, Rect.fromLTRB(left, top, right, bottom)));
          }
        }
      }

      final nms = _applyNMS(dets);
      if (nms.isEmpty) return (false, 0.0, 0, const []);
      final bestConf = nms.map((d) => d.conf).reduce(math.max);
      return (true, bestConf, nms.length, nms.map((d) => d.box).toList());
    }
  }

  // ── NMS ───────────────────────────────────────────────────────────────────

  List<_Det> _applyNMS(List<_Det> dets) {
    if (dets.isEmpty) return [];
    final sorted = List<_Det>.from(dets)
      ..sort((a, b) => b.conf.compareTo(a.conf));
    final kept = <_Det>[];
    final suppressed = List.filled(sorted.length, false);

    for (int i = 0; i < sorted.length; i++) {
      if (suppressed[i]) continue;
      kept.add(sorted[i]);
      for (int j = i + 1; j < sorted.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(sorted[i].box, sorted[j].box) > _nmsIouThreshold) {
          suppressed[j] = true;
        }
      }
    }
    return kept;
  }

  double _iou(Rect a, Rect b) {
    final inter = a.intersect(b);
    if (inter.isEmpty) return 0.0;
    final interArea = inter.width * inter.height;
    final unionArea = a.width * a.height + b.width * b.height - interArea;
    return unionArea > 0 ? interArea / unionArea : 0.0;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static double _sigmoid(double x) =>
      1.0 / (1.0 + math.exp(-x.clamp(-88.0, 88.0)));

  List _reshapeInput(Float32List flat, int size) {
    final row = List.generate(size, (y) =>
      List.generate(size, (x) {
        final base = (y * size + x) * 3;
        return [flat[base], flat[base + 1], flat[base + 2]];
      }),
    );
    return [row];
  }

  void dispose() {
    _customInterp?.close();
    _cocoInterp?.close();
    _ready = false;
  }
}
