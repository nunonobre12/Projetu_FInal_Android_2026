import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const RacingGameApp());

class RacingGameApp extends StatelessWidget {
  const RacingGameApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'CAR GAME',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE63946)), useMaterial3: true),
        home: const RacingGamePage(),
      );
}

enum _GameView { menu, playing }

class _LeaderboardEntry {
  const _LeaderboardEntry({required this.playerName, required this.bestScore});
  final String playerName;
  final int bestScore;
  factory _LeaderboardEntry.fromMap(Map<String, dynamic> map) =>
      _LeaderboardEntry(playerName: (map['playerName'] ?? '').toString(), bestScore: (map['bestScore'] as num?)?.toInt() ?? 0);
  Map<String, dynamic> toMap() => <String, dynamic>{'playerName': playerName, 'bestScore': bestScore};
}

class _EnemyCar {
  _EnemyCar({required this.lane, required this.x, required this.y, required this.speedBoost, required this.assetPath});
  int lane; double x; double y; double speedBoost; String assetPath;
}

class RacingGamePage extends StatefulWidget {
  const RacingGamePage({super.key});
  @override
  State<RacingGamePage> createState() => _RacingGamePageState();
}

class _RacingGamePageState extends State<RacingGamePage> with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

  static const int _laneCount = 4;
  static const double _playerWidthFactor  = 0.16;
  static const double _playerHeightFactor = 0.13;
  static const double _enemyWidthFactor   = 0.155;
  static const double _enemyHeightFactor  = 0.125;
  static const List<String> _playerCarOptions = <String>[
    'assets/images/car_1.png', 'assets/images/car_2.png',
    'assets/images/car_3.png', 'assets/images/car_4.png',
  ];
  static const List<String> _enemyCarOptions = <String>[
    'assets/images/car_5.png', 'assets/images/car_6.png', 'assets/images/car_7.png',
    'assets/images/car_8.png', 'assets/images/car_9.png', 'assets/images/car_10.png',
  ];
  static const String _menuMusicAsset     = 'audio/menu_music.wav';
  static const String _gameplayMusicAsset = 'audio/gameplay_music.wav';
  static const String _engineLoopAsset    = 'audio/engine_loop.wav';
  static const String _crashSfxAsset      = 'audio/crash.wav';
  static const String _buttonTapSfxAsset  = 'audio/button_tap.wav';
  static const String _steerSfxAsset      = 'audio/steer.wav';
  static const String _pauseSfxAsset      = 'audio/pause.wav';
  static const String _resumeBeepSfxAsset = 'audio/resume_beep.wav';
  static const String _resumeGoSfxAsset   = 'audio/resume_go.wav';
  static const String _leaderboardPrefsKey = 'leaderboard_v1';

  final Random _random = Random();
  final List<_EnemyCar> _enemies = <_EnemyCar>[];
  final TextEditingController _nameController = TextEditingController();
  final AudioPlayer _musicPlayer  = AudioPlayer();
  final AudioPlayer _enginePlayer = AudioPlayer();
  final AudioPlayer _sfxPlayer    = AudioPlayer();
  final AudioPlayer _sfxAltPlayer = AudioPlayer();
  SharedPreferences? _prefs;

  _GameView _view = _GameView.menu;
  double _playerX = 0;
  double _roadOffset = 0;
  double _baseSpeed = 0.44;
  double _difficulty = 0;
  double _spawnTimer = 0;
  double _laneSpacingSolveTimer = 0;
  double _lastPaintMicros = 0;
  double _survivalTime = 0;
  double _elapsed = 0;
  double _smoothedDt = 0.016;
  double _masterVolume = 0.82;
  double _musicMixVolume = 0.44;
  final double _engineMixVolume = 0.3;
  double _steerSfxCooldown = 0;
  double _laneHoldTime = 0;
  double _lanePressureCooldown = 0;
  int _lastPlayerLane = 0;
  // [. Guard so precacheImage runs only once
  bool _assetsWarmedUp = false;
  String? _currentMusicAsset;
  bool _isEngineLooping = false;
  String? _nameValidationMessage;
  String _activePlayerName = '';
  int _score = 0;
  int _bestScore = 0;
  List<_LeaderboardEntry> _leaderboard = <_LeaderboardEntry>[];
  bool _leaderboardDirty = false;
  bool _isGameOver = false;
  bool _isCrashing = false;
  double _crashFxTime = 0;
  // [. X position at the moment of crash — used to position the crash flash
  double _crashAtX = 0;
  bool _isPaused = false;
  double _resumeCountdown = 0;
  String _selectedPlayerCarAsset = _playerCarOptions.first;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_update)..forward();
    unawaited(_initAudio());
    unawaited(_loadLeaderboard());
  }

  @override
  void dispose() {
    if (_leaderboardDirty) unawaited(_saveLeaderboard());
    _nameController.dispose();
    _musicPlayer.dispose(); _enginePlayer.dispose();
    _sfxPlayer.dispose(); _sfxAltPlayer.dispose();
    _ticker.dispose();
    super.dispose();
  }

  // [. Precache all image assets when the widget tree is ready
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assetsWarmedUp) return;
    _assetsWarmedUp = true;
    final List<String> assets = <String>[
      'assets/images/road_tile.png', // [. road tile now in assets
      ..._playerCarOptions,
      ..._enemyCarOptions,
    ];
    for (final String asset in assets) precacheImage(AssetImage(asset), context);
  }

  Future<void> _loadLeaderboard() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final String? raw = _prefs!.getString(_leaderboardPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return;
      final List<_LeaderboardEntry> entries = <_LeaderboardEntry>[];
      for (final dynamic item in decoded) {
        if (item is Map<String, dynamic>) entries.add(_LeaderboardEntry.fromMap(item));
        else if (item is Map) entries.add(_LeaderboardEntry.fromMap(item.cast<String, dynamic>()));
      }
      entries.sort((a, b) => b.bestScore.compareTo(a.bestScore));
      if (!mounted) return;
      setState(() => _leaderboard = entries);
    } catch (_) {}
  }

  Future<void> _saveLeaderboard() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(_leaderboardPrefsKey, jsonEncode(_leaderboard.map((e) => e.toMap()).toList()));
      _leaderboardDirty = false;
    } catch (_) {}
  }

  void _recordScoreForActivePlayer() {
    if (_activePlayerName.trim().isEmpty) return;
    final String player = _activePlayerName.trim();
    final int idx = _leaderboard.indexWhere((e) => e.playerName.toLowerCase() == player.toLowerCase());
    bool changed = false;
    if (idx >= 0) {
      if (_score > _leaderboard[idx].bestScore) { _leaderboard[idx] = _LeaderboardEntry(playerName: player, bestScore: _score); changed = true; }
    } else {
      _leaderboard.add(_LeaderboardEntry(playerName: player, bestScore: _score)); changed = true;
    }
    if (changed) {
      _leaderboard.sort((a, b) => b.bestScore.compareTo(a.bestScore));
      if (_leaderboard.length > 30) _leaderboard = _leaderboard.take(30).toList();
      _leaderboardDirty = true;
      unawaited(_saveLeaderboard());
    }
  }

  Future<void> _clearLeaderboard() async {
    setState(() { _leaderboard = <_LeaderboardEntry>[]; _leaderboardDirty = true; });
    await _saveLeaderboard();
  }

  Future<void> _initAudio() async {
    await _musicPlayer.setReleaseMode(ReleaseMode.loop);
    await _enginePlayer.setReleaseMode(ReleaseMode.loop);
    await _sfxPlayer.setReleaseMode(ReleaseMode.stop);
    await _sfxAltPlayer.setReleaseMode(ReleaseMode.stop);
    await _setMusicTrack(_menuMusicAsset, volume: 0.44);
  }

  double _scaledVolume(double v) => (v * _masterVolume).clamp(0.0, 1.0);
  Future<void> _applyMasterVolume() async {
    try { await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume)); await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume)); } catch (_) {}
  }
  void _setMasterVolume(double v) { setState(() => _masterVolume = v.clamp(0.0, 1.0)); unawaited(_applyMasterVolume()); }
  Future<void> _setMusicTrack(String asset, {required double volume}) async {
    _musicMixVolume = volume;
    if (_currentMusicAsset == asset) { await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume)); return; }
    _currentMusicAsset = asset;
    try { await _musicPlayer.stop(); await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume)); await _musicPlayer.play(AssetSource(asset)); } catch (_) {}
  }
  Future<void> _stopMusic() async { _currentMusicAsset = null; try { await _musicPlayer.stop(); } catch (_) {} }
  Future<void> _startEngineLoop() async {
    if (_isEngineLooping) return; _isEngineLooping = true;
    try { await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume)); await _enginePlayer.play(AssetSource(_engineLoopAsset)); } catch (_) {}
  }
  Future<void> _stopEngineLoop() async { _isEngineLooping = false; try { await _enginePlayer.stop(); } catch (_) {} }
  Future<void> _playSfx(String asset, {double volume = 1, bool useAlt = false}) async {
    final AudioPlayer p = useAlt ? _sfxAltPlayer : _sfxPlayer;
    try { await p.stop(); await p.setVolume(_scaledVolume(volume)); await p.play(AssetSource(asset)); } catch (_) {}
  }

  void _startGame() {
    final String username = _nameController.text.trim();
    if (username.isEmpty) { setState(() => _nameValidationMessage = 'Favor Insere Naran Antes Halimar'); return; }
    setState(() { _activePlayerName = username; _nameValidationMessage = null; _view = _GameView.playing; _resetState(); });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
    unawaited(_startEngineLoop());
  }

  void _backToMenu() {
    setState(() { _view = _GameView.menu; _isGameOver = false; _isCrashing = false; _crashFxTime = 0; _isPaused = false; _resumeCountdown = 0; _enemies.clear(); _playerX = 0; });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_stopEngineLoop());
    unawaited(_setMusicTrack(_menuMusicAsset, volume: 0.44));
  }

  void _resetGame() {
    setState(() => _resetState());
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
    unawaited(_startEngineLoop());
  }

  void _resetState() {
    _enemies.clear(); _playerX = 0; _roadOffset = 0; _baseSpeed = 0.5;
    _difficulty = 0; _spawnTimer = 0.62; _laneSpacingSolveTimer = 0;
    _lastPaintMicros = 0; _survivalTime = 0;
    _elapsed = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    _smoothedDt = 0.016; _steerSfxCooldown = 0;
    _laneHoldTime = 0; _lanePressureCooldown = 0;
    _lastPlayerLane = _playerLaneIndex();
    _score = 0; _isGameOver = false; _isCrashing = false; _crashFxTime = 0;
    _crashAtX = _playerX; // [.
    _isPaused = false; _resumeCountdown = 0;
  }

  void _pauseGame() {
    if (_isGameOver || _isCrashing || _view != _GameView.playing || _resumeCountdown > 0) return;
    setState(() => _isPaused = true);
    unawaited(_playSfx(_pauseSfxAsset, volume: 0.8));
    unawaited(_stopMusic()); unawaited(_stopEngineLoop());
  }

  void _resumeWithCountdown() {
    if (_view != _GameView.playing || !_isPaused || _isGameOver) return;
    setState(() { _isPaused = false; _resumeCountdown = 3; });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_playSfx(_resumeBeepSfxAsset, volume: 0.8, useAlt: true));
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
    if (_resumeCountdown > 0) {
      final int prev = _resumeCountdown.ceil();
      _resumeCountdown = max(0, _resumeCountdown - dt);
      final int next = _resumeCountdown.ceil();
      if (next < prev && next > 0) unawaited(_playSfx(_resumeBeepSfxAsset, volume: 0.78, useAlt: true));
      if (next == 0 && prev > 0) {
        unawaited(_playSfx(_resumeGoSfxAsset, volume: 0.86, useAlt: true));
        unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
        unawaited(_startEngineLoop());
      }
      if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
      return;
    }
    if (_isPaused) return;

    _survivalTime += dt;
    _steerSfxCooldown = max(0, _steerSfxCooldown - dt);
    _lanePressureCooldown = max(0, _lanePressureCooldown - dt);
    final int curLane = _playerLaneIndex();
    if (curLane == _lastPlayerLane) { _laneHoldTime += dt; } else { _lastPlayerLane = curLane; _laneHoldTime = 0; }
    final double earlyRamp = (_survivalTime / 18).clamp(0.0, 1.0);
    _difficulty += dt * (0.032 + 0.03 * earlyRamp);
    final double speed = _baseSpeed + _pacedDifficulty() * (0.56 + earlyRamp * 0.34 + _pacedDifficulty() * 0.4);
    _roadOffset += dt * (1.18 + speed * (1.58 + earlyRamp * 0.56));
    for (final _EnemyCar e in _enemies) { e.y += dt * (0.72 + e.speedBoost + speed * (1.7 + earlyRamp * 0.48)); }
    _laneSpacingSolveTimer -= dt;
    if (_laneSpacingSolveTimer <= 0) { _enforceEnemyLaneSpacing(); _laneSpacingSolveTimer = 0.05; }
    _enemies.removeWhere((e) => e.y > 1.3);
    if (_enemies.length > 20) _enemies.removeRange(0, _enemies.length - 20);
    _spawnTimer -= dt;
    if (_spawnTimer <= 0) { _spawnEnemyWave(); _spawnTimer = _nextSpawnDelay(); }
    _score += (dt * 90 * (1 + _difficulty)).round();
    if (_findCollidingEnemy() != null) { _triggerCrashEffect(); return; }
    if (now - _lastPaintMicros >= 16000) { _lastPaintMicros = now; setState(() {}); }
  }

  double _pacedDifficulty() => min(_difficulty, 1.48);

  double _nextSpawnDelay() {
    final double ea = _survivalTime < 15 ? (15 - _survivalTime) / 15 : 0;
    return (max(0.24, 0.82 - _pacedDifficulty() * 0.28)) * (0.9 + _random.nextDouble() * 0.34) + ea * 0.22;
  }

  void _spawnEnemyWave() {
    int waveCount = 1;
    if (_survivalTime > 16 && _pacedDifficulty() > 0.98 && _random.nextDouble() < 0.2) waveCount = 2;
    final int playerLane = _playerLaneIndex();
    int spawned = 0;
    if (_canSpawnInLane(playerLane)) { _spawnEnemyOnPlayerPath(); spawned++; }
    final double pressure = ((_laneHoldTime - 4.2) / 3.8).clamp(0.0, 1.0);
    if (pressure > 0 && _lanePressureCooldown <= 0 && spawned < waveCount &&
        _canSpawnInLane(playerLane) && _random.nextDouble() < (0.58 + pressure * 0.26)) {
      _spawnEnemyOnPlayerPath(); _lanePressureCooldown = 1.3; spawned++;
    }
    final List<int> lanes = List.generate(_laneCount, (i) => i)..shuffle(_random);
    for (final int lane in lanes) {
      if (spawned >= waveCount) break;
      if (_canSpawnInLane(lane)) { _spawnEnemyInLane(lane); spawned++; }
    }
    if (spawned == 0) { for (final int lane in lanes) { if (_canSpawnInLane(lane)) { _spawnEnemyInLane(lane); break; } } }
  }

  bool _canSpawnInLane(int lane) {
    const double spawnY = -1.24;
    final double minGap = max(0.3, 0.64 - _pacedDifficulty() * 0.16);
    return !_enemies.any((e) => e.lane == lane && e.y < -0.35 && (e.y - spawnY).abs() < minGap);
  }
  double _laneTrafficSpacing() => max(0.22, 0.34 - _pacedDifficulty() * 0.06);
  void _enforceEnemyLaneSpacing() {
    final double ms = _laneTrafficSpacing();
    for (int lane = 0; lane < _laneCount; lane++) {
      final List<_EnemyCar> lc = _enemies.where((e) => e.lane == lane).toList()..sort((a, b) => b.y.compareTo(a.y));
      for (int i = 1; i < lc.length; i++) {
        final double maxY = lc[i - 1].y - ms;
        if (lc[i].y > maxY) lc[i].y = maxY;
      }
    }
  }
  int _playerLaneIndex() => (((_playerX + 1) / (2 / _laneCount)).floor()).clamp(0, _laneCount - 1);
  void _spawnEnemyOnPlayerPath() { _spawnEnemyInLane(_playerLaneIndex(), xOverride: _playerX.clamp(-0.84, 0.84)); }
  double _spawnYForLane(int lane) {
    final List<_EnemyCar> lc = _enemies.where((e) => e.lane == lane).toList();
    if (lc.isEmpty) return -1.24;
    return min(-1.24, lc.map((e) => e.y).reduce((a, b) => a < b ? a : b) - _laneTrafficSpacing());
  }
  void _spawnEnemyInLane(int lane, {double? xOverride}) {
    final double lw = 2 / _laneCount;
    _enemies.add(_EnemyCar(lane: lane, x: xOverride ?? (-1 + lw * lane + lw / 2), y: _spawnYForLane(lane),
        speedBoost: 0.04 + _random.nextDouble() * (0.34 + min(_pacedDifficulty() * 0.24, 0.3)),
        assetPath: _enemyCarOptions[_random.nextInt(_enemyCarOptions.length)]));
  }
  Rect _playerHitBox() => Rect.fromCenter(center: Offset(_playerX, 0.79), width: _playerWidthFactor * 0.86, height: _playerHeightFactor * 0.9).inflate(0.01);
  Rect _enemyHitBox(_EnemyCar e) => Rect.fromCenter(center: Offset(e.x, e.y), width: _enemyWidthFactor * 0.84, height: _enemyHeightFactor * 0.9).inflate(0.008);
  _EnemyCar? _findCollidingEnemy() {
    final Rect p = _playerHitBox();
    for (final _EnemyCar e in _enemies) { if (p.overlaps(_enemyHitBox(e))) return e; }
    return null;
  }
  void _triggerCrashEffect() {
    if (_isCrashing || _isGameOver) return;
    setState(() {
      _isCrashing = true; _crashFxTime = 0.72;
      _crashAtX = _playerX; // [. Remember crash position for the flash overlay
      _isPaused = false; _resumeCountdown = 0;
    });
    unawaited(_stopEngineLoop()); unawaited(_stopMusic());
    unawaited(_playSfx(_crashSfxAsset, volume: 1, useAlt: true));
  }
  void _finishGameOver() {
    setState(() { _isGameOver = true; _isCrashing = false; _crashFxTime = 0; _isPaused = false; _resumeCountdown = 0; _bestScore = max(_bestScore, _score); _recordScoreForActivePlayer(); });
  }
  void _steer(double delta) {
    if (_isGameOver || _isCrashing || _view != _GameView.playing || _isPaused || _resumeCountdown > 0) return;
    if (_steerSfxCooldown <= 0) { _steerSfxCooldown = 0.08; unawaited(_playSfx(_steerSfxAsset, volume: 0.2, useAlt: true)); }
    setState(() { _playerX = (_playerX + delta).clamp(-0.77, 0.77); });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) return _buildMenu();
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: LayoutBuilder(builder: (context, c) => GestureDetector(
        onPanUpdate: (d) => _steer(d.delta.dx / c.maxWidth * 2.2),
        child: Stack(children: <Widget>[
          Positioned.fill(child: _RoadLayer(offset: _roadOffset)),
          // [. Speed lines layer rendered above the road, ignoring pointer events
          Positioned.fill(child: IgnorePointer(child: _SpeedLinesLayer(
            progress: _roadOffset,
            intensity: (_pacedDifficulty() / 1.5).clamp(0.2, 1.0),
          ))),
          ..._enemies.map((e) => _buildEnemy(e)),
          _buildPlayerCar(),
          _buildHud(),
          // .[ Crash flash overlay centred on the crash position
          if (_isCrashing) _buildCrashEffectOverlay(),
          if (_isGameOver) _buildGameOverOverlay(),
          if (_isPaused) _buildPauseOverlay(),
          if (_resumeCountdown > 0) _buildResumeCountdownOverlay(),
          _buildTouchControls(),
        ]),
      )),
    );
  }

  Widget _buildEnemy(_EnemyCar e) => Align(
    alignment: Alignment(e.x, e.y),
    child: FractionallySizedBox(widthFactor: _enemyWidthFactor, heightFactor: _enemyHeightFactor,
        child: _CarSprite(assetPath: e.assetPath)),
  );

  // [. Player car rendered with a green glow
  Widget _buildPlayerCar() => Align(
    alignment: Alignment(_playerX, 0.79),
    child: FractionallySizedBox(widthFactor: _playerWidthFactor, heightFactor: _playerHeightFactor,
        child: _CarSprite(assetPath: _selectedPlayerCarAsset, hasGlow: true)),
  );

  // [. HUD now uses styled _HudChip widgets instead of plain Text
  Widget _buildHud() => Positioned(
    top: 10, left: 12, right: 12,
    child: Row(children: <Widget>[
      _HudChip(label: 'PONTUS', value: '$_score'),
      const SizedBox(width: 8),
      _HudChip(label: 'PONTUS AAS', value: '$_bestScore'),
      const Spacer(),
      _HudChip(label: 'VELOSIDADE', value: '${(1 + _difficulty).toStringAsFixed(2)}x'),
      const SizedBox(width: 8),
      IconButton(onPressed: _pauseGame, icon: const Icon(Icons.pause_rounded, color: Colors.white, size: 26)),
    ]),
  );

  // [. Crash effect — red vignette flash that fades with _crashFxTime
  Widget _buildCrashEffectOverlay() {
    final double intensity = (_crashFxTime / 0.72).clamp(0.0, 1.0);
    return Positioned.fill(
      child: IgnorePointer(child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(_crashAtX, 0.6),
            radius: 1.4,
            colors: <Color>[
              Colors.transparent,
              Colors.redAccent.withOpacity(0.55 * intensity),
            ],
          ),
        ),
      )),
    );
  }

  Widget _buildGameOverOverlay() => Positioned.fill(
    child: Container(color: Colors.black54, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      const Text('SOKE!', style: TextStyle(color: Color(0xFFFFBE0B), fontSize: 34, fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      Text('Score: $_score', style: const TextStyle(color: Colors.white, fontSize: 20)),
      const SizedBox(height: 20),
      ElevatedButton.icon(onPressed: _resetGame, icon: const Icon(Icons.replay_rounded), label: const Text('Play Again')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _backToMenu, style: OutlinedButton.styleFrom(foregroundColor: Colors.white), child: const Text('Main Menu')),
    ]))),
  );
  Widget _buildPauseOverlay() => Positioned.fill(
    child: Container(color: Colors.black.withOpacity(0.7), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      const Text('PAUSED', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900)),
      const SizedBox(height: 24),
      FilledButton.icon(onPressed: _resumeWithCountdown, icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('RESUME'), style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2ECC71))),
      const SizedBox(height: 12),
      OutlinedButton(onPressed: _backToMenu, style: OutlinedButton.styleFrom(foregroundColor: Colors.white), child: const Text('Main Menu')),
    ]))),
  );
  Widget _buildResumeCountdownOverlay() => Positioned.fill(
    child: Container(color: Colors.black.withOpacity(0.55), child: Center(child: Text(
      _resumeCountdown.ceil() > 0 ? '${_resumeCountdown.ceil()}' : 'GO!',
      style: const TextStyle(color: Colors.white, fontSize: 72, fontWeight: FontWeight.w900),
    ))),
  );
  Widget _buildTouchControls() {
    if (_isGameOver || _isCrashing || _isPaused || _resumeCountdown > 0) return const SizedBox.shrink();
    return Positioned(left: 0, right: 0, bottom: 24, child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: <Widget>[
      _ControlButton(icon: Icons.chevron_left_rounded, onPressed: () => _steer(-0.14)),
      _ControlButton(icon: Icons.chevron_right_rounded, onPressed: () => _steer(0.14)),
    ]));
  }

  Widget _buildMenu() => Scaffold(
    body: Container(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFF151A22), Color(0xFF0E1218), Color(0xFF171D25)], stops: <double>[0.0, 0.5, 1.0])),
      child: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(children: <Widget>[
        const Text('CAR GAME', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 2.2, color: Color(0xFFECEFF4))),
        const SizedBox(height: 8),
        const Text('HALAI HASORU OBSTAKULU SIRA', style: TextStyle(color: Color(0xFF9AA5B1), fontSize: 11, letterSpacing: 1.0, fontWeight: FontWeight.w700)),
        const SizedBox(height: 24),
        TextField(controller: _nameController, style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(labelText: 'Naran', labelStyle: const TextStyle(color: Colors.white70),
            errorText: _nameValidationMessage, filled: true, fillColor: const Color(0xFF0D1118),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))),
        const SizedBox(height: 16),
        Row(children: <Widget>[
          const Icon(Icons.volume_up, color: Colors.white60),
          Expanded(child: Slider(value: _masterVolume, onChanged: _setMasterVolume, activeColor: const Color(0xFFE63946))),
        ]),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _startGame, icon: const Icon(Icons.play_arrow_rounded), label: const Text('KOMESA'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2ECC71), minimumSize: const Size(220, 54),
            textStyle: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8))),
      ])))),
    ),
  );
}

// =============================================================================
// Widget classes
// =============================================================================

// [. _CarSprite now accepts hasGlow to draw a coloured box shadow
class _CarSprite extends StatelessWidget {
  const _CarSprite({required this.assetPath, this.hasGlow = false});
  final String assetPath;
  final bool hasGlow;

  @override
  Widget build(BuildContext context) {
    final Widget img = Image.asset(assetPath, fit: BoxFit.contain);
    if (!hasGlow) return img;
    return Container(
      decoration: BoxDecoration(
        boxShadow: <BoxShadow>[
          BoxShadow(color: const Color(0xFF2ECC71).withOpacity(0.45), blurRadius: 18, spreadRadius: 2),
        ],
      ),
      child: img,
    );
  }
}

// [. _HudChip — small pill-shaped label+value widget for the HUD
class _HudChip extends StatelessWidget {
  const _HudChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        Text(value,  style: const TextStyle(color: Colors.white,   fontSize: 13, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

// [. _SpeedLinesLayer — renders _SpeedLinesPainter as a widget
class _SpeedLinesLayer extends StatelessWidget {
  const _SpeedLinesLayer({required this.progress, required this.intensity});
  final double progress;
  final double intensity;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SpeedLinesPainter(progress: progress, intensity: intensity));
}

// [. _SpeedLinesPainter — draws fast-moving vertical light streaks
// whose opacity, count, and length scale with the intensity parameter
class _SpeedLinesPainter extends CustomPainter {
  const _SpeedLinesPainter({required this.progress, required this.intensity});
  final double progress;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..strokeWidth = 1.2;
    final int count = (18 + (intensity * 24).toInt());
    final Random rng = Random(42); // fixed seed = stable line positions

    for (int i = 0; i < count; i++) {
      final double x = rng.nextDouble() * size.width;
      final double speed = 0.6 + rng.nextDouble() * 0.8;
      final double y = (progress * speed * 0.18 + rng.nextDouble() * size.height) % size.height;
      final double centerBias = 1.0 - ((x / size.width - 0.5).abs() * 1.8).clamp(0.0, 1.0);
      final double alpha = (0.045 + 0.11 * intensity) * (0.55 + centerBias * 0.45);
      paint.color = const Color(0xFFBBD6FF).withOpacity(alpha);
      canvas.drawLine(Offset(x, y), Offset(x, y + 16 + 16 * intensity), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedLinesPainter old) =>
      old.progress != progress || old.intensity != intensity;
}

// [. _RoadLayer now tiles the road_tile.png image instead of a solid colour
class _RoadLayer extends StatelessWidget {
  const _RoadLayer({required this.offset});
  final double offset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final double tileH = c.maxWidth * 0.55;
      final double scrolledY = -(offset % tileH);
      return ClipRect(child: Stack(children: <Widget>[
        // base dark road colour
        Container(color: const Color(0xFF1A1F28)),
        // tiled image scrolled downward
        Positioned(left: 0, right: 0, top: scrolledY, child: Column(children: <Widget>[
          for (int i = 0; i < (c.maxHeight / tileH).ceil() + 2; i++)
            SizedBox(width: c.maxWidth, height: tileH,
              child: Image.asset('assets/images/road_tile.png', fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1A1F28)))),
        ])),
      ]));
    });
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed, borderRadius: BorderRadius.circular(26),
    child: Ink(width: 70, height: 70,
      decoration: BoxDecoration(shape: BoxShape.circle,
        gradient: const LinearGradient(colors: <Color>[Color(0xFF2B313B), Color(0xFF191E26)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        border: Border.all(color: Colors.white.withOpacity(0.24))),
      child: Icon(icon, size: 40, color: Colors.white)),
  );
}
