import Flutter
import UIKit
import Speech
import AVFoundation

// SceneDelegate wires up the Flutter engine AND hosts the "com.naviglasses/speech"
// MethodChannel that VoiceService.dart uses for speech-to-text.
//
// Supported methods:
//   "listen"        — start recognition, returns the recognised string
//   "stopListening" — cancel an in-flight listen call (returns "")

class SceneDelegate: FlutterSceneDelegate {

    // ── Speech recognition state ──────────────────────────────────────────
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    private var resultDelivered = false
    // Stored so stopListening can resolve the pending "listen" call
    private var pendingListenResult: FlutterResult?

    // ── Scene lifecycle ───────────────────────────────────────────────────

    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        registerSpeechChannel()
    }

    private func registerSpeechChannel() {
        guard let flutterVC = window?.rootViewController as? FlutterViewController else {
            DispatchQueue.main.async { [weak self] in self?.registerSpeechChannel() }
            return
        }

        let channel = FlutterMethodChannel(
            name: "com.naviglasses/speech",
            binaryMessenger: flutterVC.binaryMessenger
        )

        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "listen":
                self?.requestPermissionsAndListen(result: result)
            case "stopListening":
                self?.cancelListening()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // ── Permission flow ───────────────────────────────────────────────────

    private func requestPermissionsAndListen(result: @escaping FlutterResult) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    result("")
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.beginRecognition(result: result)
                        } else {
                            result("")
                        }
                    }
                }
            }
        }
    }

    // ── Core recognition ──────────────────────────────────────────────────

    private func beginRecognition(result: @escaping FlutterResult) {
        stopRecognition()
        resultDelivered = false
        pendingListenResult = result      // store so cancelListening can resolve it

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            deliver(result, text: "")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = false

        guard let req = recognitionRequest else { deliver(result, text: ""); return }

        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] res, error in
            guard let self = self else { return }
            if let res = res, res.isFinal {
                self.deliver(result, text: res.bestTranscription.formattedString.lowercased())
                self.stopRecognition()
                return
            }
            if error != nil {
                self.deliver(result, text: "")
                self.stopRecognition()
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopRecognition()
            deliver(result, text: "")
            return
        }

        // Hard timeout — endAudio signals the recogniser to finalise
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
            self?.recognitionRequest?.endAudio()
        }
    }

    // Called by Flutter when it wants to abort an in-flight listen (e.g. to speak)
    private func cancelListening() {
        if let pending = pendingListenResult {
            deliver(pending, text: "")
            stopRecognition()
        }
    }

    // Delivers the Flutter result exactly once
    private func deliver(_ result: FlutterResult, text: String) {
        guard !resultDelivered else { return }
        resultDelivered = true
        pendingListenResult = nil
        result(text)
    }

    private func stopRecognition() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
