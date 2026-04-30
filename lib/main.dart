
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE63946)),
        useMaterial3: true,
      ),
      home: const RacingGamePage(),
    );
  }
}

enum _GameView { menu, playing }

class RacingGamePage extends StatefulWidget {
  const RacingGamePage({super.key});

  @override
  State<RacingGamePage> createState() => _RacingGamePageState();
}

// SingleTickerProviderStateMixin enables the AnimationController
class _RacingGamePageState extends State<RacingGamePage>
    with SingleTickerProviderStateMixin {
  //  AnimationController acts as the game loop ticker
  late final AnimationController _ticker;

  static const double _playerWidthFactor = 0.16;
  static const double _playerHeightFactor = 0.13;
  static const List<String> _playerCarOptions = <String>[
    'assets/images/car_1.png',
    'assets/images/car_2.png',
    'assets/images/car_3.png',
    'assets/images/car_4.png',
  ];

  final TextEditingController _nameController = TextEditingController();

  _GameView _view = _GameView.menu;

  //  Player horizontal position (-1.0 to 1.0 normalised)
  double _playerX = 0;
  //  Road scroll offset drives the animated background
  double _roadOffset = 0;
  double _baseSpeed = 0.44;
  // ] Time tracking for frame-rate-independent movement
  double _lastPaintMicros = 0;
  double _elapsed = 0;
  double _smoothedDt = 0.016;
  String? _nameValidationMessage;
  //  Selected car asset for the player sprite
  String _selectedPlayerCarAsset = _playerCarOptions.first;

  @override
  void initState() {
    super.initState();
    // Create ticker and attach the _update listener
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(days: 1),
    )
      ..addListener(_update)
      ..forward();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ticker.dispose();
    super.dispose();
  }

  //  Warm up image assets when dependencies are ready
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final String asset in _playerCarOptions) {
      precacheImage(AssetImage(asset), context);
    }
  }

  void _startGame() {
    final String username = _nameController.text.trim();
    if (username.isEmpty) {
      setState(() => _nameValidationMessage = 'Favor Insere Naran Antes Halimar');
      return;
    }
    setState(() {
      _nameValidationMessage = null;
      _view = _GameView.playing;
      _playerX = 0;
      _roadOffset = 0;
      _elapsed = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    });
  }

  //  Game loop: called every frame by the AnimationController
  void _update() {
    final double now =
        _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    if (now == 0) return;

    final double rawDt = ((now - _elapsed) / 1000000).clamp(0.0, 0.04);
    //  Exponential smoothing prevents frame-spike jitter
    _smoothedDt = _smoothedDt * 0.82 + rawDt * 0.18;
    final double dt = _smoothedDt.clamp(0.0, 0.033);
    _elapsed = now;

    if (!mounted || _view != _GameView.playing) return;

    //  Scroll the road downward each frame
    _roadOffset += dt * (1.18 + _baseSpeed * 1.58);

    //  Throttle repaints to ~60fps to avoid over-rendering
    if (now - _lastPaintMicros >= 16000) {
      _lastPaintMicros = now;
      setState(() {});
    }
  }

  //  Move player left or right on swipe/button press
  void _steer(double delta) {
    if (_view != _GameView.playing) return;
    setState(() {
      _playerX = (_playerX + delta).clamp(-0.77, 0.77);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) return _buildMenu();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return GestureDetector(
            //  Drag gesture drives the steer function
            onPanUpdate: (details) =>
                _steer(details.delta.dx / constraints.maxWidth * 2.2),
            child: Stack(
              children: <Widget>[
                // Scrolling road layer fills the background
                Positioned.fill(child: _RoadLayer(offset: _roadOffset)),
                // Player car positioned near the bottom
                _buildPlayerCar(),
                //  Left/right arrow buttons for touch steering
                _buildTouchControls(),
              ],
            ),
          );
        },
      ),
    );
  }

  //  Renders the player's car sprite at the correct position
  Widget _buildPlayerCar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final double carW = w * _playerWidthFactor;
        final double carH = h * _playerHeightFactor;
        final double cx = w / 2 + _playerX * w / 2 - carW / 2;
        final double cy = h * 0.79 - carH / 2;
        return Stack(
          children: [
            Positioned(
              left: cx,
              top: cy,
              width: carW,
              height: carH,
              child: _CarSprite(assetPath: _selectedPlayerCarAsset),
            ),
          ],
        );
      },
    );
  }

  //  Left / right control buttons at the bottom of the screen
  Widget _buildTouchControls() {
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
          _ControlButton(
            icon: Icons.arrow_left_rounded,
            onPressed: () => _steer(-0.12),
          ),
          _ControlButton(
            icon: Icons.arrow_right_rounded,
            onPressed: () => _steer(0.12),
          ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMenu() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFF151A22), Color(0xFF0E1218), Color(0xFF171D25)],
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
                  const Text(
                    'CAR GAME',
                    style: TextStyle(
                      fontSize: 42, fontWeight: FontWeight.w900,
                      letterSpacing: 2.2, color: Color(0xFFECEFF4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'HALAI HASORU OBSTAKULU SIRA',
                    style: TextStyle(color: Color(0xFF9AA5B1), fontSize: 11,
                        letterSpacing: 1.0, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Insere Naran',
                      labelStyle: const TextStyle(color: Colors.white60),
                      errorText: _nameValidationMessage,
                      filled: true,
                      fillColor: const Color(0xFF1C2330),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // [V2 ADDED] Car selection row lets the player pick their car before starting
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: _playerCarOptions.asMap().entries.map((e) {
                      final bool selected = e.value == _selectedPlayerCarAsset;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedPlayerCarAsset = e.value),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected ? const Color(0xFF2ECC71) : Colors.white24,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: SizedBox(
                            width: 50,
                            height: 60,
                            child: _CarSprite(assetPath: e.value),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _startGame,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE63946),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('HAHU JOGU',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
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

//  _CarSprite - renders a car image from assets
class _CarSprite extends StatelessWidget {
  const _CarSprite({required this.assetPath});
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return Image.asset(assetPath, fit: BoxFit.contain);
  }
}

//  _RoadLayer - Custom painter that tiles and scrolls the road background
class _RoadLayer extends StatelessWidget {
  const _RoadLayer({required this.offset});
  final double offset;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _RoadPainter(offset: offset));
  }
}

class _RoadPainter extends CustomPainter {
  const _RoadPainter({required this.offset});
  final double offset;

  @override
  void paint(Canvas canvas, Size size) {
    //  Draw a simple dark road rectangle
    final Paint roadPaint = Paint()..color = const Color(0xFF1A1F28);
    canvas.drawRect(Offset.zero & size, roadPaint);

    //  Draw dashed lane dividers that scroll with offset
    final Paint dashPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 2;

    const int laneCount = 4;
    for (int i = 1; i < laneCount; i++) {
      final double x = size.width * i / laneCount;
      double y = -(offset % 40);
      while (y < size.height) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 20), dashPaint);
        y += 40;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RoadPainter oldDelegate) =>
      oldDelegate.offset != offset;
}

//  _ControlButton - circular left/right arrow buttons for steering
class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(26),
      child: Ink(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: <Color>[Color(0xFF2B313B), Color(0xFF191E26)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(0.24)),
        ),
        child: Icon(icon, size: 40, color: Colors.white),
      ),
    );
  }
}
