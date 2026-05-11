# NaviGlasses

A voice-guided iOS accessibility app for visually impaired users. All four features work fully on-device — no internet required except Scene Description (which uses OpenAI GPT-4o).

---

## Features

| Feature | What it does | Needs internet? |
|---|---|---|
| **Bill Scanner** | Points camera at a Jordanian banknote and speaks the denomination | No |
| **Text Reader** | Points camera at any printed text and reads it aloud | No |
| **Vision Assist** | Say the name of any object; the app tells you if it is in front of you | No |
| **Scene Description** | Takes a photo and gives a full spoken description of the scene | Yes (OpenAI) |

Every screen is controlled entirely by voice and touch. Double-tap anywhere to go back to the main menu.

---

## Requirements

- **Mac** with Xcode 15 or later
- **Flutter SDK** 3.11 or later — [install guide](https://docs.flutter.dev/get-started/install/macos)
- **iPhone** running iOS 15 or later (the app is iOS-only)
- A paid or free Apple Developer account (needed to sign the app for your device)

---

## Setup

### 1. Install Flutter dependencies

```bash
cd my_first_app
flutter pub get
```

### 2. Add your OpenAI API key (for Scene Description only)

Open `lib/config.dart` and replace the key with your own:

```dart
const String kOpenAiApiKey = 'sk-...your-key-here...';
```

If you do not have an OpenAI key, the other three features still work fine without it.

### 3. Connect your iPhone and trust the Mac

1. Plug in your iPhone via USB.
2. On the phone tap **Trust This Computer**.
3. In Xcode open `ios/Runner.xcworkspace`, select your device at the top, and set the **Team** under *Signing & Capabilities* to your Apple ID.

### 4. Run the app

```bash
flutter run --release
```

Flutter will build, sign, and install the app on your phone automatically. The first build takes a few minutes.

---

## Project structure

```
lib/
  main.dart                        App entry point
  config.dart                      API keys
  theme/app_theme.dart             Colours and text styles
  screens/
    intro_screen.dart              Welcome / onboarding screen
    home_screen.dart               Main menu
    banknote_screen.dart           Bill Scanner
    ocr_screen.dart                Text Reader
    scene_description_screen.dart  Vision Assist (on-device TFLite)
    openai_scene_screen.dart       Scene Description (GPT-4o)
  services/
    voice_service.dart             Shared TTS + STT wrapper
    vision_assist_service.dart     On-device object detection (TFLite)

assets/
  jordanian_banknote.tflite        Banknote classifier model
  ocr_model.tflite                 OCR helper model
  vision_assist.tflite             16-object custom detection model
  vision_assist_labels.txt         Labels for the custom model
  yolov8n.tflite                   YOLOv8n COCO-80 fallback model
  yolov8n_labels.txt               Labels for the COCO model
```

---

## Permissions

The app requests these permissions on first launch:

- **Camera** — used by Bill Scanner, Text Reader, and Vision Assist
- **Microphone** — used for voice commands
- **Speech Recognition** — used to hear what object you are looking for

---

## Troubleshooting

**Build fails with signing error**
Open `ios/Runner.xcworkspace` in Xcode, go to *Signing & Capabilities*, and make sure a valid Team is selected.

**"flutter" command not found**
Make sure Flutter is on your PATH. Add this line to `~/.zshrc` (replace the path with where you installed Flutter):
```bash
export PATH="$PATH:$HOME/flutter/bin"
```

**App installs but crashes immediately**
Run without `--release` to see error logs:
```bash
flutter run
```

**Scene Description says "Something went wrong"**
Check that `lib/config.dart` has a valid OpenAI API key with GPT-4o access.

**Vision Assist does not hear my voice**
Speak clearly after the chime. The mic opens roughly half a second after the app finishes talking. Background noise is filtered automatically; short words (under 2 characters) and numbers are ignored.
