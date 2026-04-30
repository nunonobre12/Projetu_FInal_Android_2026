
import 'package:flutter/material.dart';

void main() {
  runApp(const RacingGameApp());
}


class RacingGameApp extends StatelessWidget {
  const RacingGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CAR GAME',
      // [V1] Simple red theme applied globally
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE63946)),
        useMaterial3: true,
      ),
      home: const RacingGamePage(),
    );
  }
}


enum _GameView {
  menu,
  playing,
}


class RacingGamePage extends StatefulWidget {
  const RacingGamePage({super.key});

  @override
  State<RacingGamePage> createState() => _RacingGamePageState();
}

class _RacingGamePageState extends State<RacingGamePage> {
  _GameView _view = _GameView.menu;

  final TextEditingController _nameController = TextEditingController();
  String? _nameValidationMessage;
  String _activePlayerName = '';

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

 
  void _startGame() {
    final String username = _nameController.text.trim();
    if (username.isEmpty) {
      setState(() {
        _nameValidationMessage = 'Favor Insere Naran Antes Halimar';
      });
      return;
    }
    setState(() {
      _activePlayerName = username;
      _nameValidationMessage = null;
      _view = _GameView.playing;
    });
  }

  void _backToMenu() {
    setState(() {
      _view = _GameView.menu;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) {
      return _buildMenu();
    }
    // [V1] Placeholder playing screen - just a simple scaffold
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              'Playing as: $_activePlayerName',
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _backToMenu,
              child: const Text('Back to Menu'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu() {
    return Scaffold(
      body: Container(
        // [V1] Dark gradient background for the menu
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0xFF151A22),
              Color(0xFF0E1218),
              Color(0xFF171D25),
            ],
            stops: <double>[0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  // [V1] Game title text
                  const Text(
                    'CAR GAME',
                    style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.2,
                      color: Color(0xFFECEFF4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'HALAI HASORU OBSTAKULU SIRA',
                    style: TextStyle(
                      color: Color(0xFF9AA5B1),
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // [V1] Player name text field
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Naran Ita-nia',
                      labelStyle: const TextStyle(color: Colors.white60),
                      errorText: _nameValidationMessage,
                      filled: true,
                      fillColor: const Color(0xFF1C2330),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // [V1] Play button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _startGame,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE63946),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'HAHU JOGU',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
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
}
