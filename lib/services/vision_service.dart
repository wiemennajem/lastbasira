import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:googleapis/vision/v1.dart' as vision;
import 'package:googleapis_auth/auth_io.dart';

class VisionResponse {
  final String? text;
  final String? language;

  VisionResponse({this.text, this.language});
}

Future<VisionResponse> recognizeTextWithLanguage(Uint8List imageBytes) async {
  final jsonCredentials = await rootBundle.loadString(
    'assets/credentials/visionkey.json',
  );
  final credentials = ServiceAccountCredentials.fromJson(
    jsonDecode(jsonCredentials),
  );

  final scopes = [vision.VisionApi.cloudVisionScope];

  final client = await clientViaServiceAccount(credentials, scopes);

  try {
    final visionApi = vision.VisionApi(client);
    final base64Image = base64Encode(imageBytes);

    final request = vision.BatchAnnotateImagesRequest(
      requests: [
        vision.AnnotateImageRequest(
          image: vision.Image(content: base64Image),
          features: [
            vision.Feature(type: 'TEXT_DETECTION'),
            vision.Feature(type: 'DOCUMENT_TEXT_DETECTION'),
          ],
          imageContext: vision.ImageContext(
            languageHints: ['en', 'fr', 'ar'], // Specify languages to look for
          ),
        ),
      ],
    );

    final response = await visionApi.images.annotate(request);
    final textAnnotation = response.responses?.first.fullTextAnnotation;
    final text = textAnnotation?.text;

    // Try to extract language from Vision API response
    String? detectedLanguage;
    try {
      // First try to get language from text annotations
      final textDetections = response.responses?.first.textAnnotations;
      if (textDetections != null &&
          textDetections.isNotEmpty &&
          textDetections.first.locale != null) {
        detectedLanguage = _mapLanguageCode(textDetections.first.locale!);
      }
    } catch (e) {
      print('Error extracting language from Vision API: $e');
    }

    return VisionResponse(text: text, language: detectedLanguage);
  } catch (e) {
    print('Vision API error: $e');
    return VisionResponse(text: null, language: null);
  } finally {
    client.close();
  }
}

// Helper to map Google's language codes to TTS compatible codes
String _mapLanguageCode(String googleCode) {
  switch (googleCode) {
    case 'en':
      return 'en-US';
    case 'fr':
      return 'fr-FR';
    case 'ar':
      return 'ar';
    default:
      return 'en-US';
  }
}
