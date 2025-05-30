import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:camera/camera.dart';

import 'text_Screen.dart';
import 'money_Screen.dart' as money;
import 'object_Screen.dart' as object;
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class WelcomeCenterScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const WelcomeCenterScreen({super.key, required this.cameras});

  @override
  State<WelcomeCenterScreen> createState() => _WelcomeCenterScreenState();
}

class _WelcomeCenterScreenState extends State<WelcomeCenterScreen> with WidgetsBindingObserver {
  final FlutterTts tts = FlutterTts();
  List<CameraDescription> get cameras => widget.cameras;
  int currentIndex = 0;

  List<String> features = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = AppLocalizations.of(context)!;

    features = [
      locale.welcome,
      locale.currencyIdentifier,
      locale.textReader,
      locale.objectFinder,
    ];

    // Delay the speech slightly to ensure proper initialization
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _speakFeature();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // Add this widget as an observer to detect when the app comes back to foreground
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // Remove the observer when the widget is disposed
    WidgetsBinding.instance.removeObserver(this);
    tts.stop();
    super.dispose();
  }

  // This method is called when the app lifecycle changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // When the app comes back to the foreground (resumed from background or another screen)
    if (state == AppLifecycleState.resumed && mounted) {
      // Add a small delay to ensure the screen is fully loaded
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          _speakFeature();
        }
      });
    }
  }

  Future<void> _speakFeature() async {
    await tts.stop();

    Locale currentLocale = Localizations.localeOf(context);
    if (currentLocale.languageCode == 'ar') {
      await tts.setLanguage('ar-SA');
    } else if (currentLocale.languageCode == 'fr') {
      await tts.setLanguage('fr-FR');
    } else {
      await tts.setLanguage('en-US');
    }

    if (currentIndex == 0) {
      await tts.speak(AppLocalizations.of(context)!.welcome);
    } else {
      await tts.speak(
        "${features[currentIndex]}. ${AppLocalizations.of(context)!.doubleTap}",
      );
    }
  }

  Future<void> _vibrate() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 100);
    }
  }

  void _nextFeature() {
    _vibrate();
    setState(() {
      currentIndex = (currentIndex + 1) % features.length;
    });
    _speakFeature();
  }

  void _prevFeature() {
    _vibrate();
    setState(() {
      currentIndex = (currentIndex - 1 + features.length) % features.length;
    });
    _speakFeature();
  }

  void _launchFeature() async {
    _vibrate();
    await tts.stop(); // Stop current speech before navigating
    
    switch (currentIndex) {
      case 1:
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => money.MoneyRecognitionScreen(camerass: cameras),
          ),
        );
        // When returning from money recognition screen, speak the feature again
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _speakFeature();
            }
          });
        }
        break;
      case 2:
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CameraScreen()),
        );
        // When returning from text screen, speak the feature again
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _speakFeature();
            }
          });
        }
        break;
      case 3:
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => object.YoloVideo(camerass: cameras),
          ),
        );
        // When returning from object detection screen, speak the feature again
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _speakFeature();
            }
          });
        }
        break;
    }
  }

  String getFeatureIconPath() {
    switch (currentIndex) {
      case 1:
        return 'assets/icons/moneyd.jpg';
      case 2:
        return 'assets/icons/textd.jpg';
      case 3:
        return 'assets/icons/objdet.jpg';
      default:
        return 'assets/icons/welcomep.jpg';
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = AppLocalizations.of(context)!;
    // Get screen dimensions for responsive layout
    final screenSize = MediaQuery.of(context).size;
    final screenHeight = screenSize.height;
    final screenWidth = screenSize.width;
    final isLandscape = screenWidth > screenHeight;
    final smallestDimension = screenWidth < screenHeight ? screenWidth : screenHeight;

    // Calculate responsive sizes with min/max constraints for better responsiveness
    final imageSize = (isLandscape ? screenHeight * 0.6 : screenWidth * 0.75)
        .clamp(200.0, 500.0); // Min 200, max 500
    final imagePadding = isLandscape 
        ? (screenWidth - imageSize) / 2 
        : screenWidth * 0.125; // Center horizontally
    
    // Font sizes with min/max constraints
    final titleFontSize = (smallestDimension * 0.075).clamp(18.0, 32.0);
    final subtitleFontSize = (smallestDimension * 0.06).clamp(16.0, 28.0);
    final instructionFontSize = (smallestDimension * 0.055).clamp(14.0, 24.0);

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity! < 0) {
          _nextFeature();
        } else if (details.primaryVelocity! > 0) {
          _prevFeature();
        }
      },
      onDoubleTap: _launchFeature,
      onLongPress: _speakFeature,
      child: Scaffold(
        backgroundColor: const Color.fromARGB(255, 224, 228, 255),
        appBar: AppBar(
          backgroundColor: const Color.fromARGB(255, 224, 228, 255),
          elevation: 0,
          title: Text(locale.appTitle)
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color.fromARGB(255, 224, 228, 255), // Light purple-blue at top
                Color.fromARGB(255, 140, 143, 255), // Slightly darker purple-blue at bottom
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    // Feature title at the top - only for non-welcome screens
                    Positioned(
                      top: constraints.maxHeight * 0.05, // 5% from the top
                      left: 0,
                      right: 0,
                      child: currentIndex != 0 
                        ? Text(
                            features[currentIndex],
                            style: TextStyle(
                              fontSize: titleFontSize,
                              fontWeight: FontWeight.bold,
                              color: const Color.fromARGB(230, 52, 19, 241),
                              letterSpacing: 0.5,
                            ),
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis, // Prevent text overflow
                            maxLines: 2,
                          )
                        : const SizedBox.shrink(), // Empty widget for welcome screen
                    ),
                    
                    // Welcome text (Welcome to Basira)
                    Positioned(
                      top: constraints.maxHeight * 0.03, // 3% from the top
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.1),
                        child: currentIndex == 0
                            ? Text(
                                locale.welcomword,
                                style: TextStyle(
                                  fontSize: subtitleFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: const Color.fromARGB(230, 52, 19, 241),
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 2,
                              )
                            : const SizedBox(),
                      ),
                    ),
                    
                    // Image container - centered both horizontally and vertically
                    Positioned(
                      top: isLandscape 
                          ? constraints.maxHeight * 0.1 // 10% from top in landscape
                          : constraints.maxHeight * 0.15, // 15% from top in portrait
                      left: imagePadding,
                      child: Container(
                        width: imageSize,
                        height: isLandscape ? constraints.maxHeight * 0.7 : imageSize, // Adjust height in landscape
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color.fromARGB(255, 166, 173, 250),
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(imageSize * 0.13), // Rounded corners
                          image: DecorationImage(
                            image: AssetImage(getFeatureIconPath()),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                    
                    // Welcome message or instructions - with adaptive positioning
                    Positioned(
                      bottom: isLandscape 
                          ? constraints.maxHeight * 0.15 // 15% from bottom in landscape
                          : constraints.maxHeight * 0.25, // 25% from bottom in portrait
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.1),
                        child: currentIndex == 0
                            ? Text(
                                locale.instruction,
                                style: TextStyle(
                                  fontSize: instructionFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: const Color.fromARGB(255, 66, 66, 66),
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 3,
                              )
                            : Text(
                                '${locale.swipeToChange}\n${locale.doubleTap}',
                                style: TextStyle(
                                  fontSize: instructionFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: const Color.fromARGB(255, 66, 66, 66),
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 3,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}