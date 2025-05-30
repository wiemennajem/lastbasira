import 'dart:core';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../utils/money_translations.dart';

late List<CameraDescription> cameras;
Offset _dragPosition = const Offset(65, 30);

class MoneyRecognitionScreen extends StatefulWidget {
  final List<CameraDescription> camerass;
  
  const MoneyRecognitionScreen({
    super.key, 
    required this.camerass,
  });

  @override
  State<MoneyRecognitionScreen> createState() => _MoneyRecognitionScreenState();
}

class _MoneyRecognitionScreenState extends State<MoneyRecognitionScreen> {
  late CameraController controller;
  late FlutterVision vision;
  late FlutterTts flutterTts;
  late List<Map<String, dynamic>> yoloResults;

  CameraImage? cameraImage;
  bool isLoaded = false;
  bool isDetecting = false;
  bool hasSpokenInstructions = false; // Track if instructions have been spoken
  Set<String> spokenTags = {};
  String currentLanguage = 'en'; // Default fallback

  // Voice instructions in different languages
  Map<String, String> voiceInstructions = {
    'en': 'Show each currency one at a time.',
    'fr': 'montrez chaque devise une à la fois" :',
    'ar': 'اعرض كل عملة على حدة.',
  };

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    vision = FlutterVision();

    final backCamera = widget.camerass.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.camerass[0],
    );

    controller = CameraController(backCamera, ResolutionPreset.low);
    await controller.initialize();
    await loadYoloModel();

    // Initialize TTS with proper configuration
    flutterTts = FlutterTts();
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
    
    // Set language based on device locale
    final localeCode = Localizations.localeOf(context).languageCode;
    currentLanguage = localeCode;
    await _setTtsLanguage(localeCode);

    setState(() {
      isLoaded = true;
      isDetecting = true; // Start detecting immediately
      yoloResults = [];
    });

    await startDetection();
  }

  // Improved TTS language configuration method
  Future<void> _setTtsLanguage(String languageCode) async {
    try {
      switch (languageCode) {
        case 'fr':
          await flutterTts.setLanguage("fr-FR");
          break;
        case 'ar':
          await flutterTts.setLanguage("ar-SA");
          break;
        default:
          await flutterTts.setLanguage("en-US");
      }
      
      // Reapply other TTS settings after language change
      await flutterTts.setSpeechRate(0.5);
      await flutterTts.setVolume(1.0);
      await flutterTts.setPitch(1.0);
      
      print('TTS language set to: $languageCode');
    } catch (e) {
      print('Error setting TTS language: $e');
    }
  }

  // Speak voice instructions in the current language
  Future<void> _speakVoiceInstructions() async {
    if (!hasSpokenInstructions) {
      final instruction = voiceInstructions[currentLanguage] ?? voiceInstructions['en']!;
      
      // Add a small delay to ensure TTS is properly initialized
      await Future.delayed(const Duration(milliseconds: 300));
      await flutterTts.speak(instruction);
      
      setState(() {
        hasSpokenInstructions = true;
      });
      
      print('Voice instruction spoken: $instruction');
    }
  }

  // Remove the old configureTtsForLanguage method and replace with calls to _setTtsLanguage
  Future<void> changeLanguage(String newLanguage) async {
    setState(() {
      currentLanguage = newLanguage;
      spokenTags.clear(); // Clear spoken tags when language changes
      hasSpokenInstructions = false; // Reset instructions flag when language changes
    });
    
    // Use the improved TTS language setting method
    await _setTtsLanguage(newLanguage);
    
    // Speak instructions in new language if detection is active
    if (isDetecting) {
      await _speakVoiceInstructions();
    }
  }

  String getTranslatedLabel(String originalTag) {
    // Check if translation exists for this tag
    if (moneyTranslations.containsKey(originalTag)) {
      return moneyTranslations[originalTag]![currentLanguage] ?? originalTag.replaceAll('_', ' ');
    }
    // Fallback to original tag with underscore replacement
    return originalTag.replaceAll('_', ' ');
  }

  @override
  void dispose() {
    controller.dispose();
    vision.closeYoloModel();
    flutterTts.stop();
    super.dispose();
  }

  Future<void> loadYoloModel() async {
    await vision.loadYoloModel(
      labels: 'assets/models/moneylabels.txt',
      modelPath: 'assets/models/best_float16.tflite',
      modelVersion: "yolov8",
      quantization: false,
      numThreads: 1,
      useGpu: false,
    );
  }

  Future<void> yoloOnFrame(CameraImage cameraImage) async {
    final result = await vision.yoloOnFrame(
      bytesList: cameraImage.planes.map((plane) => plane.bytes).toList(),
      imageHeight: cameraImage.height,
      imageWidth: cameraImage.width,
      iouThreshold: 0.2,
      confThreshold: 0.2,
      classThreshold: 0.2,
    );

    if (result.isNotEmpty) {
      setState(() {
        yoloResults = result;
      });

      // Speak detected currency in the selected language
      for (var item in result) {
        final tag = item['tag'];
        if (!spokenTags.contains(tag)) {
          spokenTags.add(tag);
          final translatedText = getTranslatedLabel(tag);
          
          // Add a small delay to ensure TTS language is properly set
          await Future.delayed(const Duration(milliseconds: 100));
          await flutterTts.speak(translatedText);
        }
      }
    }
  }

  Future<void> startDetection() async {
    setState(() {
      isDetecting = true;
    });

    if (controller.value.isStreamingImages) return;

    // Speak voice instructions when detection starts
    await _speakVoiceInstructions();

    await controller.startImageStream((image) async {
      if (isDetecting) {
        cameraImage = image;
        yoloOnFrame(image);
      }
    });
  }

  // Function to speak currently detected currencies when screen is tapped
  Future<void> _speakCurrentDetections() async {
    if (yoloResults.isNotEmpty) {
      // Stop any current speech first
      await flutterTts.stop();
      
      for (var result in yoloResults) {
        final tag = result['tag'];
        final translatedText = getTranslatedLabel(tag);
        
        // Add a small delay between speaking multiple currencies
        await Future.delayed(const Duration(milliseconds: 200));
        await flutterTts.speak(translatedText);
      }
    } else {
      // If no detections, speak a message in the current language
      String noDetectionMessage;
      switch (currentLanguage) {
        case 'fr':
          noDetectionMessage = 'Aucune devise détectée';
          break;
        case 'ar':
          noDetectionMessage = 'لم يتم اكتشاف أي عملة';
          break;
        default:
          noDetectionMessage = 'No currency detected';
      }
      await flutterTts.speak(noDetectionMessage);
    }
  }

  List<Widget> displayBoxesAroundRecognizedObjects(Size screen) {
    if (yoloResults.isEmpty || cameraImage == null) return [];

    double factorX = screen.width / cameraImage!.height;
    double factorY = screen.height / cameraImage!.width;
    Color colorPick = const Color.fromARGB(255, 0, 140, 255);

    return yoloResults.map((result) {
      double objectX = result["box"][0] * factorX;
      double objectY = result["box"][1] * factorY;
      double objectWidth = (result["box"][2] - result["box"][0]) * factorX;
      double objectHeight = (result["box"][3] - result["box"][1]) * factorY;

      final translatedLabel = getTranslatedLabel(result['tag']);

      return Positioned(
        left: objectX,
        top: objectY,
        width: objectWidth,
        height: objectHeight,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(10.0)),
            border: Border.all(color: Colors.green, width: 2.0),
          ),
          child: Text(
            "$translatedLabel ${(result['box'][4] * 100).toStringAsFixed(1)}%",
            style: TextStyle(
              background: Paint()..color = colorPick,
              color: Colors.white,
              fontSize: 18.0,
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget buildLiveDetectionBox() {
    return Container(); // Return empty container - effectively removes the box
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;

    return Scaffold(
      body: isLoaded ? GestureDetector(
        // Add swipe gesture to quit the screen
        onPanEnd: (details) {
          // Check for swipe velocity and direction
          if (details.velocity.pixelsPerSecond.dx.abs() > 500 || 
              details.velocity.pixelsPerSecond.dy.abs() > 500) {
            Navigator.pop(context);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: _speakCurrentDetections,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: CameraPreview(controller),
              ),
            ),
            ...displayBoxesAroundRecognizedObjects(size),
            buildLiveDetectionBox(),
            // Back button positioned over the camera
            Positioned(
              top: 50,
              left: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ],
        ),
      ) : const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}