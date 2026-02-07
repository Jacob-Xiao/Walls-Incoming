import 'package:flutter/material.dart';
import 'package:wallsincoming/screens/home_page.dart';

void main() {
  runApp(const WallsIncomingApp());
}

class WallsIncomingApp extends StatelessWidget {
  const WallsIncomingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walls Incoming',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D5A27),
          brightness: Brightness.dark,
          primary: const Color(0xFF3D7A35),
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomePage(),
    );
  }
}
