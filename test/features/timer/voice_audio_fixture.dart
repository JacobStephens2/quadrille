import 'package:audioplayers/audioplayers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:quadrille/core/audio/rest_voice_player.dart';
import 'package:quadrille/features/timer/timer_providers.dart';

/// Silence the platform audio boundary in tests about other workout behavior.
final silentVoiceAudio = restVoicePlayerProvider.overrideWith(
  (_) => RestVoicePlayer(createPlayer: _SilentAudioPlayer.new),
);

class _SilentAudioPlayer extends Fake implements AudioPlayer {
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
