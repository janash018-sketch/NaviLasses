import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Wraps flutter_tts (TTS) and speech_to_text (STT) into one simple API.
///
/// Uses a shared static engine so multiple screens don't fight over the same
/// AVSpeechSynthesizer / SFSpeechRecognizer under the hood.
class VoiceService {
  // ── Shared engines (one per app process) ──────────────────────────────────
  static final FlutterTts _tts = FlutterTts();
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static bool _ttsReady = false;
  static bool _speechReady = false;

  // Per-instance listening flag so each screen can track its own state.
  bool _listening = false;
  static DateTime? _lastListenEnd; // shared — tracks when STT last stopped

  bool get isListening => _listening || _speech.isListening;

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Initialises TTS only.  Call this first so the welcome message can be
  /// spoken before the iOS STT permission dialog appears.
  Future<void> initTtsOnly() async {
    if (!_ttsReady) {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _ttsReady = true;
    }
  }

  /// Initialises STT.  On first launch this triggers the iOS
  /// "Allow speech recognition?" permission dialog.
  Future<void> initStt() async {
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (_) {},
        onError: (_) {},
      );
    }
  }

  /// Initialises both TTS and STT together (used by sub-screens).
  Future<void> init() async {
    await initTtsOnly();
    await initStt();
  }

  Future<void> reinit() async {
    await stopAll(); // fully stop before resetting
    _ttsReady = false;
    _speechReady = false;
    await Future.delayed(const Duration(milliseconds: 600));
    await init();
  }

  // ── TTS ───────────────────────────────────────────────────────────────────

  /// Speaks [text] and awaits completion before returning.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_ttsReady) await init();

    // Stop any current speech first, then wait briefly so iOS can fire the
    // cancel callback from the previous utterance before we set new handlers.
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 150));

    final completer = Completer<void>();

    _tts.setCompletionHandler(() {
      if (!completer.isCompleted) completer.complete();
    });
    _tts.setCancelHandler(() {
      if (!completer.isCompleted) completer.complete();
    });
    _tts.setErrorHandler((_) {
      if (!completer.isCompleted) completer.complete();
    });

    await _tts.speak(text);

    // Safety timeout — don't block forever if the handler never fires.
    await completer.future.timeout(
      Duration(milliseconds: (text.length * 80) + 3000),
      onTimeout: () {},
    );
  }

  // ── STT ───────────────────────────────────────────────────────────────────

  /// Starts listening for one utterance.
  ///
  /// [onResult] is called with the lowercased recognised words when the user
  ///   finishes speaking (final result).
  /// [onDone]   is called when the listening session ends (result or timeout).
  ///
  /// Returns `true` if the session started successfully.
  Future<bool> startListening({
    required void Function(String words) onResult,
    required void Function() onDone,
  }) async {
    if (!_speechReady) await init();
    if (!_speechReady) {
      onDone();
      return false;
    }

    // Stop any previous listening session first.
    if (_speech.isListening) await _speech.stop();

    // Re-init if last session ended more than 3 s ago (or never ran).
    // This ensures the audio session is fresh without being too slow.
    final now = DateTime.now();
    final staleStt = _lastListenEnd == null ||
        now.difference(_lastListenEnd!) > const Duration(seconds: 3);
    if (staleStt) {
      _speechReady = false;
      _speechReady = await _speech.initialize(onStatus: (_) {}, onError: (_) {});
      if (!_speechReady) { onDone(); return false; }
    }

    // Wait for TTS audio to fully fade before the mic opens.
    // 900 ms gives iOS enough time to release the audio session.
    await Future.delayed(const Duration(milliseconds: 900));

    _listening = true;
    bool doneCalled = false;

    void finish() {
      _listening = false;
      _lastListenEnd = DateTime.now();
      if (!doneCalled) {
        doneCalled = true;
        onDone();
      }
    }

    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          final words = result.recognizedWords.toLowerCase().trim();
          _listening = false;
          // Noise filter: ignore results that are too short or look like
          // garbled audio (single chars, numbers only, or empty).
          final isNoise = words.isEmpty ||
              words.length < 2 ||
              RegExp(r'^[\d\s]+$').hasMatch(words);
          if (!isNoise) onResult(words);
          finish();
        }
      },
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(milliseconds: 2000),
      partialResults: false,
      cancelOnError: false, // keep session alive even on minor errors
    );

    // Fallback timeout.
    Future.delayed(const Duration(seconds: 11), finish);

    return true;
  }

  Future<void> stopListening() async {
    await _speech.stop();
    _listening = false;
  }

  /// Stops both TTS and STT immediately.
  Future<void> stopAll() async {
    await _tts.stop();
    await _speech.stop();
    _listening = false;
  }
}
