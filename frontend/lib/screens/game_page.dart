import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:ui'; // ✅ 确保文件顶部有这个

// 后端 API 地址，可根据实际部署修改
const String _apiBaseUrl = 'http://localhost:8000';

/// 墙洞相对屏幕短边的宽度比例，判定与绘制共用
const double _holeWidthRatio = 0.85;

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

  /// 当前检测到的关键点 [x_norm, y_norm, confidence]，归一化到 [0,1]
  List<List<double>> _keypoints = [];
  int _imageWidth = 0;
  int _imageHeight = 0;

  /// 过关判定结果：null=未判定，true=过关，false=未过关
  bool? _gameResult;
  Timer? _poseDetectionTimer;
  bool _checkTriggered = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _wallAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    // 墙缩放至 1.0 时与屏幕完全吻合
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
    // 当墙缩放至 1.0 时进行判定（完全吻合）
    if (_wallScaleAnimation.value >= 0.99 && !_checkTriggered) {
      _triggerPassFailCheck();
    }
  }

  Future<void> _triggerPassFailCheck() async {
    if (_checkTriggered) return;
    _checkTriggered = true;
    _poseDetectionTimer?.cancel();

    // 用「墙闭合瞬间」的一帧做判定，避免用 0~800ms 前的旧关键点误判
    await _finalCaptureAndCheck();
  }

  /// 拍一张最终帧，等 API 返回后用该帧关键点做过关判定
  Future<void> _finalCaptureAndCheck() async {
    final size = MediaQuery.of(context).size;
    if (_controller == null || !_controller!.value.isInitialized || !mounted) {
      if (mounted) setState(() => _gameResult = false);
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
        setState(() => _gameResult = false);
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final kpts = (data['keypoints'] as List<dynamic>?)
          ?.map((e) => (e as List<dynamic>).map((v) => (v as num).toDouble()).toList())
          .toList();
      final w = (data['image_width'] as num?)?.toInt() ?? 0;
      final h = (data['image_height'] as num?)?.toInt() ?? 0;
      final passed = _checkKeypointsInHoleWithKeypoints(size, kpts ?? [], w, h);
      if (mounted) {
        setState(() {
          _keypoints = kpts ?? [];
          _imageWidth = w;
          _imageHeight = h;
          _gameResult = passed;
        });
      }
    } catch (e) {
      debugPrint('Final capture/check error: $e');
      if (mounted) setState(() => _gameResult = false);
    }
  }

  /// 过关判定：墙闭合瞬间，该帧检测到的所有关键点均在该瞬间墙的空洞内（与绘制用同一空洞参数）
  bool _checkKeypointsInHoleWithKeypoints(
    Size screenSize,
    List<List<double>> keypoints,
    int imageWidth,
    int imageHeight,
  ) {
    if (keypoints.isEmpty) return false;
    final holeW = screenSize.shortestSide * _holeWidthRatio;
    final r = holeW / 2;
    final centerX = screenSize.width * 0.5;
    final circleCenterY = screenSize.height - r;
    for (final kp in keypoints) {
      if (kp.length < 2) continue;
      final screenPos = _normToScreenWithSize(kp[0], kp[1], screenSize, imageWidth, imageHeight);
      if (!_pointInSemicircle(screenPos.dx, screenPos.dy, centerX, circleCenterY, r)) {
        return false;
      }
    }
    return true;
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

  bool _pointInSemicircle(double px, double py, double cx, double cy, double r) {
    final dx = px - cx;
    final dy = py - cy;
    if (py < cy) return false; // 在半圆直径上方则不在洞内
    return (dx * dx + dy * dy) <= (r * r);
  }

  /// 将归一化坐标 [0,1] 转换为屏幕坐标（考虑 FittedBox cover 与前置摄像头镜像）
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() {
          _cameraError = '未检测到摄像头';
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
        _cameraError = '摄像头初始化失败: $e';
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
        setState(() {
          _keypoints = kpts ?? [];
          _imageWidth = (data['image_width'] as num?)?.toInt() ?? 0;
          _imageHeight = (data['image_height'] as num?)?.toInt() ?? 0;
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
      _gameStarted = false;
    });
    _wallAnimationController.reset();
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

  /// 始终显示实时摄像头预览，不替换为静态图，保证画面持续可见
  Widget _buildVideoDisplay() {
    return _buildCameraPreview();
  }

  /// 在摄像头画面上叠加关键点（游戏进行中且有关键点数据时）
  Widget _buildKeypointsOverlay() {
    final size = MediaQuery.of(context).size;
    return IgnorePointer(
      child: CustomPaint(
        size: size,
        painter: KeypointsOverlayPainter(
          keypoints: _keypoints,
          imageWidth: _imageWidth,
          imageHeight: _imageHeight,
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
            Text('正在启动摄像头...', style: TextStyle(color: Colors.white70)),
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
                  const Text(
                    '关卡 1',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '难度：简单',
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
                        '开始',
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
                holeType: WallHoleType.semicircle,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildResultIsland() {
    final passed = _gameResult!;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2F17).withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: passed ? const Color(0xFF4CAF50) : const Color(0xFFE53935),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 28,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: (passed ? const Color(0xFF4CAF50) : const Color(0xFFE53935)).withOpacity(0.3),
                blurRadius: 36,
                spreadRadius: -4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                passed ? Icons.emoji_events : Icons.cancel,
                size: 64,
                color: passed ? const Color(0xFF4CAF50) : const Color(0xFFE53935),
              ),
              const SizedBox(height: 16),
              Text(
                passed ? '过关' : '未过关',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: passed ? const Color(0xFF4CAF50) : const Color(0xFFE53935),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                passed ? '所有关键点均在空洞内！' : '部分关键点触碰墙体',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: _goHome,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: BorderSide(color: Colors.white.withOpacity(0.5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('返回主页'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _playAgain,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF3D7A35),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('再玩一次'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 在摄像头画面上绘制关键点（与 _normToScreen 一致的 cover + 前置镜像）
class KeypointsOverlayPainter extends CustomPainter {
  KeypointsOverlayPainter({
    required this.keypoints,
    required this.imageWidth,
    required this.imageHeight,
  });

  final List<List<double>> keypoints;
  final int imageWidth;
  final int imageHeight;

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
    final pointPaint = Paint()
      ..color = const Color(0xFF3D7A35)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final kp in keypoints) {
      if (kp.length < 2) continue;
      final pos = _normToScreen(kp[0], kp[1], size, imageWidth, imageHeight);
      canvas.drawCircle(pos, 8, pointPaint);
      canvas.drawCircle(pos, 8, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant KeypointsOverlayPainter oldDelegate) {
    return oldDelegate.keypoints != keypoints ||
        oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight;
  }
}

enum WallHoleType { semicircle }

class WallPainter extends CustomPainter {
  WallPainter({required this.holeType});

  final WallHoleType holeType;

  @override
  void paint(Canvas canvas, Size size) {
    final wallPaint = Paint()
      ..color = const Color(0xFF1A2F17).withOpacity(0.88)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = const Color(0xFF3D7A35).withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    final rect = Offset.zero & size;
    final fullRectPath = Path()..addRect(rect);

    final centerX = size.width * 0.5;
    final holeW = size.shortestSide * _holeWidthRatio;
    final r = holeW / 2;
    final circleCenterY = size.height - r;

    final holePath = Path();
    switch (holeType) {
      case WallHoleType.semicircle:
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
        break;
    }

    final path = Path.combine(PathOperation.difference, fullRectPath, holePath);
    canvas.drawPath(path, wallPaint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
