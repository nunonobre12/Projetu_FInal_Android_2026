import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

void main() => runApp(const RacingGameApp());

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

//  _EnemyCar holds position, lane, speed boost, and asset for each obstacle
class _EnemyCar {
  _EnemyCar({
    required this.lane,
    required this.x,
    required this.y,
    required this.speedBoost,
    required this.assetPath,
  });

  int lane;
  double x;
  double y;
  double speedBoost;
  String assetPath;
}

class RacingGamePage extends StatefulWidget {
  const RacingGamePage({super.key});

  @override
  State<RacingGamePage> createState() => _RacingGamePageState();
}

class _RacingGamePageState extends State<RacingGamePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

  //  Number of lanes on the road
  static const int _laneCount = 4;
  static const double _playerWidthFactor = 0.16;
  static const double _playerHeightFactor = 0.13;
  static const double _enemyWidthFactor = 0.155;
  static const double _enemyHeightFactor = 0.125;
  static const List<String> _playerCarOptions = <String>[
    'assets/images/car_1.png',
    'assets/images/car_2.png',
    'assets/images/car_3.png',
    'assets/images/car_4.png',
  ];
  //  Pool of enemy car images for random selection
  static const List<String> _enemyCarOptions = <String>[
    'assets/images/car_5.png',
    'assets/images/car_6.png',
    'assets/images/car_7.png',
    'assets/images/car_8.png',
    'assets/images/car_9.png',
    'assets/images/car_10.png',
  ];

  //  Random number generator for spawning and speed variation
  final Random _random = Random();
  //  Active enemies list
  final List<_EnemyCar> _enemies = <_EnemyCar>[];
  final TextEditingController _nameController = TextEditingController();

  _GameView _view = _GameView.menu;
  double _playerX = 0;
  double _roadOffset = 0;
  double _baseSpeed = 0.44;
  //  Difficulty ramps up over time
  double _difficulty = 0;
  //  Countdown until the next enemy wave spawns
  double _spawnTimer = 0;
  double _lastPaintMicros = 0;
  //  Total time the player has survived (drives difficulty)
  double _survivalTime = 0;
  double _elapsed = 0;
  double _smoothedDt = 0.016;
  String? _nameValidationMessage;
  String _activePlayerName = '';

  //  Current and best scores
  int _score = 0;
  int _bestScore = 0;
  //  Game state flags
  bool _isGameOver = false;
  bool _isCrashing = false;
  double _crashFxTime = 0;
  String _selectedPlayerCarAsset = _playerCarOptions.first;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_update)
      ..forward();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _startGame() {
    final String username = _nameController.text.trim();
    if (username.isEmpty) {
      setState(() => _nameValidationMessage = 'Favor Insere Naran Antes Halimar');
      return;
    }
    setState(() {
      _activePlayerName = username;
      _nameValidationMessage = null;
      _view = _GameView.playing;
      _resetState();
    });
  }

  void _backToMenu() {
    setState(() {
      _view = _GameView.menu;
      _isGameOver = false;
      _isCrashing = false;
      _enemies.clear();
      _playerX = 0;
    });
  }

  void _resetGame() {
    setState(() => _resetState());
  }

  //  Full game state reset - clears enemies, resets scores and timers
  void _resetState() {
    _enemies.clear();
    _playerX = 0;
    _roadOffset = 0;
    _baseSpeed = 0.5;
    _difficulty = 0;
    _spawnTimer = 0.62;
    _lastPaintMicros = 0;
    _survivalTime = 0;
    _elapsed = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    _smoothedDt = 0.016;
    _score = 0;
    _isGameOver = false;
    _isCrashing = false;
    _crashFxTime = 0;
  }

  void _update() {
    final double now = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    if (now == 0) return;

    final double rawDt = ((now - _elapsed) / 1000000).clamp(0.0, 0.04);
    _smoothedDt = _smoothedDt * 0.82 + rawDt * 0.18;
    final double dt = _smoothedDt.clamp(0.0, 0.033);
    _elapsed = now;

    if (!mounted || _view != _GameView.playing || _isGameOver) return;

    //  Run crash animation timer before everything else
    if (_isCrashing) {
      _crashFxTime = max(0, _crashFxTime - dt);
      if (_crashFxTime <= 0) _finishGameOver();
      if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
      return;
    }

    _survivalTime += dt;
    final double earlyRamp = (_survivalTime / 18).clamp(0.0, 1.0);
    _difficulty += dt * (0.032 + 0.03 * earlyRamp);
    final double speed = _baseSpeed + _pacedDifficulty() * (0.56 + earlyRamp * 0.34);
    _roadOffset += dt * (1.18 + speed * (1.58 + earlyRamp * 0.56));

    //  Move all enemies downward each frame
    for (final _EnemyCar enemy in _enemies) {
      enemy.y += dt * (0.72 + enemy.speedBoost + speed * 1.7);
    }

    //  Remove enemies that have scrolled off the bottom
    _enemies.removeWhere((enemy) => enemy.y > 1.3);

    //  Spawn new wave of enemies when timer elapses
    _spawnTimer -= dt;
    if (_spawnTimer <= 0) {
      _spawnEnemyWave();
      _spawnTimer = _nextSpawnDelay();
    }

    //  Increment score over time (faster at higher difficulty)
    _score += (dt * 90 * (1 + _difficulty)).round();

    //  Check for collision every frame
    if (_findCollidingEnemy() != null) {
      _triggerCrashEffect();
      return;
    }

    if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
  }

  double _pacedDifficulty() => min(_difficulty, 1.48);

  //  Calculate delay until the next enemy wave based on difficulty
  double _nextSpawnDelay() {
    final double earlyAssist = _survivalTime < 15 ? (15 - _survivalTime) / 15 : 0;
    final double baseDelay = max(0.24, 0.82 - _pacedDifficulty() * 0.28);
    final double jitter = 0.9 + _random.nextDouble() * 0.34;
    return baseDelay * jitter + earlyAssist * 0.22;
  }

  //  Spawn one or more enemies in random lanes each wave
  void _spawnEnemyWave() {
    final List<int> lanes = List<int>.generate(_laneCount, (i) => i)..shuffle(_random);
    for (final int lane in lanes) {
      if (_canSpawnInLane(lane)) {
        _spawnEnemyInLane(lane);
        break;
      }
    }
  }

  //  Ensure there is enough vertical gap before spawning in a lane
  bool _canSpawnInLane(int lane) {
    const double spawnY = -1.24;
    const double minGap = 0.64;
    return !_enemies.any(
      (enemy) => enemy.lane == lane && enemy.y < -0.35 && (enemy.y - spawnY).abs() < minGap,
    );
  }

  //  Create a new enemy car in the given lane
  void _spawnEnemyInLane(int lane, {double? xOverride}) {
    final double laneWidth = 2 / _laneCount;
    final double x = xOverride ?? (-1 + laneWidth * lane + laneWidth / 2);
    _enemies.add(_EnemyCar(
      lane: lane,
      x: x,
      y: -1.24,
      speedBoost: 0.04 + _random.nextDouble() * 0.34,
      assetPath: _enemyCarOptions[_random.nextInt(_enemyCarOptions.length)],
    ));
  }

  //  Axis-aligned bounding box for the player car
  Rect _playerHitBox() {
    return Rect.fromCenter(
      center: Offset(_playerX, 0.79),
      width: _playerWidthFactor * 0.86,
      height: _playerHeightFactor * 0.9,
    ).inflate(0.01);
  }

  //  Axis-aligned bounding box for a specific enemy car
  Rect _enemyHitBox(_EnemyCar enemy) {
    return Rect.fromCenter(
      center: Offset(enemy.x, enemy.y),
      width: _enemyWidthFactor * 0.84,
      height: _enemyHeightFactor * 0.9,
    ).inflate(0.008);
  }

  //  Scan enemy list and return the first car overlapping the player
  _EnemyCar? _findCollidingEnemy() {
    final Rect playerRect = _playerHitBox();
    for (final _EnemyCar enemy in _enemies) {
      if (playerRect.overlaps(_enemyHitBox(enemy))) return enemy;
    }
    return null;
  }

  //  Begin the crash visual effect (short timer before game-over screen)
  void _triggerCrashEffect() {
    if (_isCrashing || _isGameOver) return;
    setState(() {
      _isCrashing = true;
      _crashFxTime = 0.72;
    });
  }

  //  Finalise game over - save best score and show overlay
  void _finishGameOver() {
    setState(() {
      _isGameOver = true;
      _isCrashing = false;
      _crashFxTime = 0;
      _bestScore = max(_bestScore, _score);
    });
  }

  void _steer(double delta) {
    if (_isGameOver || _isCrashing || _view != _GameView.playing) return;
    setState(() { _playerX = (_playerX + delta).clamp(-0.77, 0.77); });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) return _buildMenu();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onPanUpdate: (d) => _steer(d.delta.dx / constraints.maxWidth * 2.2),
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _RoadLayer(offset: _roadOffset)),
                // . Render all active enemy cars
                ..._enemies.map((enemy) => _buildEnemy(enemy, constraints)),
                _buildPlayerCar(constraints),
                // . Heads-up display showing current score
                _buildHud(),
                //  Game over overlay with restart button
                if (_isGameOver) _buildGameOverOverlay(),
                _buildTouchControls(),
              ],
            ),
          );
        },
      ),
    );
  }

  //  Render a single enemy car at its normalised position
  Widget _buildEnemy(_EnemyCar enemy, BoxConstraints c) {
    final double w = c.maxWidth;
    final double h = c.maxHeight;
    final double carW = w * _enemyWidthFactor;
    final double carH = h * _enemyHeightFactor;
    final double cx = w / 2 + enemy.x * w / 2 - carW / 2;
    final double cy = h / 2 + enemy.y * h / 2 - carH / 2;
    return Positioned(
      left: cx, top: cy, width: carW, height: carH,
      child: _CarSprite(assetPath: enemy.assetPath),
    );
  }

  Widget _buildPlayerCar(BoxConstraints c) {
    final double w = c.maxWidth;
    final double h = c.maxHeight;
    final double carW = w * _playerWidthFactor;
    final double carH = h * _playerHeightFactor;
    return Positioned(
      left: w / 2 + _playerX * w / 2 - carW / 2,
      top: h * 0.79 - carH / 2,
      width: carW, height: carH,
      child: _CarSprite(assetPath: _selectedPlayerCarAsset),
    );
  }

  //  Score and best score HUD in the top-left corner
  Widget _buildHud() {
    return Positioned(
      top: 16, left: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Score: $_score',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          Text('Best: $_bestScore',
              style: const TextStyle(color: Color(0xFFFFBE0B), fontSize: 14)),
        ],
      ),
    );
  }

  //  Full-screen overlay shown when the player crashes
  Widget _buildGameOverOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text('GAME OVER',
                  style: TextStyle(color: Colors.red, fontSize: 36, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              Text('Score: $_score',
                  style: const TextStyle(color: Colors.white, fontSize: 24)),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _resetGame, child: const Text('Play Again')),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: _backToMenu,
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Main Menu')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTouchControls() {
    return Positioned(
      left: 0, right: 0, bottom: 24,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _ControlButton(icon: Icons.arrow_left_rounded, onPressed: () => _steer(-0.12)),
          _ControlButton(icon: Icons.arrow_right_rounded, onPressed: () => _steer(0.12)),
        ],
      ),
    );
  }

  Widget _buildMenu() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFF151A22), Color(0xFF0E1218), Color(0xFF171D25)],
            stops: <double>[0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Text('CAR GAME',
                        style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900,
                            letterSpacing: 2.2, color: Color(0xFFECEFF4))),
                    const SizedBox(height: 32),
                    const Text('HILI KARETA',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white70)),
                    const SizedBox(height: 16),
                    Center(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 16,
                        runSpacing: 16,
                        children: List.generate(
                          _playerCarOptions.length,
                          (index) {
                            final String carAsset = _playerCarOptions[index];
                            final bool isSelected = carAsset == _selectedPlayerCarAsset;
                            return GestureDetector(
                              onTap: () => setState(() => _selectedPlayerCarAsset = carAsset),
                              child: Container(
                                width: 100,
                                height: 100,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: isSelected ? const Color(0xFFE63946) : Colors.white24,
                                    width: isSelected ? 3 : 1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  color: isSelected ? const Color(0xFF2B313B) : const Color(0xFF1C2330),
                                ),
                                child: Image.asset(carAsset, fit: BoxFit.contain),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'INSERE NARAN',
                        labelStyle: const TextStyle(color: Colors.white60),
                        errorText: _nameValidationMessage,
                        filled: true, fillColor: const Color(0xFF1C2330),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
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
      ),
    );
  }
}

class _CarSprite extends StatelessWidget {
  const _CarSprite({required this.assetPath});
  final String assetPath;
  @override
  Widget build(BuildContext context) => Image.asset(assetPath, fit: BoxFit.contain);
}

class _RoadLayer extends StatelessWidget {
  const _RoadLayer({required this.offset});
  final double offset;
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _RoadPainter(offset: offset));
}

class _RoadPainter extends CustomPainter {
  const _RoadPainter({required this.offset});
  final double offset;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1F28));
    final Paint p = Paint()..color = Colors.white24..strokeWidth = 2;
    for (int i = 1; i < 4; i++) {
      final double x = size.width * i / 4;
      double y = -(offset % 40);
      while (y < size.height) { canvas.drawLine(Offset(x, y), Offset(x, y + 20), p); y += 40; }
    }
  }
  @override
  bool shouldRepaint(covariant _RoadPainter old) => old.offset != offset;
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed, borderRadius: BorderRadius.circular(26),
      child: Ink(
        width: 70, height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: <Color>[Color(0xFF2B313B), Color(0xFF191E26)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(0.24)),
        ),
        child: Icon(icon, size: 40, color: Colors.white),
      ),
    );
  }
}