import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const RacingGameApp());
}

class RacingGameApp extends StatelessWidget {
  const RacingGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Arcade Car Racing',
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

class _RacingGamePageState extends State<RacingGamePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

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
  static const List<String> _enemyCarOptions = <String>[
    'assets/images/car_5.png',
    'assets/images/car_6.png',
    'assets/images/car_7.png',
    'assets/images/car_8.png',
    'assets/images/car_9.png',
    'assets/images/car_10.png',
  ];
  static const String _menuMusicAsset = 'audio/menu_music.wav';
  static const String _gameplayMusicAsset = 'audio/gameplay_music.wav';
  static const String _engineLoopAsset = 'audio/engine_loop.wav';
  static const String _crashSfxAsset = 'audio/crash.wav';
  static const String _buttonTapSfxAsset = 'audio/button_tap.wav';
  static const String _pauseSfxAsset = 'audio/pause.wav';
  static const String _resumeBeepSfxAsset = 'audio/resume_beep.wav';
  static const String _resumeGoSfxAsset = 'audio/resume_go.wav';
  static const String _steerSfxAsset = 'audio/steer.wav';
  static const String _leaderboardPrefsKey = 'leaderboard_v1';

  final Random _random = Random();
  final List<_EnemyCar> _enemies = <_EnemyCar>[];
  final TextEditingController _nameController = TextEditingController();
  final AudioPlayer _musicPlayer = AudioPlayer();
  final AudioPlayer _enginePlayer = AudioPlayer();
  final AudioPlayer _sfxPlayer = AudioPlayer();
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
  bool _assetsWarmedUp = false;
  String? _currentMusicAsset;
  bool _isEngineLooping = false;

  int _score = 0;
  int _bestScore = 0;
  String _activePlayerName = '';
  String? _nameValidationMessage;
  List<_LeaderboardEntry> _leaderboard = <_LeaderboardEntry>[];
  bool _leaderboardDirty = false;
  bool _isGameOver = false;
  bool _isCrashing = false;
  double _crashFxTime = 0;
  double _crashAtX = 0;
  bool _isPaused = false;
  double _resumeCountdown = 0;
  String _selectedPlayerCarAsset = _playerCarOptions.first;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(days: 1),
    )
      ..addListener(_update)
      ..forward();

    unawaited(_initAudio());
    unawaited(_loadLeaderboard());
  }

  @override
  void dispose() {
    if (_leaderboardDirty) {
      unawaited(_saveLeaderboard());
    }
    _nameController.dispose();
    _musicPlayer.dispose();
    _enginePlayer.dispose();
    _sfxPlayer.dispose();
    _sfxAltPlayer.dispose();
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _loadLeaderboard() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final SharedPreferences prefs = _prefs!;
      final String? raw = prefs.getString(_leaderboardPrefsKey);
      if (raw == null || raw.isEmpty) {
        return;
      }

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return;
      }

      final List<_LeaderboardEntry> entries = <_LeaderboardEntry>[];
      for (final dynamic item in decoded) {
        if (item is Map<String, dynamic>) {
          entries.add(_LeaderboardEntry.fromMap(item));
        } else if (item is Map) {
          entries.add(_LeaderboardEntry.fromMap(item.cast<String, dynamic>()));
        }
      }

      entries.sort((a, b) => b.bestScore.compareTo(a.bestScore));
      if (!mounted) {
        return;
      }
      setState(() {
        _leaderboard = entries;
      });
    } catch (_) {}
  }

  Future<void> _saveLeaderboard() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final SharedPreferences prefs = _prefs!;
      final String raw = jsonEncode(
        _leaderboard.map((entry) => entry.toMap()).toList(),
      );
      await prefs.setString(_leaderboardPrefsKey, raw);
      _leaderboardDirty = false;
    } catch (_) {}
  }

  void _recordScoreForActivePlayer() {
    if (_activePlayerName.trim().isEmpty) {
      return;
    }

    final String player = _activePlayerName.trim();
    final int existingIndex = _leaderboard.indexWhere(
      (entry) => entry.playerName.toLowerCase() == player.toLowerCase(),
    );

    bool changed = false;
    if (existingIndex >= 0) {
      if (_score > _leaderboard[existingIndex].bestScore) {
        _leaderboard[existingIndex] = _LeaderboardEntry(
          playerName: player,
          bestScore: _score,
        );
        changed = true;
      }
    } else {
      _leaderboard
          .add(_LeaderboardEntry(playerName: player, bestScore: _score));
      changed = true;
    }

    if (changed) {
      _leaderboard.sort((a, b) => b.bestScore.compareTo(a.bestScore));
      if (_leaderboard.length > 30) {
        _leaderboard = _leaderboard.take(30).toList();
      }
      _leaderboardDirty = true;
      unawaited(_saveLeaderboard());
    }
  }

  Future<void> _clearLeaderboard() async {
    setState(() {
      _leaderboard = <_LeaderboardEntry>[];
      _leaderboardDirty = true;
    });
    await _saveLeaderboard();
  }

  Future<void> _initAudio() async {
    await _musicPlayer.setReleaseMode(ReleaseMode.loop);
    await _enginePlayer.setReleaseMode(ReleaseMode.loop);
    await _sfxPlayer.setReleaseMode(ReleaseMode.stop);
    await _sfxAltPlayer.setReleaseMode(ReleaseMode.stop);
    await _setMusicTrack(_menuMusicAsset, volume: 0.44);
  }

  double _scaledVolume(double baseVolume) {
    return (baseVolume * _masterVolume).clamp(0.0, 1.0);
  }

  Future<void> _applyMasterVolume() async {
    try {
      await _musicPlayer.setVolume(_scaledVolume(_musicMixVolume));
      await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume));
    } catch (_) {}
  }

  void _setMasterVolume(double value) {
    setState(() {
      _masterVolume = value.clamp(0.0, 1.0);
    });
    unawaited(_applyMasterVolume());
  }

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
    try {
      await _musicPlayer.stop();
    } catch (_) {}
  }

  Future<void> _startEngineLoop() async {
    if (_isEngineLooping) {
      return;
    }
    _isEngineLooping = true;
    try {
      await _enginePlayer.setVolume(_scaledVolume(_engineMixVolume));
      await _enginePlayer.play(AssetSource(_engineLoopAsset));
    } catch (_) {}
  }

  Future<void> _stopEngineLoop() async {
    _isEngineLooping = false;
    try {
      await _enginePlayer.stop();
    } catch (_) {}
  }

  Future<void> _playSfx(
    String asset, {
    double volume = 1,
    bool useAlt = false,
  }) async {
    final AudioPlayer player = useAlt ? _sfxAltPlayer : _sfxPlayer;
    try {
      await player.stop();
      await player.setVolume(_scaledVolume(volume));
      await player.play(AssetSource(asset));
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assetsWarmedUp) {
      return;
    }
    _assetsWarmedUp = true;

    final List<String> assetsToWarm = <String>[
      'assets/images/road_tile.png',
      ..._playerCarOptions,
      ..._enemyCarOptions,
    ];

    for (final String asset in assetsToWarm) {
      precacheImage(AssetImage(asset), context);
    }
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
      _resetState(fullReset: true);
    });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
    unawaited(_startEngineLoop());
  }

  void _backToMenu() {
    setState(() {
      _view = _GameView.menu;
      _isGameOver = false;
      _isCrashing = false;
      _crashFxTime = 0;
      _isPaused = false;
      _resumeCountdown = 0;
      _enemies.clear();
      _playerX = 0;
    });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_stopEngineLoop());
    unawaited(_setMusicTrack(_menuMusicAsset, volume: 0.44));
  }

  void _resetGame() {
    setState(() {
      _resetState(fullReset: true);
    });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
    unawaited(_startEngineLoop());
  }

  void _resetState({required bool fullReset}) {
    _enemies.clear();
    _playerX = 0;
    _roadOffset = 0;
    _baseSpeed = 0.5;
    _difficulty = 0;
    _spawnTimer = 0.62;
    _laneSpacingSolveTimer = 0;
    _lastPaintMicros = 0;
    _survivalTime = 0;
    _elapsed = _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    _smoothedDt = 0.016;
    _steerSfxCooldown = 0;
    _laneHoldTime = 0;
    _lanePressureCooldown = 0;
    _lastPlayerLane = _playerLaneIndex();
    _score = 0;
    _isGameOver = false;
    _isCrashing = false;
    _crashFxTime = 0;
    _crashAtX = _playerX;
    _isPaused = false;
    _resumeCountdown = 0;

    if (!fullReset) {
      _bestScore = _bestScore;
    }
  }

  void _update() {
    final double now =
        _ticker.lastElapsedDuration?.inMicroseconds.toDouble() ?? 0;
    if (now == 0) {
      return;
    }

    final double rawDt = ((now - _elapsed) / 1000000).clamp(0.0, 0.04);
    _smoothedDt = _smoothedDt * 0.82 + rawDt * 0.18;
    final double dt = _smoothedDt.clamp(0.0, 0.033);
    _elapsed = now;

    if (!mounted || _view != _GameView.playing || _isGameOver) {
      return;
    }

    if (_isCrashing) {
      _crashFxTime = max(0, _crashFxTime - dt);
      if (_crashFxTime <= 0) {
        _finishGameOver();
      }
      _paintIfDue(now);
      return;
    }

    if (_resumeCountdown > 0) {
      final int previousTick = _resumeCountdown.ceil();
      _resumeCountdown = max(0, _resumeCountdown - dt);
      final int newTick = _resumeCountdown.ceil();
      if (newTick < previousTick && newTick > 0) {
        unawaited(_playSfx(_resumeBeepSfxAsset, volume: 0.78, useAlt: true));
      }
      if (newTick == 0 && previousTick > 0) {
        unawaited(_playSfx(_resumeGoSfxAsset, volume: 0.86, useAlt: true));
        unawaited(_setMusicTrack(_gameplayMusicAsset, volume: 0.42));
        unawaited(_startEngineLoop());
      }
      _paintIfDue(now);
      return;
    }

    if (_isPaused) {
      return;
    }

    _survivalTime += dt;
    _steerSfxCooldown = max(0, _steerSfxCooldown - dt);
    _lanePressureCooldown = max(0, _lanePressureCooldown - dt);
    final int currentLane = _playerLaneIndex();
    if (currentLane == _lastPlayerLane) {
      _laneHoldTime += dt;
    } else {
      _lastPlayerLane = currentLane;
      _laneHoldTime = 0;
    }

    final double gameplayDifficulty = _pacedDifficulty();
    final double earlyRamp = (_survivalTime / 18).clamp(0.0, 1.0);
    _difficulty += dt * (0.032 + 0.03 * earlyRamp);
    final double speed = _baseSpeed +
        gameplayDifficulty *
            (0.56 + earlyRamp * 0.34 + gameplayDifficulty * 0.4);
    _roadOffset += dt * (1.18 + speed * (1.58 + earlyRamp * 0.56));

    for (final _EnemyCar enemy in _enemies) {
      enemy.y +=
          dt * (0.72 + enemy.speedBoost + speed * (1.7 + earlyRamp * 0.48));
    }

    _laneSpacingSolveTimer -= dt;
    if (_laneSpacingSolveTimer <= 0) {
      _enforceEnemyLaneSpacing();
      _laneSpacingSolveTimer = 0.05;
    }

    _enemies.removeWhere((enemy) => enemy.y > 1.3);
    if (_enemies.length > 20) {
      _enemies.removeRange(0, _enemies.length - 20);
    }

    _spawnTimer -= dt;
    if (_spawnTimer <= 0) {
      _spawnEnemyWave();
      _spawnTimer = _nextSpawnDelay();
    }

    _score += (dt * 90 * (1 + _difficulty)).round();

    final _EnemyCar? collidingEnemy = _findCollidingEnemy();
    if (collidingEnemy != null) {
      _triggerCrashEffect();
      return;
    }

    _paintIfDue(now);
  }

  void _paintIfDue(double now, {bool force = false}) {
    if (!mounted) {
      return;
    }

    if (force || now - _lastPaintMicros >= 16000) {
      _lastPaintMicros = now;
      setState(() {});
    }
  }

  double _nextSpawnDelay() {
    final double earlyAssist =
        _survivalTime < 15 ? (15 - _survivalTime) / 15 : 0;
    final double baseDelay = max(0.24, 0.82 - _pacedDifficulty() * 0.28);
    final double jitter = 0.9 + _random.nextDouble() * 0.34;
    return baseDelay * jitter + earlyAssist * 0.22;
  }

  void _spawnEnemyWave() {
    final double gameplayDifficulty = _pacedDifficulty();
    int waveCount = 1;
    if (_survivalTime > 16 &&
        gameplayDifficulty > 0.98 &&
        _random.nextDouble() < 0.2) {
      waveCount = 2;
    }

    final int playerLane = _playerLaneIndex();
    int spawned = 0;

    if (_canSpawnInLane(playerLane)) {
      _spawnEnemyOnPlayerPath();
      spawned += 1;
    }

    final double laneCampPressure =
        ((_laneHoldTime - 4.2) / 3.8).clamp(0.0, 1.0);
    if (laneCampPressure > 0 &&
        _lanePressureCooldown <= 0 &&
        spawned < waveCount &&
        _canSpawnInLane(playerLane) &&
        _random.nextDouble() < (0.58 + laneCampPressure * 0.26)) {
      _spawnEnemyOnPlayerPath();
      _lanePressureCooldown = 1.3;
      spawned += 1;
    }

    final List<int> lanes = List<int>.generate(_laneCount, (int i) => i)
      ..shuffle(_random);

    for (final int lane in lanes) {
      if (spawned >= waveCount) {
        break;
      }
      if (_canSpawnInLane(lane)) {
        _spawnEnemyInLane(lane);
        spawned += 1;
      }
    }

    if (spawned == 0 && waveCount > 0) {
      for (final int lane in lanes) {
        if (_canSpawnInLane(lane)) {
          _spawnEnemyInLane(lane);
          break;
        }
      }
    }
  }

  bool _canSpawnInLane(int lane) {
    const double spawnY = -1.24;
    final double minGap = max(0.3, 0.64 - _pacedDifficulty() * 0.16);
    return !_enemies.any(
      (enemy) =>
          enemy.lane == lane &&
          enemy.y < -0.35 &&
          (enemy.y - spawnY).abs() < minGap,
    );
  }

  double _laneTrafficSpacing() {
    return max(0.22, 0.34 - _pacedDifficulty() * 0.06);
  }

  void _enforceEnemyLaneSpacing() {
    final double minSpacing = _laneTrafficSpacing();

    for (int lane = 0; lane < _laneCount; lane++) {
      final List<_EnemyCar> laneCars = _enemies
          .where((enemy) => enemy.lane == lane)
          .toList()
        ..sort((a, b) => b.y.compareTo(a.y));

      for (int i = 1; i < laneCars.length; i++) {
        final _EnemyCar front = laneCars[i - 1];
        final _EnemyCar back = laneCars[i];
        final double maxBackY = front.y - minSpacing;
        if (back.y > maxBackY) {
          back.y = maxBackY;
        }
      }
    }
  }

  int _playerLaneIndex() {
    final double laneWidth = 2 / _laneCount;
    return (((_playerX + 1) / laneWidth).floor()).clamp(0, _laneCount - 1);
  }

  double _pacedDifficulty() {
    return min(_difficulty, 1.48);
  }

  void _spawnEnemyOnPlayerPath() {
    final int lane = _playerLaneIndex();
    final double x = _playerX.clamp(-0.84, 0.84);
    _spawnEnemyInLane(lane, xOverride: x);
  }

  void _spawnEnemyInLane(int lane, {double? xOverride}) {
    final double laneWidth = 2 / _laneCount;
    final double x = xOverride ?? (-1 + laneWidth * lane + laneWidth / 2);
    final double spawnY = _spawnYForLane(lane);

    _enemies.add(
      _EnemyCar(
        lane: lane,
        x: x,
        y: spawnY,
        speedBoost: 0.04 +
            _random.nextDouble() * (0.34 + min(_pacedDifficulty() * 0.24, 0.3)),
        assetPath: _enemyCarOptions[_random.nextInt(_enemyCarOptions.length)],
      ),
    );
  }

  double _spawnYForLane(int lane) {
    const double baseSpawnY = -1.24;
    final List<_EnemyCar> laneCars =
        _enemies.where((enemy) => enemy.lane == lane).toList();

    if (laneCars.isEmpty) {
      return baseSpawnY;
    }

    final double topMostY =
        laneCars.map((enemy) => enemy.y).reduce((a, b) => a < b ? a : b);
    return min(baseSpawnY, topMostY - _laneTrafficSpacing());
  }

  Rect _playerHitBox() {
    return Rect.fromCenter(
      center: Offset(_playerX, 0.79),
      width: _playerWidthFactor * 0.86,
      height: _playerHeightFactor * 0.9,
    ).inflate(0.01);
  }

  Rect _enemyHitBox(_EnemyCar enemy) {
    return Rect.fromCenter(
      center: Offset(enemy.x, enemy.y),
      width: _enemyWidthFactor * 0.84,
      height: _enemyHeightFactor * 0.9,
    ).inflate(0.008);
  }

  _EnemyCar? _findCollidingEnemy() {
    final Rect playerRect = _playerHitBox();

    for (final _EnemyCar enemy in _enemies) {
      if (playerRect.overlaps(_enemyHitBox(enemy))) {
        return enemy;
      }
    }

    return null;
  }

  void _finishGameOver() {
    setState(() {
      _isGameOver = true;
      _isCrashing = false;
      _crashFxTime = 0;
      _isPaused = false;
      _resumeCountdown = 0;
      _bestScore = max(_bestScore, _score);
      _recordScoreForActivePlayer();
    });
  }

  Future<void> _openLeaderboardDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF151920),
              title: const Text(
                'Leaderboard',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
              ),
              content: SizedBox(
                width: 360,
                child: _leaderboard.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'Seidauk iha pontus. Hahu lai jogu hodi hetan pontus.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _leaderboard.length,
                          separatorBuilder: (_, __) => Divider(
                            color: Colors.white.withOpacity(0.12),
                            height: 12,
                          ),
                          itemBuilder: (BuildContext context, int index) {
                            final _LeaderboardEntry entry = _leaderboard[index];
                            return Row(
                              children: <Widget>[
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    entry.playerName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${entry.bestScore}',
                                  style: const TextStyle(
                                    color: Color(0xFFFFBE0B),
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
              ),
              actions: <Widget>[
                TextButton.icon(
                  onPressed: _leaderboard.isEmpty
                      ? null
                      : () async {
                          await _clearLeaderboard();
                          if (!context.mounted) {
                            return;
                          }
                          setDialogState(() {});
                        },
                  icon: const Icon(Icons.delete_forever_rounded),
                  label: const Text('Hamoos'),
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFE63946)),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Taka'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _openHowToPlayDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF151920),
          title: const Text(
            'Oinsa Atu Halimar',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 520),
              child: SingleChildScrollView(child: _buildHowToPlayCard()),
            ),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Taka'),
            ),
          ],
        );
      },
    );
  }

  void _triggerCrashEffect() {
    if (_isCrashing || _isGameOver) {
      return;
    }

    setState(() {
      _isCrashing = true;
      _crashFxTime = 0.72;
      _crashAtX = _playerX;
      _isPaused = false;
      _resumeCountdown = 0;
    });

    unawaited(_stopEngineLoop());
    unawaited(_stopMusic());
    unawaited(_playSfx(_crashSfxAsset, volume: 1, useAlt: true));
  }

  void _pauseGame() {
    if (_isGameOver ||
        _isCrashing ||
        _view != _GameView.playing ||
        _resumeCountdown > 0) {
      return;
    }
    setState(() {
      _isPaused = true;
    });
    unawaited(_playSfx(_pauseSfxAsset, volume: 0.8));
    unawaited(_stopMusic());
    unawaited(_stopEngineLoop());
  }

  void _resumeWithCountdown() {
    if (_view != _GameView.playing || !_isPaused || _isGameOver) {
      return;
    }
    setState(() {
      _isPaused = false;
      _resumeCountdown = 3;
    });
    unawaited(_playSfx(_buttonTapSfxAsset, volume: 0.8));
    unawaited(_playSfx(_resumeBeepSfxAsset, volume: 0.8, useAlt: true));
  }

  void _steer(double delta) {
    if (_isGameOver ||
        _isCrashing ||
        _view != _GameView.playing ||
        _isPaused ||
        _resumeCountdown > 0) {
      return;
    }
    if (_steerSfxCooldown <= 0) {
      _steerSfxCooldown = 0.08;
      unawaited(_playSfx(_steerSfxAsset, volume: 0.2, useAlt: true));
    }
    setState(() {
      _playerX = (_playerX + delta).clamp(-0.77, 0.77);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_view == _GameView.menu) {
      return _buildMenu();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return GestureDetector(
            onPanUpdate: (details) =>
                _steer(details.delta.dx / constraints.maxWidth * 2.2),
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _RoadLayer(offset: _roadOffset)),
                Positioned.fill(
                  child: IgnorePointer(
                    child: _SpeedLinesLayer(
                      progress: _roadOffset,
                      intensity: (_pacedDifficulty() / 1.5).clamp(0.2, 1.0),
                    ),
                  ),
                ),
                ..._enemies.map((enemy) => _buildEnemy(enemy)),
                _buildPlayerCar(),
                _buildHud(),
                if (_isCrashing) _buildCrashEffectOverlay(),
                if (_isGameOver) _buildGameOverOverlay(),
                if (_isPaused) _buildPauseOverlay(),
                if (_resumeCountdown > 0) _buildResumeCountdownOverlay(),
                _buildTouchControls(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMenu() {
    return Scaffold(
      body: Container(
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
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: const Color(0xFF11161D).withOpacity(0.92),
                        border:
                            Border.all(color: Colors.white.withOpacity(0.1)),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 30,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Text(
                            'CAR GAME',
                            textAlign: TextAlign.center,
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
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF9AA5B1),
                              letterSpacing: 1.0,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 22),
                          Container(
                            height: 130,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              color: const Color(0xFF24292F),
                            ),
                            child: Stack(
                              children: <Widget>[
                                const Positioned.fill(
                                    child: _RoadLayer(offset: 0.34)),
                                Align(
                                  alignment: Alignment(0, 0.45),
                                  child: FractionallySizedBox(
                                    widthFactor: 0.22,
                                    heightFactor: 0.65,
                                    child: _CarSprite(
                                      assetPath: _selectedPlayerCarAsset,
                                      hasGlow: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Hili Kareta',
                            style: TextStyle(
                              color: Color(0xFFB9C2CC),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            alignment: WrapAlignment.center,
                            children: List<Widget>.generate(
                              _playerCarOptions.length,
                              (int index) {
                                final String assetPath =
                                    _playerCarOptions[index];
                                return _CarChoiceChip(
                                  assetPath: assetPath,
                                  indexLabel: '${index + 1}',
                                  isSelected:
                                      _selectedPlayerCarAsset == assetPath,
                                  onTap: () {
                                    setState(() {
                                      _selectedPlayerCarAsset = assetPath;
                                    });
                                    unawaited(_playSfx(_buttonTapSfxAsset,
                                        volume: 0.7));
                                  },
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildMasterVolumeCard(),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameController,
                            maxLength: 16,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              counterText: '',
                              labelText: 'Naran ',
                              labelStyle:
                                  const TextStyle(color: Colors.white70),
                              hintText: 'Insere Naran',
                              hintStyle: const TextStyle(color: Colors.white38),
                              errorText: _nameValidationMessage,
                              filled: true,
                              fillColor: const Color(0xFF0D1118),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                    color: Colors.white.withOpacity(0.14)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                    color: Colors.white.withOpacity(0.14)),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.all(Radius.circular(12)),
                                borderSide: BorderSide(
                                    color: Color(0xFF2ECC71), width: 1.4),
                              ),
                            ),
                            onChanged: (_) {
                              if (_nameValidationMessage != null) {
                                setState(() {
                                  _nameValidationMessage = null;
                                });
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () {
                              unawaited(
                                  _playSfx(_buttonTapSfxAsset, volume: 0.7));
                              unawaited(_openHowToPlayDialog());
                            },
                            icon: const Icon(Icons.help_outline_rounded),
                            label: const Text('OINSA ATU HALIMAR'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                  color: Colors.white.withOpacity(0.35)),
                              minimumSize: const Size(220, 46),
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () {
                              unawaited(
                                  _playSfx(_buttonTapSfxAsset, volume: 0.7));
                              unawaited(_openLeaderboardDialog());
                            },
                            icon: const Icon(Icons.leaderboard_rounded),
                            label: const Text('HARE LEADERBOARD'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                  color: Colors.white.withOpacity(0.35)),
                              minimumSize: const Size(220, 46),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _startGame,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('KOMESA'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF2ECC71),
                              elevation: 0,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(220, 54),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          if (_bestScore > 0) ...<Widget>[
                            const SizedBox(height: 14),
                            Text(
                              'Pontus Aas: $_bestScore',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEnemy(_EnemyCar enemy) {
    return Align(
      alignment: Alignment(enemy.x, enemy.y),
      child: FractionallySizedBox(
        widthFactor: _enemyWidthFactor,
        heightFactor: _enemyHeightFactor,
        child: _CarSprite(assetPath: enemy.assetPath),
      ),
    );
  }

  Widget _buildPlayerCar() {
    return Align(
      alignment: Alignment(_playerX, 0.79),
      child: FractionallySizedBox(
        widthFactor: _playerWidthFactor,
        heightFactor: _playerHeightFactor,
        child: _CarSprite(
          assetPath: _selectedPlayerCarAsset,
          hasGlow: true,
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _HudChip(label: 'PONTUS', value: '$_score'),
            const SizedBox(width: 8),
            _HudChip(label: 'PONTUS AAS', value: '$_bestScore'),
            const Spacer(),
            _HudChip(
                label: 'VELOSIDADE',
                value: '${(1 + _difficulty).toStringAsFixed(2)}x'),
            const SizedBox(width: 8),
            _PauseButton(onPressed: _pauseGame),
          ],
        ),
      ),
    );
  }

  Widget _buildTouchControls() {
    if (_isGameOver || _isCrashing || _isPaused || _resumeCountdown > 0) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _ControlButton(
              icon: Icons.chevron_left_rounded,
              onPressed: () => _steer(-0.14),
            ),
            const SizedBox(width: 22),
            _ControlButton(
              icon: Icons.chevron_right_rounded,
              onPressed: () => _steer(0.14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameOverOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.62),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        margin: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: const Color(0xFF151920),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFFFBE0B), width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'SOKE!',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: Color(0xFFFFBE0B),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'PONTUS FINAL: $_score',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pontus Aas: $_bestScore',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _resetGame,
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('HAHU FILA-FALI'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE63946),
                    foregroundColor: Colors.white,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _backToMenu,
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('MENU'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.4)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCrashEffectOverlay() {
    final double progress = (1 - (_crashFxTime / 0.72)).clamp(0.0, 1.0);
    final double blastSize =
        lerpDouble(58, 190, Curves.easeOutExpo.transform(progress))!;
    final double flashOpacity = (0.5 - progress).clamp(0.0, 0.5);
    final double sparkOpacity = (1 - progress).clamp(0.0, 1.0);

    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ColoredBox(
                color: Colors.white.withOpacity(flashOpacity * 0.45)),
          ),
          Align(
            alignment: Alignment(_crashAtX, 0.79),
            child: SizedBox(
              width: blastSize,
              height: blastSize,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Container(
                    width: blastSize,
                    height: blastSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          const Color(0xFFFFF2B2)
                              .withOpacity(0.95 * sparkOpacity),
                          const Color(0xFFFF8A00)
                              .withOpacity(0.72 * sparkOpacity),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: blastSize * 0.58,
                    height: blastSize * 0.58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFFFE066)
                            .withOpacity(0.7 * sparkOpacity),
                        width: 3,
                      ),
                    ),
                  ),
                  ...List<Widget>.generate(8, (int i) {
                    final double angle = i * pi / 4;
                    final double dist =
                        lerpDouble(12, blastSize * 0.62, progress)!;
                    return Transform.translate(
                      offset: Offset(cos(angle) * dist, sin(angle) * dist),
                      child: Transform.rotate(
                        angle: angle,
                        child: Container(
                          width: 18,
                          height: 4,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: const Color(0xFFFFD166)
                                .withOpacity(0.85 * sparkOpacity),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHowToPlayCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF151A22).withOpacity(0.86),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.sports_esports_rounded,
                  color: Color(0xFFB9F2CB), size: 18),
              SizedBox(width: 8),
              Text(
                'OINSA ATU HALIMAR',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF0E131B),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: const Row(
              children: <Widget>[
                Icon(Icons.swipe_rounded, color: Color(0xFF2ECC71), size: 20),
                SizedBox(width: 8),
                Icon(Icons.arrow_back_rounded, color: Colors.white60, size: 20),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Muda ba loos no karuk atu kontrola kareta',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward_rounded,
                    color: Colors.white60, size: 20),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            children: <Widget>[
              Expanded(
                child: _HowToStep(
                  icon: Icons.warning_amber_rounded,
                  title: 'Evita Soke ',
                  caption: 'Jogu sei para',
                  tint: Color(0xFFFFBE0B),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _HowToStep(
                  icon: Icons.speed_rounded,
                  title: 'Fokus',
                  caption: 'Velosidade aumenta',
                  tint: Color(0xFF4FC3F7),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _HowToStep(
                  icon: Icons.emoji_events_rounded,
                  title: 'Pontus Aas',
                  caption: 'iha leaderoard',
                  tint: Color(0xFFB9F2CB),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0x33FFFFFF), height: 8),
          const SizedBox(height: 10),
          const _HowToInfoRow(
            icon: Icons.pause_circle_filled_rounded,
            title: 'Pauza',
            detail:
                'Atu pauza jogu. bainhira kontinua jogu sei hahu depois 3 segundu.',
            accent: Color(0xFFB9F2CB),
          ),
          const SizedBox(height: 8),
          const _HowToInfoRow(
            icon: Icons.leaderboard_rounded,
            title: 'Leaderboard',
            detail:
                'Insere naran antes halimar. Pontus ass sei rai no hatudu iha leaderboard.',
            accent: Color(0xFFFFE08A),
          ),
        ],
      ),
    );
  }

  Widget _buildMasterVolumeCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF151A22).withOpacity(0.82),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.volume_up_rounded,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text(
                'VOLUME',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  letterSpacing: 0.9,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '${(_masterVolume * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF2ECC71),
              inactiveTrackColor: const Color(0xFF2B313B),
              thumbColor: const Color(0xFFB9F2CB),
              overlayColor: const Color(0x442ECC71),
              trackHeight: 4,
            ),
            child: Slider(
              value: _masterVolume,
              min: 0,
              max: 1,
              onChanged: _setMasterVolume,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPauseOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.58),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        margin: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: const Color(0xFF151920),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF2ECC71), width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'PAUZA',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: Color(0xFF2ECC71),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pontus: $_score',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _buildMasterVolumeCard(),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _resumeWithCountdown,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('KONTINUA'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2ECC71),
                    foregroundColor: Colors.white,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _resetGame,
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('HAHU FILA FALI'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE63946),
                    foregroundColor: Colors.white,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _backToMenu,
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('MENU'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.4)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumeCountdownOverlay() {
    final int count = _resumeCountdown.ceil().clamp(1, 3);
    return IgnorePointer(
      child: Container(
        color: Colors.black.withOpacity(0.32),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            '$count',
            key: ValueKey<int>(count),
            style: const TextStyle(
              fontSize: 90,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 2,
              shadows: <Shadow>[
                Shadow(color: Colors.black54, blurRadius: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoadLayer extends StatelessWidget {
  const _RoadLayer({required this.offset});

  final double offset;
  static const String _asset = 'assets/images/road_tile.png';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = constraints.maxHeight;
        final double scrollPx = (-offset * 420) % height;

        return Stack(
          children: <Widget>[
            Positioned(
              top: -scrollPx,
              left: 0,
              right: 0,
              height: height,
              child: Image.asset(
                _asset,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
              ),
            ),
            Positioned(
              top: height - scrollPx,
              left: 0,
              right: 0,
              height: height,
              child: Image.asset(
                _asset,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CarSprite extends StatelessWidget {
  const _CarSprite({
    required this.assetPath,
    this.hasGlow = false,
  });

  final String assetPath;
  final bool hasGlow;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.low,
    );
  }
}

class _HudChip extends StatelessWidget {
  const _HudChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: const Color(0xFF151A22).withOpacity(0.9),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white70,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            style: const TextStyle(
              fontSize: 17,
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        width: 48,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: const Color(0xFF151A22).withOpacity(0.9),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: const Icon(Icons.pause_rounded, color: Colors.white, size: 28),
      ),
    );
  }
}

class _SpeedLinesLayer extends StatelessWidget {
  const _SpeedLinesLayer({required this.progress, required this.intensity});

  final double progress;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpeedLinesPainter(progress: progress, intensity: intensity),
    );
  }
}

class _SpeedLinesPainter extends CustomPainter {
  _SpeedLinesPainter({required this.progress, required this.intensity});

  final double progress;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3;

    const int lines = 14;
    final double offset = (progress * 280) % (size.height + 40);

    for (int i = 0; i < lines; i++) {
      final double norm = i / lines;
      final double x = size.width * (0.08 + 0.84 * norm);
      final double y =
          (i * (size.height / lines) + offset) % (size.height + 30) - 15;
      final double centerBias = 1 - ((norm - 0.5).abs() * 1.8).clamp(0.0, 0.85);
      final double alpha =
          (0.045 + 0.11 * intensity) * (0.55 + centerBias * 0.45);
      paint.color = Color(0xFFBBD6FF).withOpacity(alpha);
      canvas.drawLine(Offset(x, y), Offset(x, y + 16 + 16 * intensity), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedLinesPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.intensity != intensity;
  }
}

class _HowToStep extends StatelessWidget {
  const _HowToStep({
    required this.icon,
    required this.title,
    required this.caption,
    required this.tint,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: const Color(0xFF0E131B),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: tint, size: 18),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 10,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _HowToInfoRow extends StatelessWidget {
  const _HowToInfoRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFF0E131B),
        border: Border.all(color: Colors.white.withOpacity(0.09)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withOpacity(0.18),
            ),
            child: Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    height: 1.28,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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

class _MenuTag extends StatelessWidget {
  const _MenuTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF0D1118),
        border: Border.all(color: Colors.white.withOpacity(0.13)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CarChoiceChip extends StatelessWidget {
  const _CarChoiceChip({
    required this.assetPath,
    required this.indexLabel,
    required this.isSelected,
    required this.onTap,
  });

  final String assetPath;
  final String indexLabel;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 76,
        height: 92,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: isSelected ? const Color(0xFF1E2E27) : const Color(0xFF0E131B),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF2ECC71)
                : Colors.white.withOpacity(0.16),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: _CarSprite(assetPath: assetPath),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'HILI $indexLabel',
              style: TextStyle(
                color: isSelected
                    ? const Color(0xFFB9F2CB)
                    : const Color(0xFFAAB3BE),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

class _LeaderboardEntry {
  const _LeaderboardEntry({required this.playerName, required this.bestScore});

  final String playerName;
  final int bestScore;

  factory _LeaderboardEntry.fromMap(Map<String, dynamic> map) {
    return _LeaderboardEntry(
      playerName: (map['Naran'] ?? '').toString(),
      bestScore: (map['Pontus Aas'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'playerName': playerName,
      'bestScore': bestScore,
    };
  }
}
