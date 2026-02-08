import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi;
import 'dart:typed_data';
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

  /// 当前检测到的关键点 [x_norm, y_norm, confidence]，来自 result.keypoints.xyn 归一化 [0,1]
  List<List<double>> _keypoints = [];
  int _imageWidth = 0;
  int _imageHeight = 0;

  /// 后端返回的 YOLO plot 图像流（img = results.plot(line_width=1)）
  Uint8List? _annotatedImageBytes;

  /// 过关判定结果：null=未判定，true=过关，false=未过关
  bool? _gameResult;

  /// 未过关时，覆盖在墙上的关键点索引
  List<int> _failedKeypointIndices = [];
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

    // 墙闭合的最后一帧进行判定，取该帧的墙进行对比判断
    await _finalCaptureAndCheck();
  }

  /// 拍墙闭合的最后一帧，等 API 返回后用该帧关键点与墙对比判定（有关键点覆盖在墙上则不通过）
  Future<void> _finalCaptureAndCheck() async {
    final size = MediaQuery.of(context).size;
    if (_controller == null || !_controller!.value.isInitialized || !mounted) {
      if (mounted) setState(() {
        _gameResult = false;
        _failedKeypointIndices = [];
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
      final annBase64 = data['annotated_image_base64'] as String?;
      final annBytes = annBase64 != null && annBase64.isNotEmpty
          ? Uint8List.fromList(base64Decode(annBase64))
          : null;
      if (mounted) {
        setState(() {
          _keypoints = kpts ?? [];
          _imageWidth = w;
          _imageHeight = h;
          _annotatedImageBytes = annBytes;
          _gameResult = passed;
          _failedKeypointIndices = passed ? [] : failedIndices;
        });
      }
    } catch (e) {
      debugPrint('Final capture/check error: $e');
      if (mounted) setState(() {
        _gameResult = false;
        _failedKeypointIndices = [];
      });
    }
  }

  /// 过关判定：墙闭合最后一帧，取该帧的墙进行对比；若有关键点覆盖在墙上则不通过
  /// 返回 (是否过关, 覆盖在墙上的关键点索引列表)
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

  /// 构建与 WallPainter 完全一致的空洞路径（供 contains 判断）
  Path _buildHolePath(Size size) {
    final centerX = size.width * 0.5;
    final holeW = size.shortestSide * _holeWidthRatio;
    final r = holeW / 2;
    final circleCenterY = size.height - r;
    final holePath = Path();
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

  /// 游戏进行中显示后端返回的 YOLO 标注图像流（镜像翻转）；否则显示摄像头预览
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

  /// 在视频流画面上叠加关键点：绿色为正常，游戏结束未过关的点为红色
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



/// 在视频流画面上绘制关键点：绿色为正常，未过关的点为红色
/// failedIndices：未过关时，覆盖在墙上的关键点索引，将以红色显示
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

enum WallHoleType { semicircle }

class WallPainter extends CustomPainter {
  WallPainter({required this.holeType});

  final WallHoleType holeType;

  @override
  void paint(Canvas canvas, Size size) {
    // 墙体：更偏赛博深色
    final wallPaint = Paint()
      ..color = const Color(0xFF0A0F1E).withOpacity(0.82)
      ..style = PaintingStyle.fill;

    // 墙体边框：霓虹青
    final borderPaint = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final rect = Offset.zero & size;
    final fullRectPath = Path()..addRect(rect);

    final centerX = size.width * 0.5;
    final holeW = size.shortestSide * _holeWidthRatio;
    final r = holeW / 2;
    final circleCenterY = size.height - r;

    // ===== 洞（用于挖空：必须闭合，包含底边没关系）=====
    final holePath = Path();

    // ✅ 只用于画门框的轮廓（不画底边线）
    final outlinePath = Path();

    switch (holeType) {
      case WallHoleType.semicircle:
        // --- 挖洞 path（闭合）---
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

        // --- 门框轮廓 path（不画底边）---
        // 1) 画上半圆弧（从右侧到左侧）
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

        // 2) 左竖边（从左侧弧端往下）
        outlinePath.lineTo(centerX - r, size.height);

        // 3) 右竖边（单独一段，避免画底边）
        outlinePath.moveTo(centerX + r, size.height);
        outlinePath.lineTo(centerX + r, circleCenterY);
        break;
    }

    // 挖洞
    final cut = Path.combine(PathOperation.difference, fullRectPath, holePath);

    // 先画墙
    canvas.drawPath(cut, wallPaint);

    // 墙外边框（如果你也不想它画底边，我后面可以再帮你改成 outline 版）
    canvas.drawPath(cut, borderPaint);

    // ===== 能量门框：沿洞边发光（不含底边）=====
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

    // ✅ 用 outlinePath 画门框（没有底部那条线）
    canvas.drawPath(outlinePath, energyGlow);
    canvas.drawPath(outlinePath, energyLine);
    canvas.drawPath(outlinePath, energyMagenta);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
