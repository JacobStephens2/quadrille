import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// One persistence destination captured by a [RetainedOpeningOwner], with the
/// read that proves the provider still returns that exact instance.
final class RetainedDestination {
  const RetainedDestination(this.captured, this._readCurrent);

  final Object? captured;
  final Object? Function() _readCurrent;

  bool get isCurrent => identical(captured, _readCurrent());
}

enum _Phase { idle, pending, completed, failed, superseded }

enum _OutcomeKind { completed, failed, notAdmitted }

final class _SharedOutcome {
  const _SharedOutcome.completed(this.value) : kind = _OutcomeKind.completed;
  const _SharedOutcome.failed() : kind = _OutcomeKind.failed, value = null;
  const _SharedOutcome.notAdmitted()
    : kind = _OutcomeKind.notAdmitted,
      value = null;

  final _OutcomeKind kind;
  final Object? value;
}

final class _SharedSubmission {
  final completion = Completer<_SharedOutcome>();
}

/// Retains the invoking Local profile generation and its exact destinations.
/// Construct from a provider build; provider disposal retires the owner.
/// Retirement is permanent and supersedes every registered opening.
class RetainedOpeningOwner {
  RetainedOpeningOwner(
    this._ref,
    this._generation, {
    required List<RetainedDestination> destinations,
  }) : _destinations = List<RetainedDestination>.unmodifiable(destinations) {
    _generation.addListener(retire);
    _ref.onDispose(retire);
  }

  final Ref _ref;
  final LocalProfileGeneration _generation;
  final List<RetainedDestination> _destinations;
  final _openings = <RetainedOpening<dynamic>>{};
  final _shared = <Object, _SharedSubmission>{};
  bool _active = true;

  /// Current only while not retired, the provider ref is mounted, the
  /// captured generation is current, and every captured destination is
  /// still what its provider returns. Reading this retires the owner when
  /// any check fails, so an A-to-B-to-A profile round trip stays fatal.
  bool get isCurrent {
    if (!_active) return false;
    if (!_ref.mounted ||
        !_generation.isCurrent ||
        _destinations.any((destination) => !destination.isCurrent)) {
      retire();
    }
    return _active;
  }

  void retire() {
    if (!_active) return;
    _active = false;
    _generation.removeListener(retire);
    for (final opening in _openings.toList()) {
      opening._supersede();
    }
  }
}

/// One Retained opening: a fixed target's single-submission authority within
/// its owner's Local profile generation. The feature supplies its own state
/// values ([S]) and maps persistence results to its completed states, so
/// dialogs keep their domain enum. Retirement or release rejects new
/// submission and supersedes feedback; persistence already accepted finishes
/// in its captured destination.
abstract class RetainedOpening<S> extends ChangeNotifier {
  RetainedOpening(
    this._owner, {
    required S idle,
    required S pending,
    required S failed,
    required S superseded,
  }) : _pendingState = pending,
       _failedState = failed,
       _supersededState = superseded,
       _state = idle {
    if (_owner.isCurrent) {
      _owner._openings.add(this);
    } else {
      _phase = _Phase.superseded;
      _state = superseded;
    }
  }

  final RetainedOpeningOwner _owner;
  final S _pendingState;
  final S _failedState;
  final S _supersededState;
  S _state;
  _Phase _phase = _Phase.idle;
  Future<S>? _pending;
  bool _released = false;
  bool _retiredHookFired = false;

  /// Always masked: a non-current opening reports superseded, even when
  /// retirement is discovered by this read rather than the cascade.
  S get state => isCurrent ? _state : _supersededState;

  bool get isCurrent =>
      !_released && _phase != _Phase.superseded && _owner.isCurrent;

  bool get canSubmit =>
      isCurrent && (_phase == _Phase.idle || _phase == _Phase.failed);

  /// Fired exactly once, when this opening first supersedes or is released.
  /// An opening created superseded fires it on release instead of during
  /// construction, so overrides must tolerate never having started.
  @protected
  void onRetired() {}

  void _fireRetired() {
    if (_retiredHookFired) return;
    _retiredHookFired = true;
    onRetired();
  }

  void _supersede() {
    _phase = _Phase.superseded;
    _state = _supersededState;
    _fireRetired();
    _owner._openings.remove(this);
    // Authority retires synchronously; observation waits past provider or
    // widget teardown that may be running when retirement happens.
    scheduleMicrotask(() {
      if (!_released) notifyListeners();
    });
  }

  /// Rejects new submission and late observation without cancelling
  /// persistence already admitted.
  void release() => dispose();

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    _phase = _Phase.superseded;
    _state = _supersededState;
    _fireRetired();
    _owner._openings.remove(this);
    // A listener may release this opening during notifyListeners; defer the
    // underlying disposal past any in-progress notification.
    scheduleMicrotask(super.dispose);
  }

  /// Fails this opening without invoking persistence, leaving it retryable.
  /// Validation runs in the feature's submit method before admission, so
  /// this only transitions from a submittable state.
  S failWithoutPersisting() {
    if (!canSubmit) return state;
    _phase = _Phase.failed;
    _state = _failedState;
    notifyListeners();
    return _state;
  }

  /// The canonical submission: a non-current opening returns superseded
  /// immediately; a pending one returns that same future; a completed one
  /// returns its stored result. Otherwise the completion future is claimed
  /// and listeners notified before [persist] is invoked, with a currency
  /// re-check in between, so a listener retiring this opening during that
  /// notification rejects admission. [persist] then runs exactly once, its
  /// return value maps through [mapCompleted] to this opening's completed
  /// state, and a throw while still current yields the retryable failed
  /// state. With a [sharingKey], concurrent openings of this owner share
  /// one persistence call and each finishes through its own currency.
  Future<S> submit<R>(
    Future<R> Function() persist, {
    required S Function(R result) mapCompleted,
    Object? sharingKey,
  }) {
    if (!isCurrent) return Future<S>.value(_supersededState);
    final pending = _pending;
    if (pending != null) return pending;
    if (_phase == _Phase.completed) return Future<S>.value(_state);
    final completion = Completer<S>();
    _pending = completion.future;
    _phase = _Phase.pending;
    _state = _pendingState;
    var shared = sharingKey == null ? null : _owner._shared[sharingKey];
    final starter = shared == null;
    if (starter) {
      shared = _SharedSubmission();
      if (sharingKey != null) _owner._shared[sharingKey] = shared;
    }
    // Claim the future (and any shared submission) before listeners reenter.
    notifyListeners();
    if (starter) unawaited(_run(persist, shared, sharingKey));
    unawaited(_finish(shared, completion, mapCompleted));
    return completion.future;
  }

  Future<void> _run<R>(
    Future<R> Function() persist,
    _SharedSubmission shared,
    Object? sharingKey,
  ) async {
    var outcome = const _SharedOutcome.notAdmitted();
    try {
      // Invocation accepts persistence in the captured destination. Later
      // retirement or release supersedes feedback, never this write.
      if (isCurrent) {
        outcome = _SharedOutcome.completed(await persist());
      } else {
        outcome = const _SharedOutcome.notAdmitted();
      }
    } catch (_) {
      outcome = const _SharedOutcome.failed();
    }
    if (sharingKey != null && identical(_owner._shared[sharingKey], shared)) {
      _owner._shared.remove(sharingKey);
    }
    shared.completion.complete(outcome);
  }

  Future<void> _finish<R>(
    _SharedSubmission shared,
    Completer<S> completion,
    S Function(R result) mapCompleted,
  ) async {
    final outcome = await shared.completion.future;
    // Each opening completes through its own currency: a joined opening
    // succeeds even when the opening that ran persistence superseded.
    final (S result, _Phase phase) = switch (outcome.kind) {
      _OutcomeKind.completed when isCurrent => (
        mapCompleted(outcome.value as R),
        _Phase.completed,
      ),
      _OutcomeKind.failed when isCurrent => (_failedState, _Phase.failed),
      _ => (_supersededState, _Phase.superseded),
    };
    _pending = null;
    _phase = phase;
    _state = result;
    completion.complete(result);
    if (!_released) notifyListeners();
  }
}
