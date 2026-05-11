import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import 'home_screen.dart';

class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward().then((_) async {
      final voice = VoiceService();
      await voice.init();
      if (!mounted) return;
      await voice.speak('NaviGlasses. Loading your assistant.');
      _autoTimer = Timer(const Duration(milliseconds: 800), _enter);
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _enter() {
    _autoTimer?.cancel();
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final blobH = size.height * 0.72;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      body: FadeTransition(
        opacity: _fade,
        child: Stack(
          children: [
            // ── Full-bleed blob field ──────────────────────────────────────
            SizedBox(
              width: size.width,
              height: blobH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // ── Main purple-pink blob (left-center, very large) ──────
                  Positioned(
                    left: -size.width * 0.12,
                    top: size.height * 0.02,
                    child: Container(
                      width: size.width * 0.92,
                      height: size.width * 0.92,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8A2BE2), Color(0xFFE91E8C)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(size.width * 0.46),
                          topRight: Radius.circular(size.width * 0.24),
                          bottomLeft: Radius.circular(size.width * 0.26),
                          bottomRight: Radius.circular(size.width * 0.46),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF8A2BE2).withValues(alpha: 0.6),
                            blurRadius: 80,
                            spreadRadius: 15,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ── Orange-yellow blob (right, overlapping) ──────────────
                  Positioned(
                    right: -size.width * 0.08,
                    top: size.height * 0.10,
                    child: Container(
                      width: size.width * 0.75,
                      height: size.width * 0.75,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF6B00), Color(0xFFFFE000)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(size.width * 0.16),
                          topRight: Radius.circular(size.width * 0.38),
                          bottomLeft: Radius.circular(size.width * 0.38),
                          bottomRight: Radius.circular(size.width * 0.18),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF6B00).withValues(alpha: 0.5),
                            blurRadius: 70,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ── Pink-lavender accent blob (center) ───────────────────
                  Positioned(
                    left: size.width * 0.20,
                    top: size.height * 0.22,
                    child: Container(
                      width: size.width * 0.50,
                      height: size.width * 0.50,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF5FA0), Color(0xFFBB86FC)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF5FA0).withValues(alpha: 0.45),
                            blurRadius: 55,
                            spreadRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ── Vignette — fade blobs into bg at bottom ───────────────
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: Container(
                      height: blobH * 0.38,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppColors.bgPrimary.withValues(alpha: 0),
                            AppColors.bgPrimary,
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Brand pill at top-left ─────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        child: const Text(
                          'NaviGlasses',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Hero text + button at bottom ──────────────────────────────
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RichText(
                        text: const TextSpan(
                          style: TextStyle(
                            fontSize: 50,
                            color: AppColors.textPrimary,
                            height: 1.06,
                            letterSpacing: -2.0,
                          ),
                          children: [
                            TextSpan(
                              text: 'Navigate\n',
                              style: TextStyle(fontWeight: FontWeight.w300),
                            ),
                            TextSpan(
                              text: 'the world\n',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                            TextSpan(
                              text: 'around you.',
                              style: TextStyle(fontWeight: FontWeight.w300),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Voice-guided assistant for everyone.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 36),
                      Semantics(
                        button: true,
                        label: 'Start application',
                        hint: 'Double tap to enter the main menu',
                        child: GestureDetector(
                          onTap: _enter,
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              color: AppColors.textPrimary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.white.withValues(alpha: 0.28),
                                  blurRadius: 32,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.arrow_forward_rounded,
                              color: AppColors.bgPrimary,
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
