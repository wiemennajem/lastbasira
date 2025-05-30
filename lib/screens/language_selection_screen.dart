import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:camera/camera.dart';
import 'package:vibration/vibration.dart';
import '../main.dart';
import 'home_Screen.dart';

class LanguageSelectionScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const LanguageSelectionScreen({super.key, required this.cameras});

  @override
  State<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends State<LanguageSelectionScreen> {
  final FlutterTts tts = FlutterTts();

  final List<Map<String, dynamic>> languages = [
    {'code': 'ar', 'label': 'العربية'},
    {'code': 'fr', 'label': 'Français'},
    {'code': 'en', 'label': 'English'},
  ];

  int currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _speakInstructions();
  }

  Future<void> _speakInstructions() async {
    await _setTTSLanguage(languages[currentIndex]['code']);
    await tts.speak(" لإختيار العربية انقر مرتين. لتغييرها اسحب الشاشه");
    await Future.delayed(const Duration(seconds: 6));
    await _speakCurrentLanguage();
  }

  Future<void> _speakCurrentLanguage() async {
    await tts.stop();
    await _setTTSLanguage(languages[currentIndex]['code']);
    await tts.speak(languages[currentIndex]['label']);
  }

  Future<void> _setTTSLanguage(String code) async {
    switch (code) {
      case 'ar':
        await tts.setLanguage('ar-SA');
        break;
      case 'fr':
        await tts.setLanguage('fr-FR');
        break;
      default:
        await tts.setLanguage('en-US');
    }
  }

  Future<void> _vibrateShort() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 50);
    }
  }

  Future<void> _vibrateStrong() async {
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(duration: 200);
    }
  }

  void _nextLanguage() {
    setState(() {
      currentIndex = (currentIndex + 1) % languages.length;
    });
    _vibrateShort();
    _speakCurrentLanguage();
  }

  void _prevLanguage() {
    setState(() {
      currentIndex = (currentIndex - 1 + languages.length) % languages.length;
    });
    _vibrateShort();
    _speakCurrentLanguage();
  }

  Future<void> _selectLanguage() async {
    await _vibrateStrong();
    String selectedCode = languages[currentIndex]['code'];
    String selectedLabel = languages[currentIndex]['label'];

    await _setTTSLanguage(selectedCode);
    await tts.speak(
      selectedCode == 'ar'
          ? "لقد اخترت $selectedLabel."
          : selectedCode == 'fr'
              ? "Vous avez choisi $selectedLabel."
              : "You selected $selectedLabel.",
    );

    await Future.delayed(const Duration(seconds: 4));
    MyApp.of(context)?.setLocale(Locale(selectedCode));
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => WelcomeCenterScreen(cameras: widget.cameras),
      ),
    );
  }

  // New method to build the oval language selector
  Widget _buildOvalLanguageSelector() {
    return GestureDetector(
      onTap: _nextLanguage,
      onDoubleTap: _selectLanguage,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        decoration: BoxDecoration(
          color: const Color.fromARGB(255, 248, 228, 244),
          borderRadius: BorderRadius.circular(50), // Creates oval shape
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              spreadRadius: 1,
              blurRadius: 5,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 40),
        child: Text(
          languages[currentIndex]['label'],
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity! < 0) {
          _nextLanguage();
        } else if (details.primaryVelocity! > 0) {
          _prevLanguage();
        }
      },
      onDoubleTap: _selectLanguage,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.white, Color.fromARGB(255, 135, 145, 255)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // Fixed logo container with responsive height
                Expanded(
                  flex: 6, // Takes 60% of the screen height
                  child: Center(
                    child: Image.asset(
                      'assets/icons/logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                // Fixed text container
                Expanded(
                  flex: 6, // Takes 60% of the screen height
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        const Text(
                          '!مرحباً بكم في بصيرة' , 
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            color: Color.fromARGB(221, 2, 2, 123),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        // Replace the previous Text widget with the new oval selector
                        _buildOvalLanguageSelector(),
                        const SizedBox(height: 20),
                        const Text(
                          '.لإختيار العربية انقر مرتين',
                          style: TextStyle(fontSize: 23, color: Color.fromARGB(221, 2, 2, 123)),
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          '.لتغييرها اسحب الشاشة',
                          style: TextStyle(fontSize: 23, color: const Color.fromARGB(221, 2, 2, 123)),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}