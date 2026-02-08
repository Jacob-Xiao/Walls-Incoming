import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:ui';

// Backend API base URL; change for deployment
const String _apiBaseUrl = 'http://localhost:8000';

/// Level 1: semicircle hole width ratio to shortest side (pass check and draw)
const double _holeWidthRatio = 0.85;

/// Level 2: center rectangle hole width ratio (medium width, through to bottom)
const double _holeWidthRatioRect = 0.40;

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with TickerProviderStateMixin {
  List<CameraDescription>? _cameras;
  CameraController? _controller;
  bool _isCameraReady = false;
  String? _cameraError;
  bool _gameStarted = false;
  late AnimationController _wallAnimationController;
  late Animation<double> _wallScaleAnimation;

  /// Keypoints [x_norm, y_norm, confidence] from result.keypoints.xyn normalized [0,1]
  List<List<double>> _keypoints = [];
  int _imageWidth = 0;
  int _imageHeight = 0;

  /// Backend YOLO plot image stream (img = results.plot(line_width=1))
  Uint8List? _annotatedImageBytes;

  /// Pass result: null = not checked, true = passed, false = failed
  bool? _gameResult;

  /// Keypoint indices on wall when failed (for red overlay)
  List<int> _failedKeypointIndices = [];
  Timer? _poseDetectionTimer;
  bool _checkTriggered = false;
  bool _isCapturing = false;

  /// Current level: 1 = semicircle hole, 2 = center rectangle hole
  int _currentLevel = 1;

  /// Score for the last finished level (shown on result island)
  int _lastScore = 0;

  /// Highest score across all levels (shown on result island)
  int _highestScore = 0;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _wallAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    // Wall scale 1.0 = full screen
    _wallScaleAnimation = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(
        parent: _wallAnimationController,
        curve: Curves.easeIn,
      ),
    );
    _wallAnimationController.addStatusListener(_onWallAnimationStatus);
    _wallAnimationController.addListener(_onWallAnimationTick);
  }

  void _onWallAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_checkTriggered) {
      _triggerPassFailCheck();
    }
  }

  void _onWallAnimationTick() {
    // Check when wall scale reaches 1.0
    if (_wallScaleAnimation.value >= 0.99 && !_checkTriggered) {
      _triggerPassFailCheck();
    }
  }

  Future<void> _triggerPassFailCheck() async {
    if (_checkTriggered) return;
    _checkTriggered = true;
    _poseDetectionTimer?.cancel();

    // Final frame at wall close for pass/fail check
    await _finalCaptureAndCheck();
  }

  /// Capture final frame at wall close; pass/fail from keypoints vs wall (any on wall = fail)
  Future<void> _finalCaptureAndCheck() async {
    final size = MediaQuery.of(context).size;
      if (_controller == null || !_controller!.value.isInitialized || !mounted) {
      if (mounted) setState(() {
        _gameResult = false;
        _failedKeypointIndices = [];
        _lastScore = 0;
      });
      return;
    }
    try {
      final file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      final uri = Uri.parse('$_apiBaseUrl/api/pose/detect');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'final_frame.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _gameResult = false;
          _failedKeypointIndices = [];
          _lastScore = 0;
        });
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final kpts = (data['keypoints'] as List<dynamic>?)
          ?.map((e) => (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
          .toList();
      final w = (data['image_width'] as num?)?.toInt() ?? 0;
      final h = (data['image_height'] as num?)?.toInt() ?? 0;
      final (passed, failedIndices) = _checkKeypointsInHoleWithKeypoints(size, kpts ?? [], w, h);
      final keypointCount = (kpts ?? []).length;
      // Pass: 10 per keypoint. Fail: 10 per in-hole (green), 5 per on-wall (red)
      final score = passed
          ? keypointCount * 10
          : (keypointCount - failedIndices.length) * 10 + failedIndices.length * 5;
      Uint8List? imgBytes;
      final annBase64 = data['annotated_image_base64'] as String?;
      if (annBase64 != null && annBase64.isNotEmpty) {
        try {
          imgBytes = base64Decode(annBase64);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _keypoints = kpts ?? [];
          _imageWidth = w;
          _imageHeight = h;
          _gameResult = passed;
          _failedKeypointIndices = passed ? [] : failedIndices;
          _lastScore = score;
          if (score > _highestScore) _highestScore = score;
          if (imgBytes != null) _annotatedImageBytes = imgBytes;
        });
      }
    } catch (e) {
      debugPrint('Final capture/check error: $e');
      if (mounted) setState(() {
        _gameResult = false;
        _failedKeypointIndices = [];
        _lastScore = 0;
      });
    }
  }

  /// Pass check: last frame at wall close; keypoints vs wall (any on wall = fail).
  /// Returns (passed, list of keypoint indices on wall).
  (bool, List<int>) _checkKeypointsInHoleWithKeypoints(
    Size screenSize,
    List<List<double>> keypoints,
    int imageWidth,
    int imageHeight,
  ) {
    if (keypoints.isEmpty) return (false, []);
    final holePath = _buildHolePath(screenSize);
    final failedIndices = <int>[];
    for (var i = 0; i < keypoints.length; i++) {
      final kp = keypoints[i];
      if (kp.length < 2) continue;
      final screenPos = _normToScreenWithSize(kp[0], kp[1], screenSize, imageWidth, imageHeight);
      if (!holePath.contains(screenPos)) {
        failedIndices.add(i);
      }
    }
    return (failedIndices.isEmpty, failedIndices);
  }

  /// Build hole path matching WallPainter for contains check; depends on current level.
  Path _buildHolePath(Size size) {
    final centerX = size.width * 0.5;
    final holePath = Path();
    if (_currentLevel == 1) {
      final holeW = size.shortestSide * _holeWidthRatio;
      final r = holeW / 2;
      final circleCenterY = size.height - r;
      holePath.moveTo(centerX - r, size.height);
      holePath.lineTo(centerX + r, size.height);
      holePath.lineTo(centerX + r, circleCenterY);
      holePath.arcTo(
        Rect.fromCenter(center: Offset(centerX, circleCenterY), width: holeW, height: holeW),
        0,
        -pi,
        false,
      );
      holePath.close();
    } else {
      // Level 2: center medium-width rectangle through to bottom
      final holeW = size.shortestSide * _holeWidthRatioRect;
      holePath.addRect(Rect.fromCenter(
        center: Offset(centerX, size.height * 0.5),
        width: holeW,
        height: size.height,
      ));
    }
    return holePath;
  }

  Offset _normToScreenWithSize(double normX, double normY, Size screenSize, int imgW, int imgH) {
    if (imgW <= 0 || imgH <= 0) return Offset.zero;
    final scale = (screenSize.width / imgW) > (screenSize.height / imgH)
        ? screenSize.width / imgW
        : screenSize.height / imgH;
    final scaledW = imgW * scale;
    final scaledH = imgH * scale;
    final offsetX = (screenSize.width - scaledW) / 2;
    final offsetY = (screenSize.height - scaledH) / 2;
    final x = screenSize.width - (normX * imgW * scale + offsetX);
    final y = normY * imgH * scale + offsetY;
    return Offset(x, y);
  }

  /// Convert normalized [0,1] to screen coords (FittedBox cover + front-camera mirror).
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() {
          _cameraError = 'No camera detected';
        });
        return;
      }
      CameraDescription? frontCamera;
      for (final camera in _cameras!) {
        if (camera.lensDirection == CameraLensDirection.front) {
          frontCamera = camera;
          break;
        }
      }
      frontCamera ??= _cameras!.first;
      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      if (!mounted) return;
      setState(() {
        _isCameraReady = true;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _cameraError = 'Camera init failed: $e';
      });
      debugPrint('Camera init error: $e\n$st');
    }
  }

  void _startGame() {
    setState(() {
      _gameStarted = true;
      _gameResult = null;
      _checkTriggered = false;
      _keypoints = [];
      _failedKeypointIndices = [];
    });
    _wallAnimationController.forward();
    _startPoseDetection();
  }

  void _startPoseDetection() {
    _poseDetectionTimer?.cancel();
    _poseDetectionTimer = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (_checkTriggered || _gameResult != null || !mounted) return;
      await _captureAndDetectPose();
    });
  }

  Future<void> _captureAndDetectPose() async {
    if (_controller == null || !_controller!.value.isInitialized || _isCapturing) return;
    _isCapturing = true;
    try {
      final file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      debugPrint('[Pose] takePicture OK, bytes=${bytes.length}');

      final uri = Uri.parse('$_apiBaseUrl/api/pose/detect');
      final request = http.MultipartRequest('POST', uri);
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'frame.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);

      debugPrint('[Pose] API status=${response.statusCode}');

      if (response.statusCode == 200 && mounted && !_checkTriggered) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final kpts = (data['keypoints'] as List<dynamic>?)
            ?.map((e) => (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
            .toList();
        final annBase64 = data['annotated_image_base64'] as String?;
        final annBytes = annBase64 != null && annBase64.isNotEmpty
            ? Uint8List.fromList(base64Decode(annBase64))
            : null;
        setState(() {
          _keypoints = kpts ?? [];
          _imageWidth = (data['image_width'] as num?)?.toInt() ?? 0;
          _imageHeight = (data['image_height'] as num?)?.toInt() ?? 0;
          _annotatedImageBytes = annBytes;
        });
      } else if (response.statusCode != 200) {
        debugPrint('[Pose] API error: ${response.body}');
      }
    } catch (e, st) {
      debugPrint('Pose detect error: $e');
      debugPrint('Stack: $st');
    } finally {
      _isCapturing = false;
    }
  }

  void _goHome() {
    _poseDetectionTimer?.cancel();
    Navigator.of(context).pop();
  }

  void _playAgain() {
    setState(() {
      _gameResult = null;
      _checkTriggered = false;
      _keypoints = [];
      _failedKeypointIndices = [];
      _gameStarted = false;
    });
    _wallAnimationController.reset();
  }

  /// Enter next level after clearing level 1
  void _goToNextLevel() {
    setState(() {
      _currentLevel = 2;
      _gameResult = null;
      _checkTriggered = false;
      _keypoints = [];
      _failedKeypointIndices = [];
    });
    _wallAnimationController.reset();
    _wallAnimationController.forward();
    _startPoseDetection();
  }

  @override
  void dispose() {
    _wallAnimationController.removeStatusListener(_onWallAnimationStatus);
    _wallAnimationController.removeListener(_onWallAnimationTick);
    _wallAnimationController.dispose();
    _poseDetectionTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideoDisplay(),
          if (_gameStarted && _keypoints.isNotEmpty) _buildKeypointsOverlay(),
          if (!_gameStarted && _gameResult == null) _buildFloatingIsland(),
          if (_gameStarted && _gameResult == null) _buildWallOverlay(),
          if (_gameResult != null) _buildResultIsland(),
        ],
      ),
    );
  }

  /// During game show backend YOLO annotated stream (mirrored); else camera preview.
  Widget _buildVideoDisplay() {
    if (_gameStarted && _annotatedImageBytes != null && _annotatedImageBytes!.isNotEmpty) {
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(-1.0, 1.0),
        child: FittedBox(
          fit: BoxFit.cover,
          child: Image.memory(
            _annotatedImageBytes!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
      );
    }
    return _buildCameraPreview();
  }

  /// Overlay keypoints on stream: green = ok, red = on wall when failed.
  Widget _buildKeypointsOverlay() {
    final size = MediaQuery.of(context).size;
    return IgnorePointer(
      child: CustomPaint(
        size: size,
        painter: KeypointsOverlayPainter(
          keypoints: _keypoints,
          imageWidth: _imageWidth,
          imageHeight: _imageHeight,
          failedIndices: _gameResult == false ? _failedKeypointIndices : const [],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.videocam_off, size: 64, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                _cameraError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    if (!_isCameraReady || _controller == null || !_controller!.value.isInitialized) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF3D7A35)),
            SizedBox(height: 16),
            Text('Starting camera...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: _controller!.value.previewSize?.height ?? 1,
        height: _controller!.value.previewSize?.width ?? 1,
        child: CameraPreview(_controller!),
      ),
    );
  }

  

  Widget _buildFloatingIsland() {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.9, end: 1.0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: 340,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0F1E).withOpacity(0.78),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withOpacity(0.85),
                  width: 1.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withOpacity(0.35),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.65),
                    blurRadius: 36,
                    spreadRadius: 6,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Level $_currentLevel',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _currentLevel == 1 ? 'Difficulty: Easy' : 'Difficulty: Medium',
                    style: TextStyle(
                      fontSize: 14,
                      letterSpacing: 4,
                      color: Colors.white.withOpacity(0.72),
                    ),
                  ),
                  const SizedBox(height: 26),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _startGame,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: const Color(0xFF081018),
                        elevation: 12,
                        shadowColor: const Color(0xFF00E5FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Start',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 6,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildWallOverlay() {
    return AnimatedBuilder(
      animation: _wallScaleAnimation,
      builder: (context, child) {
        return Center(
          child: Transform.scale(
            scale: _wallScaleAnimation.value,
            child: CustomPaint(
              size: MediaQuery.of(context).size,
              painter: WallPainter(
                holeType: _currentLevel == 1 ? WallHoleType.semicircle : WallHoleType.rectangle,
              ),
            ),
          ),
        );
      },
    );
  }

   Widget _buildResultIsland() {
    final passed = _gameResult ?? false;
    final glow = passed ? const Color(0xFF00E676) : const Color(0xFFFF1744);

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.88, end: 1.0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: 360,
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0F1E).withOpacity(0.82),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: glow.withOpacity(0.9), width: 1.8),
                boxShadow: [
                  BoxShadow(
                    color: glow.withOpacity(0.35),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.65),
                    blurRadius: 40,
                    spreadRadius: 6,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top scan bar
                  Container(
                    height: 6,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [
                          glow.withOpacity(0.0),
                          glow.withOpacity(0.85),
                          glow.withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Icon
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glow.withOpacity(0.10),
                      border: Border.all(color: glow.withOpacity(0.7), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: glow.withOpacity(0.25),
                          blurRadius: 22,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      passed ? Icons.emoji_events_rounded : Icons.warning_amber_rounded,
                      size: 44,
                      color: glow,
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Title
                  Text(
                    passed ? 'CLEAR' : 'FAILED',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                      color: glow,
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Message
                  Text(
                    passed
                        ? 'Pose matched successfully.\nYou made it through!'
                        : 'Pose mismatch detected.\nYou hit the wall.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      letterSpacing: 2,
                      height: 1.4,
                      color: Colors.white.withOpacity(0.75),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Score & Best
                  Text(
                    'Score: $_lastScore',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: glow,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Best: $_highestScore',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Divider
                  Container(
                    height: 1,
                    width: double.infinity,
                    color: Colors.white.withOpacity(0.12),
                  ),

                  const SizedBox(height: 18),

                  // Buttons
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: _goHome,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: BorderSide(color: Colors.white.withOpacity(0.35)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              'BACK TO HOME',
                              style: TextStyle(letterSpacing: 2),
                            ),
                          ),
                        ),
                      ),
                      if (passed && _currentLevel == 1) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: FilledButton(
                              onPressed: _goToNextLevel,
                              style: FilledButton.styleFrom(
                                backgroundColor: glow,
                                foregroundColor: const Color(0xFF081018),
                                elevation: 14,
                                shadowColor: glow.withOpacity(0.7),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text(
                                'NEXT LEVEL',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 14),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: _playAgain,
                            style: FilledButton.styleFrom(
                              backgroundColor: glow,
                              foregroundColor: const Color(0xFF081018),
                              elevation: 14,
                              shadowColor: glow.withOpacity(0.7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              'PLAY AGAIN',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
} 



/// Draw keypoints on stream: green = ok, red = failed (on wall). Coords from xyn to screen (cover + mirror).
class KeypointsOverlayPainter extends CustomPainter {
  KeypointsOverlayPainter({
    required this.keypoints,
    required this.imageWidth,
    required this.imageHeight,
    this.failedIndices = const [],
  });

  final List<List<double>> keypoints;
  final int imageWidth;
  final int imageHeight;
  final List<int> failedIndices;

  static Offset _normToScreen(double normX, double normY, Size screenSize, int imgW, int imgH) {
    if (imgW <= 0 || imgH <= 0) return Offset.zero;
    final scale = (screenSize.width / imgW) > (screenSize.height / imgH)
        ? screenSize.width / imgW
        : screenSize.height / imgH;
    final scaledW = imgW * scale;
    final scaledH = imgH * scale;
    final offsetX = (screenSize.width - scaledW) / 2;
    final offsetY = (screenSize.height - scaledH) / 2;
    final x = screenSize.width - (normX * imgW * scale + offsetX);
    final y = normY * imgH * scale + offsetY;
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final failedSet = failedIndices.toSet();
    const greenColor = Color(0xFF3D7A35);
    const redColor = Color(0xFFFF1744);
    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < keypoints.length; i++) {
      final kp = keypoints[i];
      if (kp.length < 2) continue;
      final pos = _normToScreen(kp[0], kp[1], size, imageWidth, imageHeight);
      final pointPaint = Paint()
        ..color = failedSet.contains(i) ? redColor : greenColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 8, pointPaint);
      canvas.drawCircle(pos, 8, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant KeypointsOverlayPainter oldDelegate) {
    return oldDelegate.keypoints != keypoints ||
        oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight ||
        oldDelegate.failedIndices != failedIndices;
  }
}

enum WallHoleType { semicircle, rectangle }

class WallPainter extends CustomPainter {
  WallPainter({required this.holeType});

  final WallHoleType holeType;

  @override
  void paint(Canvas canvas, Size size) {
    final wallPaint = Paint()
      ..color = const Color(0xFF0A0F1E).withOpacity(0.82)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final rect = Offset.zero & size;
    final fullRectPath = Path()..addRect(rect);

    final centerX = size.width * 0.5;
    final holePath = Path();
    final outlinePath = Path();

    switch (holeType) {
      case WallHoleType.semicircle:
        final holeW = size.shortestSide * _holeWidthRatio;
        final r = holeW / 2;
        final circleCenterY = size.height - r;
        holePath.moveTo(centerX - r, size.height);
        holePath.lineTo(centerX + r, size.height);
        holePath.lineTo(centerX + r, circleCenterY);
        holePath.arcTo(
          Rect.fromCenter(
            center: Offset(centerX, circleCenterY),
            width: holeW,
            height: holeW,
          ),
          0,
          -pi,
          false,
        );
        holePath.close();

        outlinePath.moveTo(centerX + r, circleCenterY);
        outlinePath.arcTo(
          Rect.fromCenter(
            center: Offset(centerX, circleCenterY),
            width: holeW,
            height: holeW,
          ),
          0,
          -pi,
          false,
        );
        outlinePath.lineTo(centerX - r, size.height);
        outlinePath.moveTo(centerX + r, size.height);
        outlinePath.lineTo(centerX + r, circleCenterY);
        break;

      case WallHoleType.rectangle:
        final holeW = size.shortestSide * _holeWidthRatioRect;
        final left = centerX - holeW / 2;
        final right = centerX + holeW / 2;
        holePath.addRect(Rect.fromLTRB(left, 0, right, size.height));
        outlinePath.moveTo(right, 0);
        outlinePath.lineTo(right, size.height);
        outlinePath.lineTo(left, size.height);
        outlinePath.lineTo(left, 0);
        outlinePath.close();
        break;
    }

    final cut = Path.combine(PathOperation.difference, fullRectPath, holePath);
    canvas.drawPath(cut, wallPaint);
    canvas.drawPath(cut, borderPaint);

    final energyGlow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..color = const Color(0xFF00E5FF).withOpacity(0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);

    final energyLine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = const Color(0xFF00E5FF).withOpacity(0.85);

    final energyMagenta = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFFF4DFF).withOpacity(0.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawPath(outlinePath, energyGlow);
    canvas.drawPath(outlinePath, energyLine);
    canvas.drawPath(outlinePath, energyMagenta);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
