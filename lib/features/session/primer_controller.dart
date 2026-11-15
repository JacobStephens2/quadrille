import 'dart:async';

import 'package:flutter/foundation.dart';

class PrimerStep {
  const PrimerStep(this.name, this.cue);

  final String name;
  final String cue;
}

/// Ephemeral movement guidance. It never touches session or rest-timer storage.
class PrimerController extends ChangeNotifier {
  PrimerController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const stepDuration = Duration(seconds: 60);
  static const steps = [
    PrimerStep(
      'Thoracic Windmills / Open-Books',
      '5 slow breaths per side: half-kneeling or side-lying against a wall, '
          'rotate the ribcage 180° open, hips and knees locked forward.',
    ),
    PrimerStep(
      'Supinated Band Pull-Aparts + Scapular Wall Slides',
      '15 reps, palms up; pull the band across the collarbones while dropping '
          'shoulders down away from the ears.',
    ),
    PrimerStep(
      'Standing Ribcage Circles / Thoracic Circumduction',
      '8 circles each way, hands on hips, pelvis completely still.',
    ),
    PrimerStep(
      'Deep Squat Pry + Ankle Rocks',
      '60 seconds: sink into a deep bodyweight squat holding an upright post, '
          'driving knees forward over the toes.',
    ),
  ];

  final DateTime Function() _now;
  Timer? _ticker;
  DateTime? _endsAt;
  Duration? _pausedRemaining;
  int _stepIndex = 0;
  bool _isComplete = false;

  bool get hasStarted => _endsAt != null;
  bool get isComplete => _isComplete;
  bool get isPaused => _pausedRemaining != null;
  int get stepNumber => _stepIndex + 1;
  PrimerStep get step => steps[_stepIndex];
  Duration get remaining {
    if (_isComplete) return Duration.zero;
    if (_pausedRemaining case final paused?) return paused;
    final deadline = _endsAt;
    if (deadline == null) return stepDuration;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  void start() {
    if (hasStarted || isComplete) return;
    _endsAt = _now().add(stepDuration);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => refresh(),
    );
    notifyListeners();
  }

  /// A late foreground tick catches up using deadlines, including step changes.
  void refresh() {
    if (!hasStarted || isComplete || isPaused) return;
    final now = _now();
    while (!now.isBefore(_endsAt!)) {
      if (_stepIndex == steps.length - 1) {
        _isComplete = true;
        _ticker?.cancel();
        break;
      }
      _stepIndex++;
      _endsAt = _endsAt!.add(stepDuration);
    }
    notifyListeners();
  }

  void pause() {
    if (!hasStarted || isComplete || isPaused) return;
    refresh();
    if (isComplete) return;
    _pausedRemaining = remaining;
    notifyListeners();
  }

  void resume() {
    if (!isPaused || isComplete) return;
    _endsAt = _now().add(_pausedRemaining!);
    _pausedRemaining = null;
    notifyListeners();
  }

  void skipStep() {
    if (!hasStarted || isComplete) return;
    if (_stepIndex == steps.length - 1) {
      _isComplete = true;
      _ticker?.cancel();
    } else {
      _stepIndex++;
      _endsAt = _now().add(stepDuration);
      if (isPaused) _pausedRemaining = stepDuration;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
