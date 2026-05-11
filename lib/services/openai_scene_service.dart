import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const String openAiApiKey = "YOUR_API_KEY_HERE";

/// Exception thrown when the scene description API call fails.
class SceneDescriptionException implements Exception {
  final String message;
  final int? statusCode;

  const SceneDescriptionException(this.message, {this.statusCode});

  @override
  String toString() => 'SceneDescriptionException: $message';
}

/// Service that sends a camera image to GPT-4o and returns a text description of the scene.
///
/// Usage:
/// ```dart
/// final service = SceneDescriptionService(apiKey: 'your-openai-api-key');
/// final description = await service.describeScene(imageFile);
/// ```
///
/// Required pubspec.yaml dependency:
/// ```yaml
/// dependencies:
///   http: ^1.2.0
/// ```
class SceneDescriptionService {
  static const String _apiUrl = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o';

  static const String _prompt =
      'Describe this scene clearly and concisely. '
      'Focus on what is happening, the setting, and any notable objects or people present. '
      'Write 1–3 sentences.';

  final String apiKey;
  final http.Client _client;

  SceneDescriptionService({
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Sends [imageFile] to GPT-4o and returns a plain-text scene description.
  ///
  /// Pass a [customPrompt] to override the default scene-description prompt —
  /// useful for object-detection queries like "Is there a chair visible?".
  ///
  /// Throws [SceneDescriptionException] if the API call fails or returns an error.
  Future<String> describeScene(File imageFile, {String? customPrompt}) async {
    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);
    final mediaType = _mediaTypeFromPath(imageFile.path);

    final response = await _client.post(
      Uri.parse(_apiUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': _model,
        'max_tokens': 512,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:$mediaType;base64,$base64Image',
                },
              },
              {
                'type': 'text',
                'text': customPrompt ?? _prompt,
              },
            ],
          },
        ],
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>;
      if (choices.isEmpty) {
        throw const SceneDescriptionException('Empty response from API');
      }
      return (choices.first as Map<String, dynamic>)['message']['content'] as String;
    }

    final error = jsonDecode(response.body) as Map<String, dynamic>;
    final errorMessage =
        (error['error'] as Map<String, dynamic>?)?['message'] ??
        'Unknown error';
    throw SceneDescriptionException(
      errorMessage,
      statusCode: response.statusCode,
    );
  }

  /// Returns the MIME type based on the file extension.
  /// Defaults to image/jpeg, which is standard for camera captures.
  String _mediaTypeFromPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  /// Call this when the service is no longer needed to free HTTP resources.
  void dispose() => _client.close();
}
