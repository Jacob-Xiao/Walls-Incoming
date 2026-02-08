import 'dart:math';
import 'package:flutter/material.dart';

double lerp(double a, double b, double t) => a + (b - a) * t;

class CyberRoadCrowdBackground extends StatefulWidget {
  const CyberRoadCrowdBackground({super.key});

  @override
  State<CyberRoadCrowdBackground> createState() => _CyberRoadCrowdBackgroundState();
}

class _CyberRoadCrowdBackgroundState extends State<CyberRoadCrowdBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Runner> runners;
  final rnd = Random(42);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
    runners = List.generate(70, (_) => _Runner.random(rnd));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return CustomPaint(
          painter: _CyberRoadCrowdPainter(t: _c.value, runners: runners),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _Runner {
  double z; // 0 远 -> 1 近
  int side; // -1 左 / +1 右
  double laneOffset;
  double speed;
  final Color bodyColor;
  final Color accentColor;

  _Runner(this.z, this.side, this.laneOffset, this.speed, this.bodyColor, this.accentColor);

  factory _Runner.random(Random rnd) {
    Color neon() {
      final h = rnd.nextDouble() * 360;
      return HSVColor.fromAHSV(1, h, 0.85, 0.95).toColor();
    }

    return _Runner(
      rnd.nextDouble(),
      rnd.nextBool() ? -1 : 1,
      0.12 + rnd.nextDouble() * 0.95,
      0.6 + rnd.nextDouble() * 1.2,
      neon(),
      neon(),
    );
  }
}

class _CyberRoadCrowdPainter extends CustomPainter {
  final double t;
  final List<_Runner> runners;

  _CyberRoadCrowdPainter({required this.t, required this.runners});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final horizonY = size.height * 0.28;

    // ===== 赛博夜空渐变（蓝紫霓虹背景）=====
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF050016),
          Color(0xFF060B2E),
          Color(0xFF02010A),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    // ===== 霓虹雾带 =====
    final fogShader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Color(0xFF00E5FF), Color(0xFFFF4DFF)],
    ).createShader(
      Rect.fromLTWH(0, size.height * 0.18, size.width, size.height * 0.25),
    );

    final fog = Paint()
      ..shader = fogShader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40)
      ..color = Colors.white.withOpacity(0.12);

    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.2, size.width, size.height * 0.22),
      fog,
    );

    // ===== 城市天际线 =====
    _drawCity(canvas, size, horizonY);

    // ===== 赛道（透视梯形）=====
    final roadTopW = size.width * 0.16;
    final roadBottomW = size.width * 0.94;

    final roadPath = Path()
      ..moveTo(cx - roadTopW / 2, horizonY)
      ..lineTo(cx + roadTopW / 2, horizonY)
      ..lineTo(cx + roadBottomW / 2, size.height)
      ..lineTo(cx - roadBottomW / 2, size.height)
      ..close();

    canvas.drawPath(
      roadPath,
      Paint()..color = const Color(0xFF070A14).withOpacity(0.85),
    );

    // 霓虹路边 glow
    final edgeGlowCyan = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF00E5FF).withOpacity(0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawPath(roadPath, edgeGlowCyan);

    final edgeGlowMagenta = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFFF4DFF).withOpacity(0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawPath(roadPath, edgeGlowMagenta);

    // 中线虚线（速度感）
    _drawDashes(canvas, size, cx, horizonY);

    // 两侧彩色观众/角色跑动
    _drawCrowd(canvas, size, cx, horizonY, roadTopW, roadBottomW);

    // 暗角聚焦
    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.topCenter,
        radius: 1.2,
        colors: [Colors.transparent, Colors.black.withOpacity(0.62)],
        stops: const [0.45, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  void _drawCity(Canvas canvas, Size size, double horizonY) {
    final rnd = Random(7);
    final cityBaseY = horizonY + size.height * 0.02;

    final skylinePaint = Paint()..color = const Color(0xFF0B0F2A).withOpacity(0.85);
    final windowPaint = Paint()..color = const Color(0xFFB6FFD1).withOpacity(0.18);

    double x = 0;
    while (x < size.width) {
      final w = 28 + rnd.nextInt(60).toDouble();
      final h = 30 + rnd.nextInt(110).toDouble();
      final rect = Rect.fromLTWH(x, cityBaseY - h, w, h);
      canvas.drawRect(rect, skylinePaint);

      for (int i = 0; i < 10; i++) {
        if (rnd.nextDouble() < 0.5) continue;
        final wx = rect.left + 6 + rnd.nextDouble() * (w - 12);
        final wy = rect.top + 6 + rnd.nextDouble() * (h - 12);
        canvas.drawRect(Rect.fromLTWH(wx, wy, 3, 5), windowPaint);
      }

      x += w + 6;
    }
  }

  void _drawDashes(Canvas canvas, Size size, double cx, double horizonY) {
    final dashPaint = Paint()..color = const Color(0xFFBFEFFF).withOpacity(0.65);
    final glow = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    const baseSpeed = 1.9;
    for (int i = 0; i < 18; i++) {
      final p = ((i / 18) + t * baseSpeed) % 1.0;
      final z = p;

      final y = horizonY + (size.height - horizonY) * pow(z, 1.7).toDouble();
      final dashLen = lerp(10, 50, pow(z, 1.45).toDouble())!;
      final dashW = lerp(2, 9, pow(z, 1.45).toDouble())!;

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, y), width: dashW, height: dashLen),
        const Radius.circular(10),
      );

      canvas.drawRRect(rect, glow);
      canvas.drawRRect(rect, dashPaint);
    }
  }

  void _drawCrowd(
    Canvas canvas,
    Size size,
    double cx,
    double horizonY,
    double roadTopW,
    double roadBottomW,
  ) {
    final glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);

    for (final r in runners) {
      final z = (r.z + t * 0.92 * r.speed) % 1.0;

      final scale = lerp(0.10, 1.12, pow(z, 1.6).toDouble())!;
      final y = horizonY + (size.height - horizonY) * pow(z, 1.55).toDouble();
      final roadW = roadTopW + (roadBottomW - roadTopW) * pow(z, 1.25).toDouble();

      final sideX = cx + r.side * (roadW / 2 + lerp(10, 95, r.laneOffset)!);

      final brightness = lerp(0.38, 1.0, pow(z, 1.3).toDouble())!;
      final bodyColor = _scaleColor(r.bodyColor, brightness);
      final accent = _scaleColor(r.accentColor, brightness);

      final bodyPaint = Paint()..color = bodyColor;
      glow.color = accent.withOpacity(0.32);

      final headR = 7.4 * scale;
      final bodyH = 28 * scale;
      final bodyW = 12 * scale;

      final swing = sin((t * 2 * pi * 2.2) + z * 8).toDouble() * 6.0 * scale;

      final head = Offset(sideX, y - bodyH * 0.72);
      final bodyRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(sideX, y - bodyH * 0.15), width: bodyW, height: bodyH),
        Radius.circular(10 * scale),
      );

      // glow first
      canvas.drawCircle(head, headR * 1.35, glow);
      canvas.drawRRect(bodyRect.inflate(3 * scale), glow);

      // body
      canvas.drawCircle(head, headR, bodyPaint);
      canvas.drawRRect(bodyRect, bodyPaint);

      // accessory
      canvas.drawCircle(
        head + Offset(headR * 0.72, -headR * 0.6),
        2.1 * scale,
        Paint()..color = Colors.white.withOpacity(0.9),
      );

      // legs
      final legPaint = Paint()
        ..color = accent
        ..strokeWidth = 3.2 * scale
        ..strokeCap = StrokeCap.round;

      final hip = Offset(sideX, y + bodyH * 0.2);
      canvas.drawLine(hip, hip + Offset(-6 * scale, 14 * scale + swing), legPaint);
      canvas.drawLine(hip, hip + Offset(6 * scale, 14 * scale - swing), legPaint);
    }
  }

  Color _scaleColor(Color c, double k) {
    final h = HSVColor.fromColor(c);
    return h.withValue((h.value * k).clamp(0.0, 1.0)).toColor();
  }

  @override
  bool shouldRepaint(covariant _CyberRoadCrowdPainter oldDelegate) => oldDelegate.t != t;
}
