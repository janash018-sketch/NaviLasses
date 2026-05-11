import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import 'banknote_screen.dart';
import 'ocr_screen.dart';
import 'scene_description_screen.dart';
import 'openai_scene_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final VoiceService _voice = VoiceService();

  bool _isListening = false;
  bool _isSpeaking = false;
  String _statusText = 'Initialising…';
  String _heardText = '';

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  // ── Voice scripts ──────────────────────────────────────────────────────────
  static const String _welcomeMessage =
      'Welcome to NaviGlasses. '
      'I will now read you the available services. '
      'Service 1: Bill Scanner. '
      'Service 2: Text Reader. '
      'Service 3: Vision Assist. '
      'Service 4: Scene Description. '
      'Say the service name or number to open it, or tap a card. '
      'When you are done from a service, double tap anywhere to go back.';

  static const String _returnMessage =
      'You are back at the main menu. '
      'Here are your services. '
      'Service 1: Bill Scanner. '
      'Service 2: Text Reader. '
      'Service 3: Vision Assist. '
      'Service 4: Scene Description. '
      'Say the service name or number to open it.';

  // ── Services ───────────────────────────────────────────────────────────────
  static const _services = [
    _ServiceData(
      icon: Icons.payments_rounded,
      label: 'Bill Scanner',
      subtitle: 'Read currency',
      gradient: AppColors.gradBill,
      keywords: [
        'bill', 'bills', 'money', 'scan', 'cash', 'dinar',
        'banknote', 'currency', 'note', 'one', '1', 'service 1',
        'scanner', 'bill scanner',
      ],
    ),
    _ServiceData(
      icon: Icons.document_scanner_rounded,
      label: 'Text Reader',
      subtitle: 'Read signs & labels',
      gradient: AppColors.gradOcr,
      keywords: [
        'text', 'read', 'ocr', 'sign', 'label', 'letter',
        'word', 'print', 'two', '2', 'service 2', 'reader',
        'scan text', 'text reader',
      ],
    ),
    _ServiceData(
      icon: Icons.remove_red_eye_rounded,
      label: 'Vision Assist',
      subtitle: 'Find objects in view',
      gradient: AppColors.gradVision,
      keywords: [
        'vision', 'assist', 'find', 'object', 'detect', 'look',
        'search', 'three', '3', 'service 3', 'vision assist',
      ],
    ),
    _ServiceData(
      icon: Icons.photo_camera_rounded,
      label: 'Scene Description',
      subtitle: 'Describe what I see',
      gradient: AppColors.gradNav,
      keywords: [
        'scene', 'describe', 'description', 'around', 'what',
        'four', '4', 'service 4', 'scene description', 'camera',
      ],
    ),
  ];

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initAndWelcome();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _voice.stopAll();
    super.dispose();
  }

  // ── Voice flow ─────────────────────────────────────────────────────────────
  Future<void> _initAndWelcome() async {
    // Init TTS first so the welcome message plays before the STT permission
    // dialog appears (the dialog can interrupt the audio session on iOS).
    await _voice.initTtsOnly();
    if (!mounted) return;
    await _voice.speak(_welcomeMessage);
    if (!mounted) return;
    // Now init STT — this triggers the iOS permission dialog after the welcome
    // has already been spoken.
    await _voice.initStt();
    if (!mounted) return;
    await _startListening();
  }

  Future<void> _announceAndListen(String message) async {
    if (!mounted) return;
    setState(() {
      _isSpeaking = true;
      _isListening = false;
      _statusText = 'Speaking…';
      _heardText = '';
    });
    await _voice.speak(message);
    if (!mounted) return;
    await _startListening();
  }

  Future<void> _startListening() async {
    if (!mounted) return;
    setState(() {
      _isListening = true;
      _isSpeaking = false;
      _statusText = 'Listening…';
    });

    final started = await _voice.startListening(
      onResult: _handleVoiceResult,
      onDone: () {
        if (mounted && _isListening) {
          setState(() {
            _isListening = false;
            _statusText = 'Tap the mic to speak';
          });
        }
      },
    );

    if (!started && mounted) {
      setState(() {
        _isListening = false;
        _statusText = 'Tap the mic to speak';
      });
    }
  }

  void _handleVoiceResult(String words) {
    if (!mounted) return;
    setState(() => _heardText = words);
    HapticFeedback.lightImpact();

    for (int i = 0; i < _services.length; i++) {
      for (final kw in _services[i].keywords) {
        if (words.contains(kw)) {
          _openService(i);
          return;
        }
      }
    }

    _announceAndListen(
      "Sorry, I didn't catch that. "
      "Say: Bills, Text Reader, Vision Assist, or Scene Description.",
    );
  }

  Future<void> _openService(int index) async {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _isListening = false;
      _statusText = 'Opening ${_services[index].label}…';
    });
    await _voice.stopAll();
    await _voice.speak('Opening ${_services[index].label}.');
    if (!mounted) return;

    final screens = [
      const BanknoteScreen(),
      const OcrScreen(),
      const SceneDescriptionScreen(),
      const OpenAiSceneScreen(),
    ];

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screens[index]),
    );

    if (mounted) {
      setState(() {
        _statusText = 'Tap the mic to speak';
        _heardText = '';
      });
      // Give the audio session a moment to fully release from the service screen
      await Future.delayed(const Duration(milliseconds: 800));
      await _voice.reinit();
      if (mounted) await _announceAndListen(_returnMessage);
    }
  }

  void _toggleMic() async {
    HapticFeedback.mediumImpact();
    if (_isListening) {
      await _voice.stopListening();
      if (mounted) {
        setState(() {
          _isListening = false;
          _statusText = 'Tap the mic to speak';
        });
      }
    } else if (!_isSpeaking) {
      await _startListening();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _buildHeader(),
                      const SizedBox(height: 24),
                      _buildHeroText(),
                      const SizedBox(height: 16),
                      if (_isListening || _isSpeaking) ...[
                        _buildStatusStrip(),
                        const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 8),
                    ]),
                  ),
                ),
                // 4 full-width service cards stacked vertically
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _ServiceCard(
                          data: _services[i],
                          onTap: () => _openService(i),
                        ),
                      ),
                      childCount: _services.length,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
            ),

            // ── Floating bottom nav bar ──────────────────────────────────
            Positioned(
              bottom: 20,
              left: 24,
              right: 24,
              child: _buildNavBar(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sub-widgets ────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFF6B48FF), Color(0xFFC650FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Text(
              'N',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Welcome back', style: AppTextStyles.bodySecondary),
            Text(
              'NaviGlasses',
              style: AppTextStyles.labelBold.copyWith(
                fontSize: 15,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeroText() {
    return RichText(
      text: const TextSpan(
        style: TextStyle(
          fontSize: 32,
          color: AppColors.textPrimary,
          height: 1.15,
          letterSpacing: -0.8,
        ),
        children: [
          TextSpan(
            text: "Let's explore\n",
            style: TextStyle(fontWeight: FontWeight.w400),
          ),
          TextSpan(
            text: 'your services',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusStrip() {
    final color = _isListening ? AppColors.accentBlue : AppColors.accentGreen;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            _isListening ? Icons.mic_rounded : Icons.volume_up_rounded,
            color: color,
            size: 15,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _heardText.isNotEmpty ? '"$_heardText"' : _statusText,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_isListening) const _WaveAnimation(),
        ],
      ),
    );
  }

  Widget _buildNavBar() {
    final active = _isListening;
    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(36),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Icon(Icons.home_rounded,
              color: AppColors.textPrimary, size: 24),
          Semantics(
            button: true,
            label: active ? 'Stop listening' : 'Start voice command',
            child: GestureDetector(
              onTap: _toggleMic,
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, child) => Transform.scale(
                  scale: active ? _pulseAnim.value : 1.0,
                  child: child,
                ),
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: active
                          ? [AppColors.accentRed, const Color(0xFFFF8A80)]
                          : [
                              const Color(0xFF6B48FF),
                              const Color(0xFFC650FF)
                            ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (active
                                ? AppColors.accentRed
                                : const Color(0xFF6B48FF))
                            .withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    active ? Icons.stop_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
          Icon(
            Icons.grid_view_rounded,
            color: AppColors.textSecondary.withValues(alpha: 0.5),
            size: 22,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────
class _ServiceData {
  final IconData icon;
  final String label;
  final String subtitle;
  final LinearGradient gradient;
  final List<String> keywords;

  const _ServiceData({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.gradient,
    required this.keywords,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-width service card
// ─────────────────────────────────────────────────────────────────────────────
class _ServiceCard extends StatelessWidget {
  final _ServiceData data;
  final VoidCallback onTap;

  const _ServiceCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: data.label,
      hint: data.subtitle,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 100,
          decoration: BoxDecoration(
            gradient: data.gradient,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: data.gradient.colors.first.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Decorative blobs
              Positioned(
                right: -24,
                top: -24,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
              ),
              Positioned(
                right: 48,
                bottom: -20,
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
              ),
              // Content
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(data.icon, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 18),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(data.label,
                            style: AppTextStyles.cardCategory
                                .copyWith(fontSize: 17)),
                        const SizedBox(height: 3),
                        Text(data.subtitle,
                            style: AppTextStyles.cardSubtitle),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.22),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_forward_rounded,
                          color: Colors.white, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated waveform bars (shown while listening)
// ─────────────────────────────────────────────────────────────────────────────
class _WaveAnimation extends StatefulWidget {
  const _WaveAnimation();

  @override
  State<_WaveAnimation> createState() => _WaveAnimationState();
}

class _WaveAnimationState extends State<_WaveAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(4, (i) {
            final phase = (i % 2 == 0) ? _ctrl.value : 1 - _ctrl.value;
            final h = 4.0 + phase * 10.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3,
                height: h,
                decoration: BoxDecoration(
                  color: AppColors.accentBlue,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
