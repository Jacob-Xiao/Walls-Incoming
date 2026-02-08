import 'package:flutter/material.dart';
import 'package:wallsincoming/screens/game_page.dart';
import 'package:wallsincoming/widgets/cyber_road_crowd_background.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: CyberRoadCrowdBackground(), // ✅ 动态背景：路+人群
          ),

          // ✅ 你原来的 UI（标题+按钮）放上面
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFF00E5FF), // cyan
                      Color(0xFFFF4DFF), // magenta
                      Color(0xFF7CFC00), // electric green
                    ],
                  ).createShader(bounds),
                  child: const Text(
                    'Walls Incoming',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '墙来了',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white.withOpacity(0.75),
                    letterSpacing: 10,
                  ),
                ),
                const Spacer(flex: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (context) => const GamePage()),
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: const Color(0xFF081018),
                        elevation: 10,
                        shadowColor: const Color(0xFF00E5FF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        '开始游戏',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
