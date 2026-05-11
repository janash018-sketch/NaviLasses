import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import '../services/vision_assist_service.dart';

// Vision Assist
// ─────────────────────────────────────────────────────────────────────────────
// The user holds the big button at the bottom to record the object name.
// While held: microphone is open (push-to-talk).
// On release: STT finalises → the app searches and speaks the result.
// Double-tap anywhere to go back.
// ─────────────────────────────────────────────────────────────────────────────

class SceneDescriptionScreen extends StatefulWidget {
  const SceneDescriptionScreen({super.key});

  @override
  State<SceneDescriptionScreen> createState() =>
      _SceneDescriptionScreenState();
}

class _SceneDescriptionScreenState extends State<SceneDescriptionScreen> {
  final VoiceService _voice = VoiceService();
  late final VisionAssistService _detector;

  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isProcessing = false;
  bool _isRecording = false; // true while the button is held

  String _statusLabel = 'HOLD TO SPEAK';
  String _statusText = 'Hold the button below and say the object name.';
  bool? _lastFound;

  List<Rect> _detectedBoxes = [];

  @override
  void initState() {
    super.initState();
    _detector = VisionAssistService();
    _detector.init();
    _initCamera().then((_) => _speakIntro());
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _detector.dispose();
    _voice.stopAll();
    super.dispose();
  }

  // ── Intro ─────────────────────────────────────────────────────────────────

  Future<void> _speakIntro() async {
    if (!mounted) return;
    await _voice.init();
    if (!mounted) return;
    await _voice.speak(
      'Vision Assist. '
      'Hold the button at the bottom and say the object you are looking for. '
      'Release when done. '
      'Double tap anywhere to go back.',
    );
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final controller = CameraController(
      cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      ),
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _cameraReady = true;
      });
    } catch (e) {
      debugPrint('Vision Assist camera init error: $e');
    }
  }

  Future<Uint8List?> _captureFrame() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;

    final completer = Completer<Uint8List?>();

    await controller.startImageStream((CameraImage camImg) async {
      if (completer.isCompleted) return;
      try {
        await controller.stopImageStream();
        final w = camImg.width;
        final h = camImg.height;
        final plane = camImg.planes[0];
        final rgbImg = img.Image(width: w, height: h);
        final src = plane.bytes;
        final rowStride = plane.bytesPerRow;
        for (int y = 0; y < h; y++) {
          for (int x = 0; x < w; x++) {
            final i = y * rowStride + x * 4;
            rgbImg.setPixelRgb(x, y, src[i + 2], src[i + 1], src[i]);
          }
        }
        completer.complete(
            Uint8List.fromList(img.encodeJpg(rgbImg, quality: 85)));
      } catch (e) {
        completer.completeError(e);
      }
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
  }

  // ── Push-to-talk ──────────────────────────────────────────────────────────

  /// Called when the user presses down on the hold button.
  void _onHoldStart() {
    if (_isProcessing) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _isRecording = true;
      _statusLabel = 'LISTENING';
      _statusText = 'Keep holding… say the object name.';
      _lastFound = null;
      _detectedBoxes = [];
    });

    _voice.startListening(
      onResult: (words) {
        // Received recognised words — trigger detection
        if (!mounted || words.trim().isEmpty) return;
        _findObject(words.trim());
      },
      onDone: () {
        if (!mounted) return;
        // If still recording (user hasn't released yet), that's fine —
        // we'll process in _onHoldEnd. If nothing came back, reset UI.
        if (mounted && !_isProcessing) {
          setState(() {
            _isRecording = false;
            if (_lastFound == null) {
              _statusLabel = 'HOLD TO SPEAK';
              _statusText = 'Hold the button below and say the object name.';
            }
          });
        }
      },
    );
  }

  /// Called when the user releases the hold button.
  void _onHoldEnd() {
    if (!_isRecording) return;
    setState(() => _isRecording = false);
    // Stop STT — this finalises any partial result and fires onResult/onDone
    _voice.stopListening();
  }

  // ── Detection ─────────────────────────────────────────────────────────────

  Future<void> _findObject(String target) async {
    if (_isProcessing) return;
    if (!_cameraReady) {
      await _voice.speak('Camera is not ready yet. Please wait.');
      return;
    }

    HapticFeedback.heavyImpact();
    setState(() {
      _isProcessing = true;
      _isRecording = false;
      _lastFound = null;
      _detectedBoxes = [];
      _statusLabel = 'SEARCHING';
      _statusText = 'Looking for "$target"…';
    });

    await _voice.speak('Looking for $target.');

    try {
      final frameBytes = await _captureFrame();
      if (frameBytes == null) {
        await _voice.speak('Could not capture a photo. Please try again.');
        if (mounted) _resetToIdle();
        return;
      }

      final result = await _detector.detect(
        imageBytes: frameBytes,
        objectName: target,
      );

      if (!mounted) return;
      setState(() {
        _lastFound = result.found;
        _statusLabel = result.found ? 'FOUND' : 'NOT FOUND';
        _statusText = result.message;
        _detectedBoxes = result.boxes;
      });

      HapticFeedback.mediumImpact();
      await _voice.speak(result.message);

    } on VisionAssistException catch (e) {
      if (!mounted) return;
      setState(() {
        _lastFound = null;
        _statusLabel = 'ERROR';
        _statusText = e.message;
      });
      await _voice.speak(e.message);
    } catch (e, st) {
      debugPrint('VisionAssist error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _lastFound = null;
        _statusLabel = 'ERROR';
        _statusText = 'Something went wrong. Please try again.';
      });
      await _voice.speak('Something went wrong. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
        // After result is spoken, prompt the user to try again
        if (mounted) _resetToIdle();
      }
    }
  }

  void _resetToIdle() {
    setState(() {
      _statusLabel = 'HOLD TO SPEAK';
      _statusText = 'Hold the button to search for another object.';
    });
  }

  Future<void> _goBack() async {
    HapticFeedback.mediumImpact();
    await _voice.stopAll();
    if (mounted) Navigator.pop(context);
  }

  // ── Colours / icons ───────────────────────────────────────────────────────

  Color get _cardColor {
    if (_lastFound == true) return AppColors.accentGreen;
    if (_lastFound == false) return AppColors.accentRed;
    if (_isRecording) return AppColors.accentBlue;
    if (_isProcessing) return AppColors.accentYellow;
    return AppColors.textSecondary;
  }

  IconData get _cardIcon {
    if (_lastFound == true) return Icons.check_circle_rounded;
    if (_lastFound == false) return Icons.cancel_rounded;
    if (_isRecording) return Icons.mic_rounded;
    if (_isProcessing) return Icons.hourglass_top_rounded;
    return Icons.remove_red_eye_rounded;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: _goBack,
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                child: Column(
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _buildCameraPreview(),
                    const SizedBox(height: 18),
                    _buildStatusCard(),
                  ],
                ),
              ),
              const Spacer(),
              _buildHoldButton(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Go back',
          child: GestureDetector(
            onTap: _goBack,
            child: Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(right: 14),
              decoration: BoxDecoration(
                color: AppColors.bgCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: AppColors.textPrimary, size: 22),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vision Assist', style: AppTextStyles.displayMedium),
            Text('Double tap to go back',
                style: AppTextStyles.bodySecondary),
          ],
        ),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _isRecording ? AppColors.accentBlue : AppColors.bgCard,
            shape: BoxShape.circle,
          ),
          child: Icon(
            _isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
            color: _isRecording ? Colors.white : AppColors.textSecondary,
            size: 20,
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: _cameraReady
          ? Stack(
              children: [
                CameraPreview(_cameraController!),
                if (_detectedBoxes.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BoundingBoxPainter(
                        boxes: _detectedBoxes,
                        color: _lastFound == true
                            ? AppColors.accentGreen
                            : AppColors.accentRed,
                      ),
                    ),
                  ),
              ],
            )
          : Container(
              height: 240,
              color: AppColors.bgCard,
              child: const Center(child: CircularProgressIndicator()),
            ),
    );
  }

  Widget _buildStatusCard() {
    final color = _cardColor;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(_cardIcon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusLabel,
                  style: AppTextStyles.labelBold
                      .copyWith(color: color, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(_statusText, style: AppTextStyles.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Big hold-to-talk button at the bottom.
  /// Uses Listener (not GestureDetector) so onPointerDown fires immediately
  /// — no long-press delay, no disambiguation wait.
  Widget _buildHoldButton() {
    final active = _isRecording;
    final busy = _isProcessing;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Listener(
        onPointerDown: busy ? null : (_) => _onHoldStart(),
        onPointerUp: (_) => _onHoldEnd(),
        onPointerCancel: (_) => _onHoldEnd(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(36),
            color: busy
                ? AppColors.bgCard
                : active
                    ? AppColors.accentRed
                    : const Color(0xFF6B48FF),
            boxShadow: [
              BoxShadow(
                color: (busy
                        ? Colors.transparent
                        : active
                            ? AppColors.accentRed
                            : const Color(0xFF6B48FF))
                    .withValues(alpha: 0.45),
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                busy
                    ? Icons.hourglass_top_rounded
                    : active
                        ? Icons.mic_rounded
                        : Icons.mic_none_rounded,
                color: busy ? AppColors.textSecondary : Colors.white,
                size: 28,
              ),
              const SizedBox(width: 10),
              Text(
                busy
                    ? 'Searching…'
                    : active
                        ? 'Listening…'
                        : 'Hold to speak',
                style: TextStyle(
                  color: busy ? AppColors.textSecondary : Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Bounding box overlay ──────────────────────────────────────────────────────
class _BoundingBoxPainter extends CustomPainter {
  final List<Rect> boxes;
  final Color color;

  const _BoundingBoxPainter({required this.boxes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    final labelBgPaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    );

    for (int i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      final rect = Rect.fromLTRB(
        box.left   * size.width,
        box.top    * size.height,
        box.right  * size.width,
        box.bottom * size.height,
      );

      canvas.drawRect(rect, fillPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        borderPaint,
      );

      final label = i == 0 ? 'FOUND' : '${i + 1}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final badgeTop = (rect.top - 24).clamp(0.0, size.height - 24);
      final badgeRect = Rect.fromLTWH(
        rect.left, badgeTop, tp.width + 10, 22,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(badgeRect, const Radius.circular(4)),
        labelBgPaint,
      );
      tp.paint(canvas, Offset(badgeRect.left + 5, badgeRect.top + 3));
    }
  }

  @override
  bool shouldRepaint(_BoundingBoxPainter old) =>
      old.boxes != boxes || old.color != color;
}
