import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/voice_service.dart';
import '../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// OCR Screen — Real-time text recognition via Apple Vision (VNRecognizeTextRequest)
//
// Every 3 seconds the screen captures a still photo and sends the file path
// to the native "com.naviglasses/ocr" MethodChannel.  The Swift side runs
// VNRecognizeTextRequest (accurate mode) and returns the recognised text.
// If the text changes, it is spoken aloud automatically.
//
// Voice commands (long-press or mic button):
//   "read"  / "what" / "say" → repeat last text
//   "clear" / "reset"        → clear buffer
//   "back"  / "home"         → return to main menu
//
// Double-tap anywhere → go back to main menu.
// ─────────────────────────────────────────────────────────────────────────────

class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key});

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen>
    with SingleTickerProviderStateMixin {
  // ── Platform channel ──────────────────────────────────────────────────────
  static const _ocrChannel = MethodChannel('com.naviglasses/ocr');

  // ── Services ──────────────────────────────────────────────────────────────
  final VoiceService _voice = VoiceService();

  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _camera;
  bool _cameraReady = false;

  // ── Scan state ────────────────────────────────────────────────────────────
  bool _isScanning = false;
  bool _isSpeaking = false;
  bool _isListeningForCmd = false;

  String _detectedText = '';
  String _lastSpokenText = '';
  String _scanStatus = 'Initialising…';

  Timer? _scanTimer;

  // ── Animation ─────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.98, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _initAll();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _camera?.dispose();
    _voice.stopAll();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> _initAll() async {
    await _initCamera();
    if (_cameraReady) {
      if (mounted) setState(() => _scanStatus = 'Point camera at text…');
      await _voice.speak(
        'Text reader ready. '
        'Point the camera at any sign, label, or printed text. '
        'I will read it aloud automatically. '
        'Long press anywhere or tap the microphone button to give a voice command. '
        'Double tap to go back.',
      );
      _startAutoScan();
    } else {
      if (mounted) setState(() => _scanStatus = 'Camera unavailable');
      await _voice.speak(
          'Camera unavailable. Please allow camera access in Settings.');
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
      );
      await _camera!.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      debugPrint('OCR cam init error: $e');
    }
  }

  // ── Auto-scan every 3 seconds ─────────────────────────────────────────────

  void _startAutoScan() {
    _scanTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_isScanning && !_isSpeaking && !_isListeningForCmd && _cameraReady) {
        _scanOnce();
      }
    });
  }

  Future<void> _scanOnce() async {
    if (_isScanning || _isSpeaking || !_cameraReady || _camera == null) return;
    if (mounted) {
      setState(() {
        _isScanning = true;
        _scanStatus = 'Scanning…';
      });
    }

    try {
      // Capture still photo
      final xFile = await _camera!.takePicture();
      if (!mounted) return;

      // Send path to Apple Vision on the native side
      final text = await _ocrChannel.invokeMethod<String>('recognizeText', {
        'imagePath': xFile.path,
      });

      // Clean up temp file
      try { File(xFile.path).deleteSync(); } catch (_) {}

      if (!mounted) return;

      if (text != null && text.trim().isNotEmpty) {
        final trimmed = text.trim();
        setState(() {
          _detectedText = trimmed;
          _scanStatus = 'Text detected';
        });

        // Only speak if text changed and we're not handling a voice command
        if (trimmed != _lastSpokenText && !_isListeningForCmd) {
          _lastSpokenText = trimmed;
          _isSpeaking = true;
          await _voice.speak(trimmed);
          _isSpeaking = false;
        }
      } else {
        if (mounted) {
          setState(() => _scanStatus = 'No text found — keep camera steady…');
        }
      }
    } catch (e) {
      debugPrint('OCR scan error: $e');
      if (mounted) setState(() => _scanStatus = 'Scan error — retrying…');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  // ── Voice control ─────────────────────────────────────────────────────────

  Future<void> _activateVoice() async {
    if (_isListeningForCmd || _voice.isListening) return;
    HapticFeedback.heavyImpact();
    if (mounted) setState(() => _isListeningForCmd = true);
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
    } else if (words.contains('read') || words.contains('text') ||
        words.contains('say') || words.contains('what') ||
        words.contains('hear') || words.contains('tell')) {
      _readText();
    } else if (words.contains('clear') || words.contains('reset') ||
        words.contains('new') || words.contains('again')) {
      _clearText();
    } else if (words.contains('scan') || words.contains('look') ||
        words.contains('check')) {
      _scanOnce();
    }
  }

  bool _isBack(String words) =>
      words.contains('back') ||
      words.contains('home') ||
      words.contains('exit') ||
      words.contains('menu') ||
      words.contains('return');

  Future<void> _readText() async {
    if (_detectedText.isEmpty) {
      await _voice.speak(
          'No text detected yet. Point the camera at a sign or label and hold steady.');
    } else {
      await _voice.speak('Detected text: $_detectedText');
    }
  }

  Future<void> _clearText() async {
    setState(() {
      _detectedText = '';
      _lastSpokenText = '';
      _scanStatus = 'Cleared — ready for a new scan';
    });
    await _voice.speak('Text cleared. Ready for a new scan.');
  }

  Future<void> _goBack() async {
    _scanTimer?.cancel();
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
        onDoubleTap: _goBack,        // double-tap → go back
        onLongPress: _activateVoice, // long-press → voice command
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(),
                  const SizedBox(height: 12),
                  Expanded(child: _buildCameraArea()),
                  const SizedBox(height: 12),
                  _buildStatusCard(),
                  const SizedBox(height: 90), // room for floating mic
                ],
              ),
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
            label: 'Go back to main menu',
            child: GestureDetector(
              onTap: _goBack,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(12),
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
              Text('Text Reader', style: AppTextStyles.displayMedium),
              Text(
                _cameraReady ? 'Auto-scanning every 3 s' : 'Loading…',
                style: AppTextStyles.bodySecondary.copyWith(
                  color: _cameraReady
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
              color:
                  _isListeningForCmd ? AppColors.accentBlue : AppColors.bgCard,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isListeningForCmd ? Icons.mic_rounded : Icons.mic_none_rounded,
              color: _isListeningForCmd ? Colors.white : AppColors.textSecondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          // Status dot: yellow while scanning, green when ready, grey when off
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isScanning
                  ? AppColors.accentYellow
                  : _cameraReady
                      ? AppColors.accentGreen
                      : AppColors.textSecondary,
              boxShadow: _cameraReady
                  ? [
                      BoxShadow(
                        color: (_isScanning
                                ? AppColors.accentYellow
                                : AppColors.accentGreen)
                            .withValues(alpha: 0.4),
                        blurRadius: 8,
                      )
                    ]
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
          scale: _isScanning ? _pulseAnim.value : 1.0,
          child: child,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: _cameraReady && _camera != null
              ? CameraPreview(_camera!)
              : Container(
                  color: const Color(0xFF111111),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.document_scanner_rounded,
                          color: Colors.white24, size: 64),
                      const SizedBox(height: 14),
                      Text('Preparing camera…',
                          style: AppTextStyles.bodySecondary
                              .copyWith(color: Colors.white38)),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final color = _isScanning
        ? AppColors.accentYellow
        : _detectedText.isNotEmpty
            ? AppColors.accentGreen
            : AppColors.textSecondary;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _isScanning ? Icons.radar : Icons.text_fields_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _isScanning ? 'Scanning…' : 'Detected Text',
                style: AppTextStyles.labelBold.copyWith(color: color),
              ),
              const Spacer(),
              if (_detectedText.isNotEmpty)
                GestureDetector(
                  onTap: _clearText,
                  child: Text('Clear',
                      style: AppTextStyles.bodySecondary
                          .copyWith(color: AppColors.accentBlue)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _detectedText.isEmpty ? _scanStatus : _detectedText,
            style: AppTextStyles.bodyLarge.copyWith(
              color: _detectedText.isEmpty
                  ? AppColors.textSecondary
                  : AppColors.textPrimary,
            ),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildMicButton() {
    final active = _isListeningForCmd;
    return Semantics(
      button: true,
      label: active ? 'Listening — say a command' : 'Tap to give a voice command',
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
                    .withValues(alpha: 0.32),
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
