import Flutter
import UIKit
import Vision
// Note: TensorFlowLiteSelectTfOps is declared as a pod dependency in the Podfile.
// With use_frameworks!, dyld loads it at app launch and its C++ static
// initialisers auto-register the Flex ops (TensorList/LSTM) with the TFLite
// kernel registry — no explicit import or function call needed here.

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // ── Apple Vision OCR channel ───────────────────────────────────────────
    // Dart side calls MethodChannel("com.naviglasses/ocr")
    //   .invokeMethod("recognizeText", {"imagePath": "/path/to/photo.jpg"})
    // Returns the recognised text as a String, or null if nothing found.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OcrPlugin") else {
      return
    }
    let ocrChannel = FlutterMethodChannel(
      name: "com.naviglasses/ocr",
      binaryMessenger: registrar.messenger()
    )
    ocrChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard call.method == "recognizeText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let imagePath = args["imagePath"] as? String else {
        result(FlutterError(code: "INVALID_ARGS",
                            message: "imagePath is required",
                            details: nil))
        return
      }
      self?.recognizeText(imagePath: imagePath, result: result)
    }
  }

  /// Runs VNRecognizeTextRequest on a JPEG/PNG saved by the camera plugin.
  /// Dispatches the recognised text (or nil) back to the Flutter result on main.
  private func recognizeText(imagePath: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let image = UIImage(contentsOfFile: imagePath),
            let cgImage = image.cgImage else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do {
        try handler.perform([request])
        let lines = (request.results ?? [])
          .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        DispatchQueue.main.async {
          result(text.isEmpty ? nil : text)
        }
      } catch {
        DispatchQueue.main.async { result(nil) }
      }
    }
  }
}
