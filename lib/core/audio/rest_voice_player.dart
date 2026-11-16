import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum RestVoiceCue {
  start('audio/rest_start.wav'),
  complete('audio/rest_complete.wav');

  const RestVoiceCue(this.assetPath);
  final String assetPath;
}

/// Bundled speech with lazy audio initialization and ordered cancellation.
/// Audio failures must never prevent logging a set or scheduling a rest alert.
class RestVoicePlayer {
  RestVoicePlayer({FutureOr<AudioPlayer> Function()? createPlayer})
    : _createPlayer = createPlayer ?? _initializePlayer;

  static Future<AudioPlayer> _initializePlayer() async {
    // Await platform setup before constructing a player, whose constructor
    // otherwise launches initialization on a detached future.
    await AudioPlayer.global.ensureInitialized();
    return AudioPlayer();
  }

  final FutureOr<AudioPlayer> Function() _createPlayer;
  AudioPlayer? _player;
  Future<void> _pending = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;

  Future<void> _enqueue(Future<void> Function() action) {
    return _pending = _pending.then((_) => _attempt(action));
  }

  Future<void> _attempt(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      debugPrint('Rest voice cue unavailable: $error');
    }
  }

  Future<void> play(RestVoiceCue cue) {
    final generation = ++_generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation) return;
      final player = _player ??= await _createPlayer();
      if (_disposed) {
        await player.dispose();
        return;
      }
      if (generation != _generation) return;
      // Setting volume initializes the plugin before asset preparation, so an
      // unavailable platform is caught here rather than on a detached future.
      await player.play(AssetSource(cue.assetPath), volume: 1);
    });
  }

  Future<void> stop() {
    _generation++;
    // AudioPlayer.stop cancels a pending preparation too. Do not wait behind
    // play: an asset that is still loading must not hold the timer queue.
    return _attempt(() async => _player?.stop());
  }

  Future<void> dispose() {
    _disposed = true;
    _generation++;
    return _attempt(() async => _player?.dispose());
  }
}
