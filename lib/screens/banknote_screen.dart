import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../services/voice_service.dart';
import '../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BanknoteScreen — Live camera + TFLite inference + voice tally
// Voice interaction: long-press anywhere OR tap the mic button at the bottom.
// ─────────────────────────────────────────────────────────────────────────────
class BanknoteScreen extends StatefulWidget {
  const BanknoteScreen({super.key});

  @override
  State<BanknoteScreen> createState() => _BanknoteScreenState();
}

class _BanknoteScreenState extends State<BanknoteScreen>
    with SingleTickerProviderStateMixin {

  // ── Voice (shared singleton) ──────────────────────────────────────────────
  final VoiceService _voice = VoiceService();
  bool _isListeningForCmd = false;

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _camera;
  bool _cameraReady = false;

  // ── Model ─────────────────────────────────────────────────────────────────
  Interpreter? _interpreter;
  bool _modelReady = false;
  bool _modelFailed = false;
  // Order matches the model's training classes (alphabetical folder names):
  // fifty → five → one → ten → twenty
  final List<String> _labels = ['50 JD', '5 JD', '1 JD', '10 JD', '20 JD'];

  static const double _threshold = 0.55;

  // ── Detection state ───────────────────────────────────────────────────────
  bool _isCapturing = false;
  String? _currentLabel;
  double _currentConfidence = 0;
  String? _lastAnnounced;
  int _silentFrames = 0;

  // Throttle: only run inference once every 2 seconds
  DateTime _lastFrameTime = DateTime(0);
  static const _frameInterval = Duration(milliseconds: 2000);

  // Throttle "move closer" hint — don't repeat more than once every 4 s
  DateTime _lastMoveCloserTime = DateTime(0);

  // ── Session tally ─────────────────────────────────────────────────────────
  final Map<String, int> _tally = {};
  int get _totalBills => _tally.values.fold(0, (a, b) => a + b);

  // ── Pulse animation (camera ring) ─────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.97, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _initAll();
  }

  @override
  void dispose() {
    if (_camera != null && _camera!.value.isStreamingImages) {
      _camera!.stopImageStream();
    }
    _camera?.dispose();
    _interpreter?.close();
    _voice.stopAll();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> _initAll() async {
    await Future.wait([_initCamera(), _loadModel()]);
    if (_cameraReady && _modelReady) {
      await _voice.speak(
        'Bill Scanner. '
        'Hold the bottom of the screen and say total to hear your tally.',
      );
      _startImageStream();
    } else if (!_cameraReady && !_modelFailed) {
      await _voice.speak(
          'Camera could not start. Please allow camera access in Settings.');
    } else if (_modelFailed) {
      await _voice.speak(
          'Sorry, the banknote model could not be loaded. '
          'Please close and reopen the app.');
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final desc = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _camera = CameraController(
        desc,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );
      await _camera!.initialize();
      // Enable torch so the camera captures the bill's true colour
      try {
        await _camera!.setFlashMode(FlashMode.torch);
      } catch (_) {
        // Some devices don't support torch — silently ignore
      }
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _loadModel() async {
    try {
      debugPrint('Banknote model: loading…');
      final byteData = await rootBundle.load('assets/jordanian_banknote.tflite');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes, byteData.lengthInBytes,
      );
      final options = InterpreterOptions()..threads = 4;
      _interpreter = Interpreter.fromBuffer(bytes, options: options);
      _interpreter!.allocateTensors();
      debugPrint('Banknote model: loaded ✓');
      if (mounted) setState(() => _modelReady = true);
    } catch (e, st) {
      debugPrint('Banknote model load error: $e\n$st');
      if (mounted) setState(() => _modelFailed = true);
    }
  }

  // ── Image stream (silent — no shutter sound) ──────────────────────────────

  void _startImageStream() {
    _camera!.startImageStream(_onCameraFrame);
  }

  void _onCameraFrame(CameraImage image) {
    if (!_modelReady || _isCapturing) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameTime) < _frameInterval) return;
    _lastFrameTime = now;
    _isCapturing = true;
    _runInferenceFromFrame(image).whenComplete(() => _isCapturing = false);
  }

  Future<void> _runInferenceFromFrame(CameraImage cameraImage) async {
    if (_interpreter == null || !mounted) return;
    try {
      final plane = cameraImage.planes[0];
      final srcBytes = plane.bytes;
      final srcW = cameraImage.width;
      final srcH = cameraImage.height;
      final rowBytes = plane.bytesPerRow;
      final scaleX = srcW / 224.0;
      final scaleY = srcH / 224.0;

      final input = List.generate(
        1,
        (_) => List.generate(
          224,
          (y) => List.generate(
            224,
            (x) {
              final sx = (x * scaleX).toInt().clamp(0, srcW - 1);
              final sy = (y * scaleY).toInt().clamp(0, srcH - 1);
              final i = sy * rowBytes + sx * 4;
              return [
                srcBytes[i + 2].toDouble(), // R  (BGRA → RGB)
                srcBytes[i + 1].toDouble(), // G
                srcBytes[i + 0].toDouble(), // B
              ];
            },
          ),
        ),
      );

      final output = [List<double>.filled(5, 0.0)];
      _interpreter!.run(input, output);

      final preds = output[0];
      int maxIdx = 0;
      for (int i = 1; i < preds.length; i++) {
        if (preds[i] > preds[maxIdx]) maxIdx = i;
      }
      final confidence = preds[maxIdx];
      final label = _labels[maxIdx];

      debugPrint('Frame → $label @ ${(confidence * 100).round()}%  '
          '[${preds.map((p) => (p * 100).round()).join(', ')}]');

      if (!mounted) return;

      if (confidence >= _threshold) {
        _silentFrames = 0;
        setState(() {
          _currentLabel = label;
          _currentConfidence = confidence;
        });
        if (label != _lastAnnounced) {
          _lastAnnounced = label;
          _tally[label] = (_tally[label] ?? 0) + 1;
          setState(() {});
          HapticFeedback.heavyImpact();
          if (!_isListeningForCmd) {
            await _voice.speak('$label banknote detected.');
            // 2-second pause before scanning again
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      } else {
        _silentFrames++;
        if (mounted) {
          setState(() {
            _currentLabel = null;
            _currentConfidence = confidence;
          });
        }
        if (_silentFrames >= 3) _lastAnnounced = null;

        // "Move closer" hint when something is partially visible
        if (confidence > 0.28 && !_isListeningForCmd) {
          final now = DateTime.now();
          if (now.difference(_lastMoveCloserTime) > const Duration(seconds: 4)) {
            _lastMoveCloserTime = now;
            await _voice.speak('Move closer.');
          }
        }
      }
    } catch (e) {
      debugPrint('Frame inference error: $e');
    }
  }

  // ── Voice control (long-press anywhere OR tap mic button) ─────────────────

  Future<void> _activateVoice() async {
    if (_isListeningForCmd || _voice.isListening) return;
    HapticFeedback.mediumImpact();
    setState(() => _isListeningForCmd = true);
    await _voice.startListening(
      onResult: _handleVoiceCommand,
      onDone: () {
        if (mounted) setState(() => _isListeningForCmd = false);
      },
    );
  }

  void _handleVoiceCommand(String words) {
    if (!mounted) return;
    if (_isBack(words)) {
      _goBack();
    } else if (words.contains('total') || words.contains('tally') ||
        words.contains('count') || words.contains('announce') ||
        words.contains('how many') || words.contains('sum')) {
      _announceTally();
    } else if (words.contains('reset') || words.contains('clear') ||
        words.contains('new') || words.contains('restart')) {
      _resetTally();
    }
  }

  bool _isBack(String words) =>
      words.contains('back') ||
      words.contains('home') ||
      words.contains('exit') ||
      words.contains('menu') ||
      words.contains('return');

  // ── Tally actions ─────────────────────────────────────────────────────────

  Future<void> _announceTally() async {
    HapticFeedback.mediumImpact();
    String msg;
    if (_tally.isEmpty) {
      msg = 'No banknotes detected yet. Point the camera at a bill.';
    } else {
      final total = _totalBills;
      final parts = _tally.entries
          .map((e) => '${e.value} ${e.key} banknote${e.value > 1 ? "s" : ""}')
          .join(', ');
      msg = 'Total: $total banknote${total > 1 ? "s" : ""} detected. $parts.';
    }
    await _voice.speak(msg);
  }

  Future<void> _resetTally() async {
    HapticFeedback.lightImpact();
    setState(() {
      _tally.clear();
      _lastAnnounced = null;
      _currentLabel = null;
    });
    await _voice.speak('Tally cleared. Ready for a new scan.');
  }

  Future<void> _goBack() async {
    HapticFeedback.mediumImpact();
    if (_camera != null && _camera!.value.isStreamingImages) {
      await _camera!.stopImageStream();
    }
    await _voice.stopAll();
    if (mounted) Navigator.pop(context);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: _activateVoice,
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(),
                  const SizedBox(height: 12),
                  Expanded(child: _buildCameraArea()),
                  const SizedBox(height: 12),
                  _buildTallyCard(),
                  const SizedBox(height: 90), // room for floating mic
                ],
              ),
              // Floating mic button
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(child: _buildMicButton()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back to main menu',
            child: GestureDetector(
              onTap: _goBack,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.06), blurRadius: 6)
                  ],
                ),
                child: const Icon(Icons.arrow_back_rounded,
                    color: AppColors.textPrimary, size: 22),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bill Scanner', style: AppTextStyles.displayMedium),
              Text(
                _modelFailed
                    ? 'Model failed to load'
                    : _modelReady
                        ? (_cameraReady ? 'Live scan active' : 'Camera starting…')
                        : 'Loading model…',
                style: AppTextStyles.bodySecondary.copyWith(
                  color: _modelFailed
                      ? AppColors.accentRed
                      : (_modelReady && _cameraReady)
                          ? AppColors.accentGreen
                          : AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Mic indicator
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _isListeningForCmd ? AppColors.accentBlue : AppColors.bgCard,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isListeningForCmd ? Icons.mic_rounded : Icons.mic_none_rounded,
              color: _isListeningForCmd ? Colors.white : AppColors.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          // Status dot
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _modelFailed
                  ? AppColors.accentRed
                  : (_modelReady && _cameraReady)
                      ? AppColors.accentGreen
                      : AppColors.accentOrange,
              boxShadow: (_modelReady && _cameraReady)
                  ? [BoxShadow(color: AppColors.accentGreen.withOpacity(0.4), blurRadius: 8)]
                  : [],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, child) => Transform.scale(
          scale: (_cameraReady && _modelReady) ? _pulseAnim.value : 1.0,
          child: child,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cameraReady && _camera != null)
                CameraPreview(_camera!)
              else
                Container(
                  color: const Color(0xFF111111),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.camera_alt_rounded,
                          color: Colors.white24, size: 64),
                      const SizedBox(height: 14),
                      Text(
                        _cameraReady ? 'Starting preview…' : 'Requesting camera…',
                        style: AppTextStyles.bodySecondary
                            .copyWith(color: Colors.white38),
                      ),
                    ],
                  ),
                ),
              if (_cameraReady)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.80),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _currentLabel != null
                                ? AppColors.accentGreen
                                : _isCapturing
                                    ? AppColors.accentYellow
                                    : Colors.white38,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _currentLabel != null
                                ? '${_currentLabel!}  ✓  ${(_currentConfidence * 100).round()}%'
                                : _currentConfidence > 0
                                    ? 'Best guess: ${(_currentConfidence * 100).round()}% — move closer'
                                    : _isCapturing
                                        ? 'Scanning…'
                                        : 'Point camera at a banknote',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_cameraReady)
                Positioned.fill(
                  child: CustomPaint(painter: _FrameGuide()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTallyCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded,
                  color: AppColors.accentGreen, size: 20),
              const SizedBox(width: 8),
              Text('Session Tally', style: AppTextStyles.labelBold),
              const Spacer(),
              Text(
                '$_totalBills bill${_totalBills == 1 ? '' : 's'} total',
                style: AppTextStyles.bodySecondary.copyWith(
                  color: AppColors.accentGreen,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (_tally.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _tally.entries
                  .map(
                    (e) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.tileMint,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${e.value}×  ${e.key}',
                        style: AppTextStyles.labelBold.copyWith(
                          color: AppColors.accentGreen,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('No bills detected yet',
                  style: AppTextStyles.bodySecondary),
            ),
        ],
      ),
    );
  }

  Widget _buildMicButton() {
    final active = _isListeningForCmd;
    return Semantics(
      button: true,
      label: active
          ? 'Listening — say: total, reset, or go back'
          : 'Tap to give a voice command',
      child: GestureDetector(
        onTap: _activateVoice,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? AppColors.accentRed : AppColors.textPrimary,
            boxShadow: [
              BoxShadow(
                color: (active ? AppColors.accentRed : AppColors.textPrimary)
                    .withOpacity(0.32),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            active ? Icons.stop_rounded : Icons.mic_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Corner guide overlay
// ─────────────────────────────────────────────────────────────────────────────
class _FrameGuide extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.55)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const len = 28.0;
    const pad = 18.0;

    final corners = [
      [Offset(pad, pad + len), Offset(pad, pad), Offset(pad + len, pad)],
      [
        Offset(size.width - pad - len, pad),
        Offset(size.width - pad, pad),
        Offset(size.width - pad, pad + len)
      ],
      [
        Offset(pad, size.height - pad - len),
        Offset(pad, size.height - pad),
        Offset(pad + len, size.height - pad)
      ],
      [
        Offset(size.width - pad, size.height - pad - len),
        Offset(size.width - pad, size.height - pad),
        Offset(size.width - pad - len, size.height - pad)
      ],
    ];

    for (final pts in corners) {
      final path = Path()
        ..moveTo(pts[0].dx, pts[0].dy)
        ..lineTo(pts[1].dx, pts[1].dy)
        ..lineTo(pts[2].dx, pts[2].dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_FrameGuide _) => false;
}
