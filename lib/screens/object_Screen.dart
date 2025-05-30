import 'dart:core';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
// Using both speech recognition plugins for fallback capability
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_speech/flutter_speech.dart';
import '../utils/label_translations.dart';



late List<CameraDescription> cameras;

// Define an enum for app operation modes
enum AppMode { objectDetection, voiceSearch, initializing }

class YoloVideo extends StatefulWidget {
  final List<CameraDescription> camerass;
  const YoloVideo({super.key, required this.camerass});

  @override
  State<YoloVideo> createState() => _YoloVideoState();
}

class _YoloVideoState extends State<YoloVideo> {
  late CameraController controller;
  late FlutterVision vision;
  late FlutterTts flutterTts;
  late List<Map<String, dynamic>> yoloResults;

  // Primary speech recognition (flutter_speech)
  late SpeechRecognition _primarySpeech;
  bool _primarySpeechAvailable = false;

  // Backup speech recognition (speech_to_text)
  late stt.SpeechToText _backupSpeech;
  bool _backupSpeechAvailable = false;

  // App mode management
  AppMode _currentMode = AppMode.initializing;

  // Speech recognition state
  bool _isListening = false;
  String _searchTerm = '';
  String _lastSearchFeedback = '';
  bool _showSearchFeedback = false;
  bool _processingSearch = false;
  bool _micPermissionGranted = false;
  int _recognitionFailureCount = 0;
  bool _useBackupRecognition = false;

  // Double tap detection
  bool _hasPlayedInitialInstructions = false;
  bool _instructionsCompleted = false;
  DateTime? _lastTapTime;
 
  CameraImage? cameraImage;
  bool isLoaded = false;
  double confidenceThreshold = 0.4;
  Set<String> spokenTags = {};
  String currentLanguage = 'en';

  // Retry mechanism
  Timer? _retryTimer;
  int _maxRetries = 3;
  int _currentRetry = 0;

  // Stream subscription for camera images
  StreamSubscription<CameraImage>? _cameraStreamSubscription;

  // Common object synonyms and variations for better matching
  final Map<String, List<String>> _objectSynonyms = {
    'glasses': ['eyeglasses', 'spectacles', 'glass', 'eyewear', 'sunglasses'],
    'phone': ['smartphone', 'mobile', 'cellphone', 'cell', 'iphone', 'android'],
    'laptop': ['computer', 'notebook', 'pc', 'macbook'],
    'cup': ['mug', 'glass', 'tumbler'],
    'bottle': ['flask', 'container', 'water bottle'],
    'chair': ['seat', 'stool'],
    'person': ['human', 'man', 'woman', 'people', 'individual'],
    'car': ['vehicle', 'automobile', 'auto'],
    'book': ['novel', 'textbook', 'magazine', 'reading material'],
    'tv': ['television', 'monitor', 'screen', 'display'],
  };

  // Minimum similarity score for a match (0.0 to 1.0)
  final double _minSimilarityScore = 0.7;

  // Minimum confidence for object detection
  final double _minDetectionConfidence = 0.5;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    try {
      // Initialize vision
      vision = FlutterVision();

      // Initialize camera
      final backCamera = widget.camerass.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => widget.camerass[0],
      );

      controller = CameraController(backCamera, ResolutionPreset.medium);
      await controller.initialize();

      // Load YOLO model
      await loadYoloModel();

      // Initialize TTS
      flutterTts = FlutterTts();
      await flutterTts.setSpeechRate(0.5);
      await flutterTts.setVolume(1.0);
      await flutterTts.setPitch(1.0);

      // Set up TTS completion listener
      flutterTts.setCompletionHandler(() {
        if (!_instructionsCompleted && _hasPlayedInitialInstructions) {
          setState(() {
            _instructionsCompleted = true;
          });
          // Start detection only after instructions are complete
          _setMode(AppMode.objectDetection);
        }
      });

      // Set language
      final localeCode = Localizations.localeOf(context).languageCode;
      currentLanguage = localeCode;
      await _setTtsLanguage(localeCode);

      // Check microphone permissions and initialize speech recognition
      await _checkPermissionsAndInitSpeech();

      setState(() {
        isLoaded = true;
        yoloResults = [];
      });

      // Play initial instructions after a short delay to ensure TTS is ready
      Future.delayed(const Duration(milliseconds: 1500), () {
        _playInitialInstructions();
      });
    } catch (e) {
      print('Initialization error: $e');
      _showErrorMessage('Error initializing app: $e');
    }
  }

  // Check microphone permissions explicitly
  Future<void> _checkPermissionsAndInitSpeech() async {
    try {
      // Request microphone permission explicitly
      final status = await Permission.microphone.request();
      _micPermissionGranted = status.isGranted;

      if (_micPermissionGranted) {
        // Initialize both speech recognition systems
        await _initPrimarySpeech();
        await _initBackupSpeech();

        // Decide which one to use based on availability
        _useBackupRecognition =
            !_primarySpeechAvailable || _recognitionFailureCount > 2;

        if (!_primarySpeechAvailable && !_backupSpeechAvailable) {
          _showErrorMessage(
            'Speech recognition is not available on this device',
          );
        }
      } else {
        _showErrorMessage('Microphone permission is required for voice search');
      }
    } catch (e) {
      print('Error checking permissions: $e');
      _showErrorMessage('Error initializing speech recognition');
    }
  }

  // Play initial voice instructions
  Future<void> _playInitialInstructions() async {
    if (_hasPlayedInitialInstructions) return;

    String instructions = _getLocalizedInstructions();
    await flutterTts.speak(instructions);

    setState(() {
      _hasPlayedInitialInstructions = true;
    });

    // If for some reason the completion handler doesn't fire,
    // start detection after a reasonable timeout
    Future.delayed(const Duration(seconds: 5), () {
      if (!_instructionsCompleted && mounted) {
        setState(() {
          _instructionsCompleted = true;
        });
        _setMode(AppMode.objectDetection);
      }
    });
  }

  // Get localized instructions for double-tap
  String _getLocalizedInstructions() {
    switch (currentLanguage) {
      case 'fr':
        return 'Appuyez deux fois sur l\'écran pour activer la recherche vocale.';
      case 'ar':
        return 'انقر مرتين على الشاشة  لتفعيل البحث الصوتي.';
      default:
        return 'Double tap anywhere on the screen to activate voice search.';
    }
  }

  // Initialize primary speech recognition (flutter_speech)
  Future<void> _initPrimarySpeech() async {
    _primarySpeech = SpeechRecognition();

    try {
      _primarySpeech.setAvailabilityHandler((bool result) {
        setState(() => _primarySpeechAvailable = result);
        print('Primary speech recognition availability: $result');
      });

      _primarySpeech.setRecognitionStartedHandler(() {
        setState(() => _isListening = true);
        print('Primary speech recognition started');
      });

      _primarySpeech.setRecognitionResultHandler((String text) {
        print('Primary speech recognition partial result: $text');
        if (text.isNotEmpty) {
          setState(() => _searchTerm = text);
        }
      });

      _primarySpeech.setRecognitionCompleteHandler((String text) {
        print('Primary speech recognition complete: $text');
        setState(() {
          _isListening = false;
          if (text.isNotEmpty) {
            _searchTerm = text;
            _processingSearch = true;
            // Reset failure count on success
            _recognitionFailureCount = 0;
          } else {
            // Increment failure count on empty result
            _recognitionFailureCount++;
          }
        });

        if (_searchTerm.isNotEmpty) {
          _extractObjectAndSearch(_searchTerm);
        } else {
          _showErrorMessage('No speech detected. Please try again.');
        }
      });

      _primarySpeech.setErrorHandler(() {
        print('Primary speech recognition error');
        setState(() {
          _isListening = false;
          // Increment failure count on error
          _recognitionFailureCount++;
        });

        // Switch to backup if primary fails repeatedly
        if (_recognitionFailureCount > 2) {
          _useBackupRecognition = true;
          _showErrorMessage('Switching to backup speech recognition');
        } else {
          _showErrorMessage('Speech recognition error. Please try again.');
        }
      });

      // Initialize the speech recognition
      bool available = await _primarySpeech.activate(_getSpeechLocale());
      setState(() => _primarySpeechAvailable = available);
      print('Primary speech recognition activated: $available');
    } catch (e) {
      print('Error initializing primary speech recognition: $e');
      setState(() => _primarySpeechAvailable = false);
    }
  }

  // Initialize backup speech recognition (speech_to_text)
  Future<void> _initBackupSpeech() async {
    _backupSpeech = stt.SpeechToText();

    try {
      bool available = await _backupSpeech.initialize(
        onStatus: (status) {
          print('Backup speech recognition status: $status');
          if (status == 'done' || status == 'notListening') {
            setState(() => _isListening = false);

            // If we have a search term but no processing has happened,
            // try to process it now as a fallback
            if (_searchTerm.isNotEmpty && !_processingSearch) {
              _extractObjectAndSearch(_searchTerm);
            }
          }
        },
        onError: (errorNotification) {
          print(
            'Backup speech recognition error: ${errorNotification.errorMsg}',
          );
          setState(() {
            _isListening = false;
            // Increment failure count on error
            _recognitionFailureCount++;
          });

          _showErrorMessage('Speech recognition error. Please try again.');
        },
        debugLogging: true,
      );

      setState(() => _backupSpeechAvailable = available);
      print('Backup speech recognition initialized: $available');
    } catch (e) {
      print('Error initializing backup speech recognition: $e');
      setState(() => _backupSpeechAvailable = false);
    }
  }

  // Show error message to user
  void _showErrorMessage(String message) {
    print('ERROR: $message'); // Log error for debugging

    setState(() {
      _lastSearchFeedback = message;
      _showSearchFeedback = true;
    });

    // Hide message after a delay
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _showSearchFeedback = false;
        });
      }
    });
  }

  // Set the current app mode and handle mode transitions
  Future<void> _setMode(AppMode newMode) async {
    // Don't change mode if it's the same
    if (_currentMode == newMode) return;

    print('Changing mode from $_currentMode to $newMode');

    // Handle cleanup of previous mode
    switch (_currentMode) {
      case AppMode.objectDetection:
        await _stopDetection();
        break;
      case AppMode.voiceSearch:
        await _stopListening();
        break;
      case AppMode.initializing:
        // No cleanup needed
        break;
    }

    // Set new mode
    setState(() {
      _currentMode = newMode;
    });

    // Initialize new mode
    switch (newMode) {
      case AppMode.objectDetection:
        await _startDetection();
        break;
      case AppMode.voiceSearch:
        await _startListening();
        break;
      case AppMode.initializing:
        // No initialization needed
        break;
    }
  }

  // Start listening for speech input with improved reliability
  Future<void> _startListening() async {
    // Cancel any existing retry timer
    _retryTimer?.cancel();
    _currentRetry = 0;

    // Check if microphone permission is granted
    if (!_micPermissionGranted) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _showErrorMessage('Microphone permission is required for voice search');
        return;
      }
      _micPermissionGranted = true;
    }

    // Reset state and prepare for new listening session
    setState(() {
      _isListening = true;
      _showSearchFeedback = false;
      _searchTerm = '';
      _processingSearch = false;
    });

    // Provide audio feedback that listening has started
    String listeningPrompt = _getLocalizedListeningPrompt();
    await flutterTts.speak(listeningPrompt);

    // Wait a moment for TTS to complete before starting listening
    await Future.delayed(const Duration(milliseconds: 1000));

    // Stop any ongoing TTS to avoid conflicts
    await flutterTts.stop();

    // Try to start speech recognition
    await _startSpeechRecognition();
  }

  // Start speech recognition with fallback and retry mechanisms
  Future<void> _startSpeechRecognition() async {
    try {
      bool started = false;

      // Decide which speech recognition to use
      if (_useBackupRecognition && _backupSpeechAvailable) {
        // Use backup speech recognition (speech_to_text)
        print('Using backup speech recognition');
        started = await _startBackupSpeechRecognition();
      } else if (_primarySpeechAvailable) {
        // Use primary speech recognition (flutter_speech)
        print('Using primary speech recognition');
        started = await _startPrimarySpeechRecognition();
      } else if (_backupSpeechAvailable) {
        // Fallback to backup if primary is not available
        print(
          'Primary not available, falling back to backup speech recognition',
        );
        _useBackupRecognition = true;
        started = await _startBackupSpeechRecognition();
      }

      if (!started) {
        print('Failed to start speech recognition');

        // Try the other recognition system if this one failed
        if (_useBackupRecognition && _primarySpeechAvailable) {
          _useBackupRecognition = false;
          return _startSpeechRecognition();
        } else if (!_useBackupRecognition && _backupSpeechAvailable) {
          _useBackupRecognition = true;
          return _startSpeechRecognition();
        }

        // If we've tried both or only one is available, show error
        _showErrorMessage(
          'Failed to start speech recognition. Please try again.',
        );
        setState(() => _isListening = false);

        // Return to object detection mode
        _setMode(AppMode.objectDetection);
      }

      // Set a timeout to ensure we don't get stuck in listening mode
      _setListeningTimeout();
    } catch (e) {
      print('Error starting speech recognition: $e');
      _showErrorMessage('Error: $e');
      setState(() => _isListening = false);

      // Try to retry if we haven't exceeded max retries
      _scheduleRetry();
    }
  }

  // Start primary speech recognition (flutter_speech)
  Future<bool> _startPrimarySpeechRecognition() async {
    try {
      // Stop any ongoing listening
      _primarySpeech.cancel();
      await Future.delayed(const Duration(milliseconds: 300));

      // Start listening without parameters as flutter_speech listen() takes no arguments
      return await _primarySpeech.listen();
    } catch (e) {
      print('Error starting primary speech recognition: $e');
      return false;
    }
  }

  // Start backup speech recognition (speech_to_text)
  Future<bool> _startBackupSpeechRecognition() async {
    try {
      // Stop any ongoing listening
      await _backupSpeech.stop();
      await Future.delayed(const Duration(milliseconds: 300));

      // Start listening with more robust settings
      return await _backupSpeech.listen(
        onResult: (result) {
          print('Backup speech result: ${result.recognizedWords}');

          if (result.recognizedWords.isNotEmpty) {
            setState(() => _searchTerm = result.recognizedWords);
          }

          // Process final results
          if (result.finalResult) {
            setState(() {
              _isListening = false;
              if (result.recognizedWords.isNotEmpty) {
                _processingSearch = true;
                // Reset failure count on success
                _recognitionFailureCount = 0;
              } else {
                // Increment failure count on empty result
                _recognitionFailureCount++;
              }
            });

            if (result.recognizedWords.isNotEmpty) {
              _extractObjectAndSearch(result.recognizedWords);
            } else {
              _showErrorMessage('No speech detected. Please try again.');

              // Return to object detection mode
              _setMode(AppMode.objectDetection);
            }
          }
        },
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        localeId: _getSpeechLocale(),
        cancelOnError: false,
        partialResults: true,
        listenMode: stt.ListenMode.confirmation,
      );
    } catch (e) {
      print('Error starting backup speech recognition: $e');
      return false;
    }
  }

  // Set a timeout for listening to prevent getting stuck
  void _setListeningTimeout() {
    Future.delayed(const Duration(seconds: 15), () {
      if (_isListening && mounted && _currentMode == AppMode.voiceSearch) {
        // Stop listening
        _stopListening();

        // If we have a search term but no processing has happened,
        // try to process it now
        if (_searchTerm.isNotEmpty && !_processingSearch) {
          _extractObjectAndSearch(_searchTerm);
        } else if (_searchTerm.isEmpty) {
          _showErrorMessage('No speech detected. Please try again.');

          // Return to object detection mode
          _setMode(AppMode.objectDetection);

          // Schedule a retry if needed
          _scheduleRetry();
        }
      }
    });
  }

  // Schedule a retry if recognition fails
  void _scheduleRetry() {
    if (_currentRetry < _maxRetries) {
      _currentRetry++;

      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _currentMode == AppMode.voiceSearch) {
          _showErrorMessage(
            'Retrying speech recognition... (Attempt $_currentRetry of $_maxRetries)',
          );
          _startSpeechRecognition();
        }
      });
    } else {
      _showErrorMessage(
        'Speech recognition failed after $_maxRetries attempts. Please try again later.',
      );

      // Return to object detection mode
      _setMode(AppMode.objectDetection);
    }
  }

  // Get localized prompt for when listening starts
  String _getLocalizedListeningPrompt() {
    switch (currentLanguage) {
      case 'fr':
        return 'Dites ce que vous cherchez.';
      case 'ar':
        return 'قل ما تبحث عنه.';
      default:
        return 'Say what you are looking for.';
    }
  }

  // Get the appropriate locale for speech recognition
  String _getSpeechLocale() {
    switch (currentLanguage) {
      case 'fr':
        return 'fr_FR';
      case 'ar':
        return 'ar_SA';
      default:
        return 'en_US';
    }
  }

  // Stop listening for speech input
  Future<void> _stopListening() async {
    if (_isListening) {
      if (_useBackupRecognition) {
        await _backupSpeech.stop();
      } else {
        _primarySpeech.stop();
      }

      setState(() => _isListening = false);

      // If we have a search term but no processing has happened,
      // try to process it now
      if (_searchTerm.isNotEmpty && !_processingSearch) {
        _extractObjectAndSearch(_searchTerm);
      }
    }
  }

  // Handle double tap detection
  void _handleTap() {
    // Don't respond to taps during initialization
    if (_currentMode == AppMode.initializing) return;

    final now = DateTime.now();

    if (_lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds < 300) {
      // Double tap detected - switch to voice search mode
      _setMode(AppMode.voiceSearch);
      _lastTapTime = null; // Reset after double tap
    } else {
      // First tap
      _lastTapTime = now;
    }

    // Reset the tap timer after a delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_lastTapTime != null &&
          now.difference(_lastTapTime!).inMilliseconds >= 300) {
        _lastTapTime = null;
      }
    });
  }

  // Extract the actual object name from the speech recognition result
  void _extractObjectAndSearch(String rawInput) async {
    print('Extracting object from: "$rawInput"');

    if (rawInput.isEmpty) {
      setState(() => _processingSearch = false);

      // Return to object detection mode
      _setMode(AppMode.objectDetection);
      return;
    }

    // Clean up input - remove punctuation and extra spaces
    String cleanedInput = rawInput.toLowerCase().trim();
    cleanedInput = cleanedInput.replaceAll(RegExp(r'[^\w\s]'), '');

    print('Cleaned input: "$cleanedInput"');

    // Extract the actual object name based on language patterns
    String objectName = _extractObjectName(cleanedInput);

    print('Extracted object name: "$objectName"');

    // If we couldn't extract a meaningful object name, use the last word as fallback
    if (objectName.isEmpty) {
      final words = cleanedInput.split(' ');
      if (words.isNotEmpty) {
        objectName = words.last;
        print('Using last word as fallback: "$objectName"');
      }
    }

    // If object name is still empty after cleaning, don't proceed
    if (objectName.isEmpty) {
      setState(() => _processingSearch = false);
      _showErrorMessage('Could not understand what you are looking for');

      // Return to object detection mode
      _setMode(AppMode.objectDetection);
      return;
    }

    print('Searching for object: "$objectName"');
    _searchForObject(objectName);
  }

  // Extract object name from input based on language patterns
  String _extractObjectName(String input) {
    // Language-specific extraction patterns
    switch (currentLanguage) {
      case 'fr':
        // French patterns
        if (input.contains('cherchez') || input.contains('cherche')) {
          final patterns = [
            RegExp(r'cherchez?\s+(?:un|une|le|la|les|des)?\s+(.+)'),
            RegExp(r'cherchez?\s+(.+)'),
            RegExp(r'recherchez?\s+(?:un|une|le|la|les|des)?\s+(.+)'),
            RegExp(r'recherchez?\s+(.+)'),
            RegExp(r'trouve[rz]?\s+(?:un|une|le|la|les|des)?\s+(.+)'),
            RegExp(r'trouve[rz]?\s+(.+)'),
          ];

          for (var pattern in patterns) {
            final match = pattern.firstMatch(input);
            if (match != null && match.groupCount >= 1) {
              return match.group(1)!.trim();
            }
          }
        }

        // Try to extract just the object name without patterns
        final frWords = input.split(' ');
        if (frWords.length > 1) {
          // Skip common French articles and prepositions
          final skipWords = [
            'le',
            'la',
            'les',
            'un',
            'une',
            'des',
            'du',
            'de',
            'à',
            'au',
            'aux',
          ];
          for (int i = frWords.length - 1; i >= 0; i--) {
            if (!skipWords.contains(frWords[i]) && frWords[i].length > 2) {
              return frWords[i];
            }
          }
        }
        break;

      case 'ar':
        // Arabic patterns - simplified approach
        final words = input.split(' ');
        if (words.length > 1) {
          return words.last;
        }
        break;

      default:
        // English patterns
        final patterns = [
          RegExp(r'looking\s+for\s+(?:a|an|the)?\s+(.+)'),
          RegExp(r'find\s+(?:a|an|the)?\s+(.+)'),
          RegExp(r'search\s+for\s+(?:a|an|the)?\s+(.+)'),
          RegExp(r'is\s+there\s+(?:a|an)?\s+(.+)'),
          RegExp(r'can\s+you\s+see\s+(?:a|an|the)?\s+(.+)'),
          RegExp(r'do\s+you\s+see\s+(?:a|an|the)?\s+(.+)'),
        ];

        for (var pattern in patterns) {
          final match = pattern.firstMatch(input);
          if (match != null && match.groupCount >= 1) {
            return match.group(1)!.trim();
          }
        }

        // Try to extract just the object name without patterns
        final enWords = input.split(' ');
        if (enWords.length > 1) {
          // Skip common English articles and prepositions
          final skipWords = [
            'the',
            'a',
            'an',
            'of',
            'in',
            'on',
            'at',
            'by',
            'for',
            'with',
            'about',
          ];
          for (int i = enWords.length - 1; i >= 0; i--) {
            if (!skipWords.contains(enWords[i]) && enWords[i].length > 2) {
              return enWords[i];
            }
          }
        }
    }

    // If no pattern matched, return the original input
    return input;
  }

  // Calculate string similarity using Levenshtein distance
  double _calculateStringSimilarity(String str1, String str2) {
    // Convert to lowercase for case-insensitive comparison
    str1 = str1.toLowerCase();
    str2 = str2.toLowerCase();

    // If strings are identical, return perfect match
    if (str1 == str2) return 1.0;

    // If either string is empty, return 0
    if (str1.isEmpty || str2.isEmpty) return 0.0;

    // Calculate Levenshtein distance
    int distance = _levenshteinDistance(str1, str2);

    // Convert to similarity score (0.0 to 1.0)
    int maxLength = max(str1.length, str2.length);
    return 1.0 - (distance / maxLength);
  }

  // Calculate Levenshtein distance between two strings
  int _levenshteinDistance(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> v0 = List<int>.filled(t.length + 1, 0);
    List<int> v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < v0.length; i++) {
      v0[i] = i;
    }

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;

      for (int j = 0; j < t.length; j++) {
        int cost = (s[i] == t[j]) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }

      for (int j = 0; j < v0.length; j++) {
        v0[j] = v1[j];
      }
    }

    return v1[t.length];
  }

  // Get normalized form of a word (handles plurals and common variations)
  String _getNormalizedForm(String word) {
    word = word.toLowerCase().trim();

    // Handle common plural forms
    if (word.endsWith('s') && word.length > 3) {
      String singular = word.substring(0, word.length - 1);
      // Check if removing 's' gives us a valid word
      if (singular.length > 2) {
        return singular;
      }
    }

    // Handle 'es' endings
    if (word.endsWith('es') && word.length > 4) {
      String singular = word.substring(0, word.length - 2);
      if (singular.length > 2) {
        return singular;
      }
    }

    // Handle 'ies' -> 'y' transformation
    if (word.endsWith('ies') && word.length > 4) {
      String singular = word.substring(0, word.length - 3) + 'y';
      if (singular.length > 2) {
        return singular;
      }
    }

    return word;
  }

  // Check if two words are similar or variations of each other
  bool _areWordsSimilar(String word1, String word2) {
    // Normalize both words
    String norm1 = _getNormalizedForm(word1);
    String norm2 = _getNormalizedForm(word2);

    // Check for exact match after normalization
    if (norm1 == norm2) return true;

    // Check similarity score
    double similarity = _calculateStringSimilarity(norm1, norm2);
    return similarity >= _minSimilarityScore;
  }

  // Check if a word matches any synonym in a list
  bool _matchesAnySynonym(String word, List<String> synonyms) {
    for (String synonym in synonyms) {
      if (_areWordsSimilar(word, synonym)) {
        return true;
      }
    }
    return false;
  }

  // Enhanced search for an object in the detected objects
  void _searchForObject(String objectName) async {
    print(
      'Searching for object: "$objectName" in ${yoloResults.length} detected objects',
    );

    // Debug: Print all detected objects
    for (var result in yoloResults) {
      String tag = result['tag'];
      double confidence = result['box'][4];
      print('Detected object: $tag (${confidence * 100}%)');
    }

    // Normalize the search term
    String normalizedSearchTerm = _getNormalizedForm(objectName);

    // Check if the object name has known synonyms
    List<String> searchSynonyms = [];
    for (var entry in _objectSynonyms.entries) {
      if (_matchesAnySynonym(normalizedSearchTerm, [
        entry.key,
        ...entry.value,
      ])) {
        searchSynonyms = [entry.key, ...entry.value];
        print('Found synonyms for "$normalizedSearchTerm": $searchSynonyms');
        break;
      }
    }

    // Check if the object name matches any recognized object
    bool found = false;
    String matchedObject = '';
    double highestConfidence = 0.0;
    double bestSimilarityScore = 0.0;

    // Search in all supported languages with improved matching
    for (var result in yoloResults) {
      String tag = result['tag'];
      double confidence = result['box'][4];

      // Skip objects with confidence below threshold
      if (confidence < _minDetectionConfidence) continue;

      // Check if the object name is in any of the translations
      for (var langCode in ['en', 'fr', 'ar']) {
        String translation = labelTranslations[tag]?[langCode]?.toLowerCase() ??
            tag.toLowerCase();

        print(
          'Comparing "$normalizedSearchTerm" with "$translation" ($langCode)',
        );

        // Get normalized form of translation
        String normalizedTranslation = _getNormalizedForm(translation);

        // Check for exact match after normalization
        bool exactMatch = normalizedSearchTerm == normalizedTranslation;

        // Check for synonym match
        bool synonymMatch = false;
        if (searchSynonyms.isNotEmpty) {
          for (String synonym in searchSynonyms) {
            if (_areWordsSimilar(normalizedTranslation, synonym)) {
              synonymMatch = true;
              print(
                'Synonym match found: "$synonym" matches "$normalizedTranslation"',
              );
              break;
            }
          }
        }

        // Calculate similarity score
        double similarityScore = _calculateStringSimilarity(
          normalizedSearchTerm,
          normalizedTranslation,
        );
        print(
          'Similarity score between "$normalizedSearchTerm" and "$normalizedTranslation": $similarityScore',
        );

        // Check if this is a match
        if (exactMatch ||
            synonymMatch ||
            similarityScore >= _minSimilarityScore) {
          found = true;

          // Prioritize matches by confidence and similarity
          double combinedScore =
              confidence * (similarityScore + 0.5); // Boost similarity

          if (combinedScore > highestConfidence) {
            highestConfidence = confidence;
            bestSimilarityScore = similarityScore;
            // Use the translation in the current language for feedback
            matchedObject = labelTranslations[tag]?[currentLanguage] ?? tag;
            print(
              'Match found: "$matchedObject" with confidence ${confidence * 100}% and similarity $similarityScore',
            );
          }
        }
      }
    }

    // Provide feedback based on the search result
    String feedback;
    if (found) {
      feedback = _getPositiveFeedback(matchedObject);
      print(
        'Positive match: "$matchedObject" with confidence ${highestConfidence * 100}% and similarity $bestSimilarityScore',
      );
    } else {
      feedback = _getNegativeFeedback(objectName);
      print('No match found for "$objectName"');
    }

    print('Feedback: "$feedback"');

    setState(() {
      _lastSearchFeedback = feedback;
      _showSearchFeedback = true;
      _processingSearch = false;
    });

    // Speak the feedback
    await flutterTts.speak(feedback);

    // Hide feedback after a delay and return to detection mode
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _showSearchFeedback = false;
        });

        // Return to object detection mode
        if (_currentMode == AppMode.voiceSearch) {
          _setMode(AppMode.objectDetection);
        }
      }
    });
  }

  // Get positive feedback message (object found)
  String _getPositiveFeedback(String objectName) {
    // Ensure object name is properly capitalized
    objectName = _capitalizeFirstLetter(objectName);

    switch (currentLanguage) {
      case 'fr':
        return 'Oui, $objectName est devant vous.';
      case 'ar':
        return 'نعم، $objectName أمامك.';
      default:
        return 'Yes, $objectName is in front of you.';
    }
  }

  // Get negative feedback message (object not found)
  String _getNegativeFeedback(String objectName) {
    // Ensure object name is properly capitalized
    objectName = _capitalizeFirstLetter(objectName);

    switch (currentLanguage) {
      case 'fr':
        return 'Non, $objectName n\'est pas visible.';
      case 'ar':
        return 'لا، $objectName غير موجود.';
      default:
        return 'No, $objectName is not visible.';
    }
  }

  // Helper to capitalize first letter of a string
  String _capitalizeFirstLetter(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  Future<void> _setTtsLanguage(String code) async {
    switch (code) {
      case 'ar':
        await flutterTts.setLanguage('ar-SA');
        break;
      case 'fr':
        await flutterTts.setLanguage('fr-FR');
        break;
      default:
        await flutterTts.setLanguage('en-US');
    }
  }

  Future<void> _speakLabel(String label) async {
    // Only speak labels if in object detection mode and instructions are completed
    if (_currentMode != AppMode.objectDetection || !_instructionsCompleted)
      return;

    String translated = labelTranslations[label]?[currentLanguage] ?? label;
    await flutterTts.speak(translated);
  }

  @override
  void dispose() {
    _stopDetection();
    controller.dispose();
    vision.closeYoloModel();
    flutterTts.stop();
    _primarySpeech.cancel();
    _backupSpeech.cancel();
    _retryTimer?.cancel();
    _cameraStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;

    if (!isLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      extendBodyBehindAppBar: true, // Make the body extend behind the AppBar
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.5),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          // Language selector dropdown
          PopupMenuButton<String>(
            icon: const Icon(Icons.language, color: Colors.white),
            onSelected: (String languageCode) {
              _changeLanguage(languageCode);
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'en',
                  child: Text('English'),
                ),
                const PopupMenuItem<String>(
                  value: 'fr',
                  child: Text('Français'),
                ),
                const PopupMenuItem<String>(
                  value: 'ar',
                  child: Text('العربية'),
                ),
              ];
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Make camera preview fill the entire screen
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller.value.previewSize!.height,
                  height: controller.value.previewSize!.width,
                  child: CameraPreview(controller),
                ),
              ),
            ),

            // Bounding boxes around detected objects
            ...displayBoxesAroundRecognizedObjects(size),

            // Voice search feedback overlay
            if (_showSearchFeedback)
              Positioned(
                top: 100,
                left: 0,
                right: 0,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _lastSearchFeedback,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Voice search button - CENTERED at bottom of screen
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Center(
                child: FloatingActionButton(
                  onPressed: () {
                    if (_currentMode == AppMode.voiceSearch) {
                      _setMode(AppMode.objectDetection);
                    } else {
                      _setMode(AppMode.voiceSearch);
                    }
                  },
                  backgroundColor: _currentMode == AppMode.voiceSearch
                      ? Colors.red
                      : Colors.blue,
                  child: Icon(
                    _currentMode == AppMode.voiceSearch
                        ? Icons.mic_off
                        : Icons.mic,
                  ),
                ),
              ),
            ),

            // Current mode indicator - moved to above the mic button
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _currentMode == AppMode.objectDetection
                        ? 'Detection Mode'
                        : _currentMode == AppMode.voiceSearch
                            ? 'Voice Search Mode'
                            : 'Initializing...',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

            // Speech recognition status indicator with improved visibility
            if (_isListening)
              Positioned(
                bottom: 90,
                right: 30,
                left: 30, // Extend across screen for better visibility
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _searchTerm.isEmpty
                        ? _getLocalizedListeningMessage()
                        : _searchTerm,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Double tap instruction reminder (only shown initially)
            if (!_isListening && _hasPlayedInitialInstructions)
              Positioned(
                bottom: 150,
                left: 0,
                right: 0,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _getLocalizedInstructions(),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Loading indicator when instructions are playing but detection hasn't started
            if (_hasPlayedInitialInstructions && !_instructionsCompleted)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Get localized "Listening..." message
  String _getLocalizedListeningMessage() {
    switch (currentLanguage) {
      case 'fr':
        return 'Écoute...';
      case 'ar':
        return 'جاري الاستماع...';
      default:
        return 'Listening...';
    }
  }

  // Change language
  Future<void> _changeLanguage(String languageCode) async {
    setState(() {
      currentLanguage = languageCode;
    });
    await _setTtsLanguage(languageCode);

    // Clear spoken tags so objects will be announced in new language
    spokenTags.clear();

    // Play instructions in new language
    _playInitialInstructions();
  }

  Future<void> loadYoloModel() async {
    await vision.loadYoloModel(
      labels: 'assets/models/newlabels.txt',
      modelPath: 'assets/models/bestlast_float16.tflite',
      modelVersion: "yolov8",
      quantization: false,
      numThreads: 1,
      useGpu: false,
    );
  }

  Future<void> yoloOnFrame(CameraImage cameraImage) async {
    // Only process frames if in object detection mode and instructions are completed
    if (_currentMode != AppMode.objectDetection || !_instructionsCompleted)
      return;

    try {
      final result = await vision.yoloOnFrame(
        bytesList: cameraImage.planes.map((plane) => plane.bytes).toList(),
        imageHeight: cameraImage.height,
        imageWidth: cameraImage.width,
        iouThreshold: 0.2,
        confThreshold: confidenceThreshold,
        classThreshold: confidenceThreshold,
      );

      if (result.isNotEmpty && mounted) {
        setState(() {
          yoloResults = result;
        });

        // Only speak labels if in object detection mode
        if (_currentMode == AppMode.objectDetection) {
          for (var item in result) {
            final tag = item['tag'];
            if (!spokenTags.contains(tag)) {
              spokenTags.add(tag);
              await _speakLabel(tag);
            }
          }
        }
      }
    } catch (e) {
      print('Error in yoloOnFrame: $e');
    }
  }

  Future<void> _startDetection() async {
    // Only start detection if instructions are completed
    if (!_instructionsCompleted) return;

    setState(() {
      yoloResults = [];
    });

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      // Use a safer approach with StreamSubscription for better cleanup
      await controller.startImageStream((image) {
        if (_currentMode == AppMode.objectDetection) {
          cameraImage = image;
          yoloOnFrame(image);
        }
      });
    } catch (e) {
      print('Error starting detection: $e');
      _showErrorMessage('Error starting object detection: $e');
    }
  }

  Future<void> _stopDetection() async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      setState(() {
        yoloResults.clear();
      });
    } catch (e) {
      print('Error stopping detection: $e');
    }
  }

  List<Widget> displayBoxesAroundRecognizedObjects(Size screen) {
    if (yoloResults.isEmpty) return [];

    double factorX = screen.width / (cameraImage?.height ?? 1);
    double factorY = screen.height / (cameraImage?.width ?? 1);
    Color boxColor = Colors.red;

    return yoloResults.map((result) {
      double objectX = result["box"][0] * factorX;
      double objectY = result["box"][1] * factorY;
      double objectWidth = (result["box"][2] - result["box"][0]) * factorX;
      double objectHeight = (result["box"][3] - result["box"][1]) * factorY;

      String translatedLabel =
          labelTranslations[result['tag']]?[currentLanguage] ?? result['tag'];
      String confidence = (result['box'][4] * 100).toStringAsFixed(1);

      return Positioned(
        left: objectX,
        top: objectY,
        width: objectWidth,
        height: objectHeight,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10.0),
            border: Border.all(color: boxColor, width: 3.0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: boxColor,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8.0),
                    bottomRight: Radius.circular(8.0),
                  ),
                ),
                child: Text(
                  "$translatedLabel $confidence%",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16.0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
