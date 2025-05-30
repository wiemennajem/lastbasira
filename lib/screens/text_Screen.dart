import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/vision_service.dart';
import '../main.dart'; // For accessing cameras

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  late CameraController _controller;
  late FlutterTts _flutterTts;
  bool _isCameraInitialized = false;
  String _detectedLanguage = "en-US";
  bool _isProcessing = false;
  bool _isCapturing = false;

  // Use current locale for instructions
  late String _instructionLanguage;

  // ML Kit text detector
  late TextRecognizer _textRecognizer;

  // Framing feedback variables
  Timer? _scanTimer;
  DateTime _lastFeedbackTime = DateTime.now();
  String _lastFeedbackMessage = "";
  bool _isTextInView = false;
  int _noTextCounter = 0;

  // Auto-capture variables
  bool _isWellPositioned = false;
  int _wellPositionedFrameCount = 0;
  final int _framesNeededForAutocapture = 1;

  // Enhanced positioning info
  double _horizontalOffsetPercent = 0;
  double _verticalOffsetPercent = 0;
  double _textSizeRatio = 0;

  // Flag to track if we're waiting for text to be read
  bool _isReadingText = false;

  Future<void> _speakFeedback(String message) async {
    // Use current locale for instructions/feedback
    String localizedMessage = message;
    final loc = AppLocalizations.of(context)!;

    // Replace "a lot" and "a bit" with localized strings
    localizedMessage = localizedMessage.replaceAll("a lot", loc.aLot);
    localizedMessage = localizedMessage.replaceAll("a bit", loc.aBit);

    await _flutterTts.setLanguage(_instructionLanguage);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(localizedMessage);
  }

  void _vibrateSuccess() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
  }

  void _vibratePattern(List<int> pattern) async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: pattern);
    }
  }

  // Method to handle quitting the camera screen
  void _quitCameraScreen() {
    // Stop all ongoing operations
    _scanTimer?.cancel();
    _flutterTts.stop();
    
    // Navigate back
    Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTextRecognizer();
    _initTts();
    _initCamera();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Set instruction language based on current locale
    Locale locale = Localizations.localeOf(context);
    switch (locale.languageCode) {
      case 'ar':
        _instructionLanguage = 'ar';
        break;
      case 'fr':
        _instructionLanguage = 'fr-FR';
        break;
      default:
        _instructionLanguage = 'en-US';
    }
  }

  void _initTextRecognizer() {
    _textRecognizer = TextRecognizer();
  }

  Future<void> _initTts() async {
    _flutterTts = FlutterTts();
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _initCamera() async {
    _controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _controller.initialize();
      setState(() => _isCameraInitialized = true);

      // Start periodic scanning instead of continuous stream processing
      _startPeriodicScanning();

      // Welcome message
      Future.delayed(const Duration(seconds: 1), () {
        _speakFeedback(AppLocalizations.of(context)!.cameraReadyMessage);
      });
    } catch (e) {
      print("Error initializing camera: $e");
    }
  }

  void _startPeriodicScanning() {
    // Cancel any existing timer
    _scanTimer?.cancel();

    // Create a new timer that captures frames periodically
    _scanTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      // Only process frames if we're not already capturing or reading text
      if (!_isCapturing && !_isReadingText && _isCameraInitialized) {
        _processCameraFrame();
      }
    });
  }

  Future<void> _processCameraFrame() async {
    if (_isCapturing || _isReadingText) return;

    // Mark as processing, but allow new frames to be processed even if previous processing is ongoing
    bool wasAlreadyProcessing = _isProcessing;
    if (!wasAlreadyProcessing) {
      setState(() {
        _isProcessing = true;
      });
    }

    try {
      final XFile imageFile = await _controller.takePicture();

      // Process with ML Kit
      final InputImage inputImage = InputImage.fromFilePath(imageFile.path);
      final RecognizedText recognizedText = await _textRecognizer.processImage(
        inputImage,
      );

      // Check if text is detected
      if (recognizedText.blocks.isEmpty) {
        _handleNoTextDetected();
      } else {
        _analyzeTextPosition(recognizedText);
      }
    } catch (e) {
      print("Error processing frame: $e");
    } finally {
      // Only update state if widget is still mounted and we weren't already processing
      if (mounted && !wasAlreadyProcessing) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _handleNoTextDetected() {
    setState(() {
      _isTextInView = false;
      _isWellPositioned = false;
      _wellPositionedFrameCount = 0;
    });

    _noTextCounter++;
    if (_noTextCounter >= 3) {
      _noTextCounter = 0;
      _speakFeedback(AppLocalizations.of(context)!.noTextFoundMessage);
    }
  }

  void _analyzeTextPosition(RecognizedText recognizedText) {
    // Reset counter since we found text
    _noTextCounter = 0;

    setState(() {
      _isTextInView = true;
    });

    // Find the largest text block
    TextBlock? largestBlock;
    double largestArea = 0;

    for (TextBlock block in recognizedText.blocks) {
      double area = block.boundingBox.width * block.boundingBox.height;
      if (area > largestArea) {
        largestArea = area;
        largestBlock = block;
      }
    }

    if (largestBlock == null) return;

    // Get device screen size for relative positioning
    final Size screenSize = MediaQuery.of(context).size;

    // Calculate position metrics
    final double textCenterX = largestBlock.boundingBox.center.dx;
    final double textCenterY = largestBlock.boundingBox.center.dy;
    final double screenCenterX = screenSize.width / 2;
    final double screenCenterY = screenSize.height / 2;

    // Calculate offsets as percentages of screen dimensions
    final double horizontalOffset =
        (textCenterX - screenCenterX) / screenCenterX;
    final double verticalOffset = (textCenterY - screenCenterY) / screenCenterY;

    // Calculate text size ratio
    final double textWidthRatio =
        largestBlock.boundingBox.width / screenSize.width;
    final double textHeightRatio =
        largestBlock.boundingBox.height / screenSize.height;

    // Update state with positioning data (for UI/debugging)
    setState(() {
      _horizontalOffsetPercent = horizontalOffset * 100;
      _verticalOffsetPercent = verticalOffset * 100;
      _textSizeRatio = textWidthRatio;
    });

    _provideFeedback(
      horizontalOffset,
      verticalOffset,
      textWidthRatio,
      textHeightRatio,
    );
  }

  void _provideFeedback(
    double horizontalOffset,
    double verticalOffset,
    double textWidthRatio,
    double textHeightRatio,
  ) {
    final loc = AppLocalizations.of(context)!;

    // Determine if the current time allows for new feedback
    final now = DateTime.now();
    if (now.difference(_lastFeedbackTime).inMilliseconds < 1500 &&
        _lastFeedbackMessage != "") {
      // Check for auto-capture condition
      _checkForAutoCapture(
        horizontalOffset,
        verticalOffset,
        textWidthRatio,
        textHeightRatio,
      );
      return;
    }

    String feedbackMessage = "";
    bool isPositionGood = false;

    // Enhanced position analysis with more precise guidance
    // Size check - relaxed thresholds slightly to match the larger box
    if (textWidthRatio < 0.15) {
      feedbackMessage = loc.textTooSmall;
    } else if (textWidthRatio > 0.9) {
      feedbackMessage = loc.textTooLarge;
    }
    // Horizontal position check
    else if (horizontalOffset.abs() > 0.35) {
      final String direction =
          horizontalOffset > 0 ? loc.directionRight : loc.directionLeft;
      final String magnitude =
          horizontalOffset.abs() > 0.5 ? loc.aLot : loc.aBit;
      feedbackMessage = loc.moveDirection(direction, magnitude);
    }
    // Vertical position check
    else if (verticalOffset.abs() > 0.35) {
      final String direction =
          verticalOffset > 0 ? loc.directionDown : loc.directionUp;
      final String magnitude = verticalOffset.abs() > 0.5 ? loc.aLot : loc.aBit;
      feedbackMessage = loc.moveDirection(direction, magnitude);
    } else if (horizontalOffset.abs() > 0.15 || verticalOffset.abs() > 0.15) {
      // Determine which direction needs more adjustment
      if (horizontalOffset.abs() > verticalOffset.abs()) {
        final String direction =
            horizontalOffset > 0 ? loc.directionRight : loc.directionLeft;
        feedbackMessage = loc.adjustSlightlyDirection(direction);
      } else {
        final String direction =
            verticalOffset > 0 ? loc.directionDown : loc.directionUp;
        feedbackMessage = loc.adjustSlightlyDirection(direction);
      }
    } else if (textWidthRatio >= 0.15 && textWidthRatio <= 0.9) {
      feedbackMessage = loc.textWellPositioned;
      isPositionGood = true;
      _vibrateSuccess();
    }

    // Update well-positioned status
    setState(() {
      _isWellPositioned = isPositionGood;
    });

    // Only speak feedback if:
    // 1. The message has changed OR this is the initial "well positioned" message
    // 2. We're not currently capturing or reading text
    if (feedbackMessage.isNotEmpty &&
        (feedbackMessage != _lastFeedbackMessage ||
            feedbackMessage == loc.textWellPositioned) &&
        !_isCapturing &&
        !_isReadingText) {
      _speakFeedback(feedbackMessage);
      _lastFeedbackMessage = feedbackMessage;
      _lastFeedbackTime = now;
    }
    // Check auto-capture condition
    _checkForAutoCapture(
      horizontalOffset,
      verticalOffset,
      textWidthRatio,
      textHeightRatio,
    );
  }

  void _checkForAutoCapture(
    double horizontalOffset,
    double verticalOffset,
    double textWidthRatio,
    double textHeightRatio,
  ) {
    // Define optimal positioning thresholds for auto-capture
    final bool isOptimalPosition =
        horizontalOffset.abs() <= 0.15 &&
        verticalOffset.abs() <= 0.15 &&
        textWidthRatio >= 0.15 &&
        textWidthRatio <= 0.9;

    if (isOptimalPosition) {
      _wellPositionedFrameCount++;

      // If we've had multiple consecutive frames with good positioning, auto-capture
      if (_wellPositionedFrameCount >= _framesNeededForAutocapture) {
        // Reset counter
        _wellPositionedFrameCount = 0;

        // Auto-capture if not already capturing or reading text
        if (!_isCapturing && !_isReadingText) {
          // Cancel the scan timer to stop further processing
          _scanTimer?.cancel();

          // Stop any ongoing speech
          _flutterTts.stop();

          // Vibrate to indicate auto-capture
          _vibratePattern([100, 100, 100]);

          // Wait a brief moment to let the user know we're in position
          Future.delayed(const Duration(milliseconds: 500), () {
            // Immediately capture the image without additional instructions
            _captureAndRecognizeText(
              isAutoCapture: true,
              skipInstructions: true,
            );
          });
        }
      }
    } else {
      // Reset counter if position is not optimal
      _wellPositionedFrameCount = 0;
    }
  }

  Future<void> _captureAndRecognizeText({
    bool isAutoCapture = false,
    bool skipInstructions = false,
  }) async {
    if (_isCapturing || _isReadingText) return;

    setState(() {
      _isCapturing = true;
      _isReadingText = true; // Set flag to prevent new instructions
    });

    try {
      // Cancel scanning timer during capture
      _scanTimer?.cancel();

      // Only announce capture if we're not skipping instructions
      if (!skipInstructions) {
        await _flutterTts.stop();
        // Ensure instructions are in English
        await _flutterTts.setLanguage(_instructionLanguage);
        if (isAutoCapture) {
          await _speakFeedback(
            AppLocalizations.of(context)!.autoCapturingImage,
          );
        } else {
          await _speakFeedback(AppLocalizations.of(context)!.capturingImage);
        }
      } else {
        // Even when skipping verbose instructions, give minimal confirmation
        _vibrateSuccess();
      }

      final XFile file = await _controller.takePicture();
      final bytes = await file.readAsBytes();

      // Show processing indicator
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Processing image...')));

      // Use Cloud Vision API for final text recognition
      final VisionResponse result = await recognizeTextWithLanguage(bytes);

      if (result.text != null && result.text!.isNotEmpty) {
        // Update detected language but keep instructions in English
        _detectedLanguage =
            result.language ?? _detectLanguageFromText(result.text!);

        // Speak the text in the detected language
        await _speakDetectedText(result.text!, _detectedLanguage);

        // Add a small delay after text is read before resuming scanning
        await Future.delayed(const Duration(seconds: 1));

        // Show detected language
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Detected language: ${_getLanguageName(_detectedLanguage)}',
            ),
          ),
        );
      } else {
        // Use English for this feedback
        await _flutterTts.setLanguage(_instructionLanguage);
        await _flutterTts.speak(
          AppLocalizations.of(context)!.noTextFoundMessage,
        );
      }
    } catch (e) {
      print("Error: $e");
      // Use English for error messages
      await _flutterTts.setLanguage(_instructionLanguage);
      await _flutterTts.speak(
        AppLocalizations.of(context)!.processingErrorMessage,
      );
    } finally {
      // Reset reading flag first
      setState(() {
        _isReadingText = false;
        _isCapturing = false;
        _isProcessing = false;
      });

      // Restart periodic scanning AFTER the text is read
      _startPeriodicScanning();

      // Reset counters
      _wellPositionedFrameCount = 0;
    }
  }

  String _getLanguageName(String languageCode) {
    switch (languageCode) {
      case "en-US":
        return "English";
      case "fr-FR":
        return "French";
      case "ar":
        return "Arabic";
      default:
        return languageCode;
    }
  }

  // New method to speak detected text in its own language
  Future<void> _speakDetectedText(String text, String languageCode) async {
    // Create a completer to track when speech is done
    final Completer<void> completer = Completer<void>();

    // Set up completion listener
    _flutterTts.setCompletionHandler(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    // Use the detected language for reading the text
    await _flutterTts.setLanguage(languageCode);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(text);

    // Wait for speech to complete
    return completer.future;
  }

  // Renamed the _speak method to make its purpose clearer
  Future<void> _speak(String text, String languageCode) async {
    // For backward compatibility - this method is now deprecated
    return _speakDetectedText(text, languageCode);
  }

  String _detectLanguageFromText(String text) {
    // Enhanced language detection using common patterns and character frequency

    // Check for Arabic script
    if (RegExp(
      r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
    ).hasMatch(text)) {
      return "ar";
    }

    // Count French-specific characters
    int frenchCount = 0;
    frenchCount +=
        RegExp(r'[éèêëàâäôöùûüÿçÉÈÊËÀÂÄÔÖÙÛÜŸÇ]').allMatches(text).length * 2;
    frenchCount +=
        RegExp(
          r'\b(le|la|les|du|des|un|une|est|sont|et|ou|où|avec|pour|dans|par|sur|en|au|aux|ce|cette|ces|mon|ton|son|nous|vous|ils|elles|qui|que|quoi|dont|car)\b',
          caseSensitive: false,
        ).allMatches(text).length *
        3;

    // Count English-specific patterns
    int englishCount = 0;
    englishCount +=
        RegExp(
          r'\b(the|of|and|to|in|is|are|was|were|with|for|on|at|by|as|this|that|these|those|my|your|his|her|our|their|which|who|whom|where|when|why|how)\b',
          caseSensitive: false,
        ).allMatches(text).length *
        2;
    englishCount +=
        RegExp(
          r'[wkjy]',
        ).allMatches(text).length; // Characters more common in English

    // Make the decision based on pattern counts
    if (frenchCount > englishCount) {
      return "fr-FR";
    } else {
      return "en-US";
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes to properly manage camera resources
    if (!_controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _scanTimer?.cancel();
      _controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    _controller.dispose();
    _flutterTts.stop();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Text Reader App'),
        backgroundColor: Colors.black.withOpacity(0.7),
        actions: [
          // Help button
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              // Speak help instructions in current locale
              _flutterTts.setLanguage(_instructionLanguage);
              _flutterTts.speak(AppLocalizations.of(context)!.helpInstructions);
            },
          ),
        ],
      ),
      body: _isCameraInitialized
          ? GestureDetector(
              // Add swipe gesture detection
              onPanUpdate: (details) {
                // Detect swipe gestures in any direction
                if (details.delta.dx.abs() > 10 || details.delta.dy.abs() > 10) {
                  // Only quit if not currently processing important tasks
                  if (!_isCapturing && !_isReadingText) {
                    _quitCameraScreen();
                  }
                }
              },
              child: Stack(
                children: [
                  CameraPreview(_controller),
                  // Language indicator
                  Positioned(
                    top: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Language: ${_getLanguageName(_detectedLanguage)}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  // Text detection indicator
                  Positioned(
                    top: 20,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _isTextInView
                            ? (_isWellPositioned
                                ? Colors.green.withOpacity(0.7)
                                : Colors.orange.withOpacity(0.7))
                            : Colors.red.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _isTextInView
                            ? (_isWellPositioned
                                ? 'Well positioned'
                                : 'Text detected')
                            : 'No text detected',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  // Auto-capture progress indicator (when position is good)
                  if (_isWellPositioned && _wellPositionedFrameCount > 0)
                    Positioned(
                      top: 60,
                      left: 20,
                      child: Container(
                        width: 110,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Auto-capture: ${(_wellPositionedFrameCount / _framesNeededForAutocapture * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Status indicator
                  Positioned(
                    top: _isWellPositioned ? 100 : 60,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _isCapturing
                            ? 'Capturing...'
                            : (_isReadingText
                                ? 'Reading text...'
                                : (_isProcessing ? 'Analyzing...' : 'Ready')),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                  // Position debugging data (optional)
                  Positioned(
                    top: _isWellPositioned ? 140 : 100,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'H: ${_horizontalOffsetPercent.toStringAsFixed(1)}% V: ${_verticalOffsetPercent.toStringAsFixed(1)}% Size: ${(_textSizeRatio * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  // Target frame indicator (helps users understand desired positioning)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          width: MediaQuery.of(context).size.width *
                              0.85, // Larger target width (increased from 0.7)
                          height: MediaQuery.of(context).size.height *
                              0.5, // Larger target height (increased from 0.4)
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _isWellPositioned
                                  ? Colors.green.withOpacity(0.7)
                                  : Colors.white.withOpacity(0.3),
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Camera button with double-tap for accessibility
                  Positioned(
                    bottom: 40,
                    left: MediaQuery.of(context).size.width / 2 - 30,
                    child: GestureDetector(
                      onDoubleTap: (_isCapturing || _isReadingText)
                          ? null
                          : () => _captureAndRecognizeText(),
                      child: FloatingActionButton(
                        onPressed: (_isCapturing || _isReadingText)
                            ? null
                            : () => _captureAndRecognizeText(),
                        backgroundColor: (_isCapturing || _isReadingText)
                            ? Colors.grey
                            : Colors.blue,
                        child: _isCapturing
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Icon(Icons.camera),
                      ),
                    ),
                  ),
                  // Instructions with swipe hint
                  Positioned(
                    bottom: 100,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _isReadingText
                                  ? AppLocalizations.of(context)!
                                      .readingDetectedText
                                  : (_isWellPositioned
                                      ? AppLocalizations.of(context)!
                                          .autoCapturingInProgress
                                      : AppLocalizations.of(context)!
                                          .alignTextWithFrame),
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Swipe to quit',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}