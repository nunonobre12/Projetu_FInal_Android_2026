

import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
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

class _EnemyCar {
  _EnemyCar({required this.lane, required this.x, required this.y,
      required this.speedBoost, required this.assetPath});
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

  static const int _laneCount = 4;
  static const double _playerWidthFactor = 0.16;
  static const double _playerHeightFactor = 0.13;
  static const double _enemyWidthFactor = 0.155;
  static const double _enemyHeightFactor = 0.125;
  static const List<String> _playerCarOptions = <String>[
    'assets/images/car_1.png', 'assets/images/car_2.png',
    'assets/images/car_3.png', 'assets/images/car_4.png',
  ];
  static const List<String> _enemyCarOptions = <String>[
    'assets/images/car_5.png', 'assets/images/car_6.png',
    'assets/images/car_7.png', 'assets/images/car_8.png',
    'assets/images/car_9.png', 'assets/images/car_10.png',
  ];

  // [V4 ADDED] Audio asset path constants
  static const String _menuMusicAsset     = 'audio/menu_music.wav';
  static const String _gameplayMusicAsset = 'audio/gameplay_music.wav';
  static const String _engineLoopAsset    = 'audio/engine_loop.wav';
  static const String _crashSfxAsset      = 'audio/crash.wav';
  static const String _buttonTapSfxAsset  = 'audio/button_tap.wav';
  static const String _steerSfxAsset      = 'audio/steer.wav';

  final Random _random = Random();
  final List<_EnemyCar> _enemies = <_EnemyCar>[];
  final TextEditingController _nameController = TextEditingController();

  // [V4 ADDED] Dedicated AudioPlayer instances for music, engine, and SFX channels
  final AudioPlayer _musicPlayer   = AudioPlayer();
  final AudioPlayer _enginePlayer  = AudioPlayer();
  final AudioPlayer _sfxPlayer     = AudioPlayer();
  final AudioPlayer _sfxAltPlayer  = AudioPlayer();

  _GameView _view = _GameView.menu;
  double _playerX = 0;
  double _roadOffset = 0;
  double _baseSpeed = 0.44;
  double _difficulty = 0;
  double _spawnTimer = 0;
  double _lastPaintMicros = 0;
  double _survivalTime = 0;
  double _elapsed = 0;
  double _smoothedDt = 0.016;

  // [V4 ADDED] Volume controls
  double _masterVolume = 0.82;
  double _musicMixVolume = 0.44;
  final double _engineMixVolume = 0.3;
  // [V4 ADDED] Steer SFX throttle to avoid sound spam
  double _steerSfxCooldown = 0;

  // [V4 ADDED] Track which music track is currently playing to avoid restarting
  String? _currentMusicAsset;
  // [V4 ADDED] Whether the engine loop is active
  bool _isEngineLooping = false;

  String? _nameValidationMessage;
  String _activePlayerName = '';
  int _score = 0;
  int _bestScore = 0;
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
    // [V4 ADDED] Initialise audio players and start menu music immediately
    unawaited(_initAudio());
  }

  @override
  void dispose() {
    _nameController.dispose();
    // [V4 ADDED] Dispose all audio players on widget teardown
    _musicPlayer.dispose();
    _enginePlayer.dispose();
    _sfxPlayer.dispose();
    _sfxAltPlayer.dispose();
    _ticker.dispose();
    super.dispose();
  }

  // [V4 ADDED] Configures release modes and starts menu music
  Future<void> _initAudio() async {
    await _musicPlayer.setReleaseMode(ReleaseMode.loop);
    await _enginePlayer.setReleaseMode(ReleaseMode.loop);
    await _sfxPlayer.setReleaseMode(ReleaseMode.stop);
    await _sfxAltPlayer.setReleaseMode(ReleaseMode.stop);
    await _setMusicTrack(_menuMusicAsset, volume: 0.44);
  }

  // [V4 ADDED] Scale any base volume by the master volume slider
  double _scaledVolume(double baseVolume) =>
      (baseVolume * _masterVolume).clamp(0.0, 1.0);

  // [V4 ADDED] Apply master volume change to all active players
  Future<void> _applyMasterVolume() async {
    try {
      await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume));
      await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume));
    } catch (_) {}
  }

  void _setMasterVolume(double value) {
    setState(() => _masterVolume = value.clamp(0.0, 1.0));
    unawaited(_applyMasterVolume());
  }

  // [V4 ADDED] Switch the looping music track (no-op if already playing)
  Future<void> _setMusicTrack(String asset, {required double volume}) async {
    _musicMixVolume = volume;
    if (_currentMusicAsset == asset) {
      await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume));
      return;
    }
    _currentMusicAsset = asset;
    try {
      await _musicPlayer.stop();
      await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume));
      await _musicPlayer.play(AssetSource(asset));
    } catch (_) {}
  }

  Future<void> _stopMusic() async {
    _currentMusicAsset = null;
    try { await _musicPlayer.stop(); } catch (_) {}
  }

  // [V4 ADDED] Start the looping engine sound when gameplay begins
  Future<void> _startEngineLoop() async {
    if (_isEngineLooping) return;
    _isEngineLooping = true;
    try {
      await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume));
      await _enginePlayer.play(AssetSource(_engineLoopAsset));
    } catch (_) {}
  }

  // [V4 ADDED] Stop the engine loop (on crash, pause, or menu)
  Future<void> _stopEngineLoop() async {
    _isEngineLooping = false;
    try { await _enginePlayer.stop(); } catch (_) {}
  }

  // [V4 ADDED] Play a one-shot sound effect on either sfx channel
  Future<void> _playSfx(String asset, {double volume = 1, bool useAlt = false}) async {
    final AudioPlayer player = useAlt ? _sfxAltPlayer : _sfxPlayer;
    try {
      await player.stop();
      await player.setVolume(_scaledVolume(volume));
      await player.play(AssetSource(asset));
    } catch (_) {}
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
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));          // [V4 ADDED]
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));   // [V4 ADDED]
    unawaited(_startEngineLoop());                                   // [V4 ADDED]
  }

  void _backToMenu() {
    setState(() {
      _view = _GameView.menu;
      _isGameOver = false; _isCrashing = false; _enemies.clear(); _playerX = 0;
    });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));       // [V4 ADDED]
    unawaited(_stopEngineLoop());                                // [V4 ADDED]
    unawaited(_setMusicTrack(_menuMusicAsset, volume: 0.44));   // [V4 ADDED]
  }

  void _resetGame() {
    setState(() => _resetState());
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));          // [V4 ADDED]
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));   // [V4 ADDED]
    unawaited(_startEngineLoop());                                   // [V4 ADDED]
  }

  void _resetState() {
    _enemies.clear(); _playerX = 0; _roadOffset = 0; _baseSpeed = 0.5;
    _difficulty = 0; _spawnTimer = 0.62; _lastPaintMicros = 0;
    _survivalTime = 0;
    _elapsed = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    _smoothedDt = 0.016; _steerSfxCooldown = 0;
    _score = 0; _isGameOver = false; _isCrashing = false; _crashFxTime = 0;
  }

  void _update() {
    final double now = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    if (now == 0) return;
    final double rawDt = ((now - _elapsed) / 1000000).clamp(0.0, 0.04);
    _smoothedDt = _smoothedDt * 0.82 + rawDt * 0.18;
    final double dt = _smoothedDt.clamp(0.0, 0.033);
    _elapsed = now;

    if (!mounted || _view != _GameView.playing || _isGameOver) return;

    if (_isCrashing) {
      _crashFxTime = max(0, _crashFxTime - dt);
      if (_crashFxTime <= 0) _finishGameOver();
      if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
      return;
    }

    _survivalTime += dt;
    // [V4 ADDED] Decrement steer SFX cooldown each frame
    _steerSfxCooldown = max(0, _steerSfxCooldown - dt);
    final double earlyRamp = (_survivalTime / 18).clamp(0.0, 1.0);
    _difficulty += dt * (0.032 + 0.03 * earlyRamp);
    final double speed = _baseSpeed + _pacedDifficulty() * (0.56 + earlyRamp * 0.34);
    _roadOffset += dt * (1.18 + speed * (1.58 + earlyRamp * 0.56));
    for (final _EnemyCar e in _enemies) { e.y += dt * (0.72 + e.speedBoost + speed * 1.7); }
    _enemies.removeWhere((e) => e.y > 1.3);
    _spawnTimer -= dt;
    if (_spawnTimer <= 0) { _spawnEnemyWave(); _spawnTimer = _nextSpawnDelay(); }
    _score += (dt * 90 * (1 + _difficulty)).round();
    if (_findCollidingEnemy() != null) { _triggerCrashEffect(); return; }
    if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
  }

  double _pacedDifficulty() => min(_difficulty, 1.48);

  double _nextSpawnDelay() {
    final double earlyAssist = _survivalTime < 15 ? (15 - _survivalTime) / 15 : 0;
    return (max(0.24, 0.82 - _pacedDifficulty() * 0.28)) *
        (0.9 + _random.nextDouble() * 0.34) + earlyAssist * 0.22;
  }

  void _spawnEnemyWave() {
    final List<int> lanes = List.generate(_laneCount, (i) => i)..shuffle(_random);
    for (final int lane in lanes) {
      if (_canSpawnInLane(lane)) { _spawnEnemyInLane(lane); break; }
    }
  }

  bool _canSpawnInLane(int lane) =>
      !_enemies.any((e) => e.lane == lane && e.y < -0.35 && (e.y - (-1.24)).abs() < 0.64);

  void _spawnEnemyInLane(int lane) {
    final double lw = 2 / _laneCount;
    _enemies.add(_EnemyCar(
      lane: lane, x: -1 + lw * lane + lw / 2, y: -1.24,
      speedBoost: 0.04 + _random.nextDouble() * 0.34,
      assetPath: _enemyCarOptions[_random.nextInt(_enemyCarOptions.length)],
    ));
  }

  Rect _playerHitBox() => Rect.fromCenter(center: Offset(_playerX, 0.79),
      width: _playerWidthFactor * 0.86, height: _playerHeightFactor * 0.9).inflate(0.01);

  Rect _enemyHitBox(_EnemyCar e) => Rect.fromCenter(center: Offset(e.x, e.y),
      width: _enemyWidthFactor * 0.84, height: _enemyHeightFactor * 0.9).inflate(0.008);

  _EnemyCar? _findCollidingEnemy() {
    final Rect p = _playerHitBox();
    for (final _EnemyCar e in _enemies) { if (p.overlaps(_enemyHitBox(e))) return e; }
    return null;
  }

  void _triggerCrashEffect() {
    if (_isCrashing || _isGameOver) return;
    setState(() { _isCrashing = true; _crashFxTime = 0.72; });
    unawaited(_stopEngineLoop());                                        // [V4 ADDED]
    unawaited(_stopMusic());                                             // [V4 ADDED]
    unawaited(_playSfx(_crashSfxAsset, volume: 1, useAlt: true));       // [V4 ADDED]
  }

  void _finishGameOver() {
    setState(() {
      _isGameOver = true; _isCrashing = false; _crashFxTime = 0;
      _bestScore = max(_bestScore, _score);
    });
  }

  void _steer(double delta) {
    if (_isGameOver || _isCrashing || _view != _GameView.playing) return;
    // [V4 ADDED] Play brief steer sound with cooldown to avoid spam
    if (_steerSfxCooldown <= 0) {
      _steerSfxCooldown = 0.08;
      unawaited(_playSfx(_steerSfxAsset, volume: 0.2, useAlt: true));
    }
    setState(() { _playerX = (_playerX + delta).clamp(-0.77, 0.77); });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) return _buildMenu();
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: LayoutBuilder(
        builder: (context, c) => GestureDetector(
          onPanUpdate: (d) => _steer(d.delta.dx / c.maxWidth * 2.2),
          child: Stack(children: <Widget>[
            Positioned.fill(child: _RoadLayer(offset: _roadOffset)),
            ..._enemies.map((e) => _buildEnemy(e, c)),
            _buildPlayerCar(),
            _buildHud(),
            if (_isGameOver) _buildGameOverOverlay(),
            _buildTouchControls(),
          ]),
        ),
      ),
    );
  }

  Widget _buildEnemy(_EnemyCar e, BoxConstraints c) {
    final double carW = c.maxWidth * _enemyWidthFactor;
    final double carH = c.maxHeight * _enemyHeightFactor;
    return Positioned(
      left: c.maxWidth / 2 + e.x * c.maxWidth / 2 - carW / 2,
      top:  c.maxHeight / 2 + e.y * c.maxHeight / 2 - carH / 2,
      width: carW, height: carH,
      child: _CarSprite(assetPath: e.assetPath),
    );
  }

  Widget _buildPlayerCar() {
    return LayoutBuilder(builder: (context, c) {
      final double carW = c.maxWidth * _playerWidthFactor;
      final double carH = c.maxHeight * _playerHeightFactor;
      return Positioned(
        left: c.maxWidth / 2 + _playerX * c.maxWidth / 2 - carW / 2,
        top:  c.maxHeight * 0.79 - carH / 2,
        width: carW, height: carH,
        child: _CarSprite(assetPath: _selectedPlayerCarAsset),
      );
    });
  }

  Widget _buildHud() => Positioned(
    top: 16, left: 16,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text('Score: $_score', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
      Text('Best: $_bestScore', style: const TextStyle(color: Color(0xFFFFBE0B), fontSize: 14)),
    ]),
  );

  Widget _buildGameOverOverlay() => Positioned.fill(
    child: Container(
      color: Colors.black54,
      child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
        const Text('GAME OVER', style: TextStyle(color: Colors.red, fontSize: 36, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Text('Score: $_score', style: const TextStyle(color: Colors.white, fontSize: 24)),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: _resetGame, child: const Text('Play Again')),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _backToMenu,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Main Menu')),
      ])),
    ),
  );

  Widget _buildTouchControls() => Positioned(
    left: 0, right: 0, bottom: 24,
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: <Widget>[
      _ControlButton(icon: Icons.arrow_left_rounded, onPressed: () => _steer(-0.12)),
      _ControlButton(icon: Icons.arrow_right_rounded, onPressed: () => _steer(0.12)),
    ]),
  );

  Widget _buildMenu() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFF151A22), Color(0xFF0E1218), Color(0xFF171D25)],
            stops: <double>[0.0, 0.5, 1.0]),
        ),
        child: SafeArea(child: Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
            const Text('CAR GAME', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900,
                letterSpacing: 2.2, color: Color(0xFFECEFF4))),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Naran Ita-nia', labelStyle: const TextStyle(color: Colors.white60),
                errorText: _nameValidationMessage, filled: true, fillColor: const Color(0xFF1C2330),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),
            // [V4 ADDED] Master volume slider shown in the menu
            Row(children: <Widget>[
              const Icon(Icons.volume_up, color: Colors.white60),
              Expanded(child: Slider(
                value: _masterVolume,
                onChanged: _setMasterVolume,
                activeColor: const Color(0xFFE63946),
              )),
            ]),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _startGame,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE63946),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('HAHU JOGU',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
            )),
          ]),
        ))),
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
      child: Ink(width: 70, height: 70,
        decoration: BoxDecoration(shape: BoxShape.circle,
          gradient: const LinearGradient(colors: <Color>[Color(0xFF2B313B), Color(0xFF191E26)],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
          border: Border.all(color: Colors.white.withOpacity(0.24))),
        child: Icon(icon, size: 40, color: Colors.white)),
    );
  }
}
