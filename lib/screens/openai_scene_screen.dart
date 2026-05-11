import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import '../services/openai_scene_service.dart';

// Scene Description — automatically captures a photo 2 seconds after opening
// and reads aloud what the camera sees. No button required.
// Double-tap anywhere to go back.

class OpenAiSceneScreen extends StatefulWidget {
  const OpenAiSceneScreen({super.key});

  @override
  State<OpenAiSceneScreen> createState() => _OpenAiSceneScreenState();
}

class _OpenAiSceneScreenState extends State<OpenAiSceneScreen> {
  final VoiceService _voice = VoiceService();
  late final SceneDescriptionService _sceneService;

  CameraController? _camera;
  bool _cameraReady = false;
  bool _isProcessing = false;

  String _statusLabel = 'READY';
  String _statusText = 'Preparing camera…';
  Color _statusColor = AppColors.accentBlue;

  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _sceneService = SceneDescriptionService(apiKey: kOpenAiApiKey);
    _initCamera().then((_) => _speakIntroThenCapture());
  }

  Future<void> _speakIntroThenCapture() async {
    if (!mounted) return;
    await _voice.init();
    if (!mounted) return;

    setState(() {
      _statusLabel = 'READY';
      _statusText = 'Describing the scene in 2 seconds…';
      _statusColor = AppColors.accentBlue;
    });

    await _voice.speak(
      'Scene Description. '
      'Hold the camera steady. '
      'I will describe what I see. '
      'Double tap anywhere to go back.',
    );

    if (!mounted) return;

    // Auto-capture 2 seconds after intro finishes
    _autoTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_isProcessing) _describeScene();
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _camera?.dispose();
    _sceneService.dispose();
    _voice.stopAll();
    super.dispose();
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });
    } catch (_) {}
  }

  // ── Auto-describe ─────────────────────────────────────────────────────────

  Future<void> _describeScene() async {
    if (_isProcessing) return;
    if (!_cameraReady) {
      await _voice.speak('Camera is not ready yet. Please wait.');
      return;
    }

    HapticFeedback.heavyImpact();
    setState(() {
      _isProcessing = true;
      _statusLabel = 'SCANNING';
      _statusText = 'Analysing the scene…';
      _statusColor = AppColors.accentYellow;
    });
    _voice.speak('Describing the scene.');

    try {
      final xFile = await _camera!.takePicture();
      final description =
          await _sceneService.describeScene(File(xFile.path));

      if (!mounted) return;
      setState(() {
        _statusLabel = 'DESCRIPTION';
        _statusText = description;
        _statusColor = AppColors.accentGreen;
      });
      HapticFeedback.mediumImpact();
      await _voice.speak(description);
      if (mounted) {
        await _voice.speak('Double tap to go back.');
      }

    } on SceneDescriptionException catch (e) {
      if (!mounted) return;
      setState(() {
        _statusLabel = 'API ERROR';
        _statusText = e.message;
        _statusColor = AppColors.accentRed;
      });
      await _voice.speak('Sorry, there was an error: ${e.message}');

    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusLabel = 'NO CONNECTION';
        _statusText = 'Could not reach the internet. Check your Wi-Fi.';
        _statusColor = AppColors.accentRed;
      });
      await _voice
          .speak('Could not connect. Please check your internet connection.');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _goBack() async {
    _autoTimer?.cancel();
    HapticFeedback.mediumImpact();
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
        onDoubleTap: _goBack,
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 60),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 20),
                _buildCameraPreview(),
                const SizedBox(height: 18),
                _buildStatusCard(),
              ],
            ),
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
            Text('Scene Description', style: AppTextStyles.displayMedium),
            Text('Double tap anywhere to go back',
                style: AppTextStyles.bodySecondary),
          ],
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: _cameraReady
          ? CameraPreview(_camera!)
          : Container(
              height: 280,
              color: AppColors.bgCard,
              child: const Center(child: CircularProgressIndicator()),
            ),
    );
  }

  Widget _buildStatusCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: _statusColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _isProcessing
                  ? Icons.hourglass_top_rounded
                  : _statusLabel == 'DESCRIPTION'
                      ? Icons.record_voice_over_rounded
                      : Icons.photo_camera_rounded,
              color: _statusColor,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusLabel,
                  style: AppTextStyles.labelBold
                      .copyWith(color: _statusColor, fontSize: 12),
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
}
