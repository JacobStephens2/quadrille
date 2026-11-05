import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/formatting/compact_number.dart';
import '../domain/session_grid.dart';
import '../session_providers.dart';

final setEntryNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Retain one seed per opening. Identity keeps separate openings independent.
@immutable
class SetEntrySeed {
  const SetEntrySeed._(this.row, this.set, this._logging);

  /// Bind synchronously at the opening request, before modal construction.
  factory SetEntrySeed.open(
    ProviderContainer container, {
    required SessionGridRow row,
    required SetEntry set,
  }) => SetEntrySeed._(
    row,
    set,
    container
        .read(sessionSetControllerProvider(row.exercise.sessionId).notifier)
        .bind(exercise: row.exercise, set: set),
  );

  final SessionGridRow row;
  final SetEntry set;
  final SetLoggingHandle _logging;
}

@immutable
class SetEntryDraft {
  const SetEntryDraft({
    this.weight = '',
    this.reps = '',
    this.leftReps = '',
    this.rightReps = '',
    this.notes = '',
    this.rpe,
    this.partials,
  });

  factory SetEntryDraft.fromSeed(SetEntrySeed seed) {
    final weight = seed.row.prefillWeightFor(seed.set);
    return SetEntryDraft(
      weight: weight == null ? '' : compactNumber(weight),
      reps:
          (seed.row.isDurationBased
                  ? seed.row.prefillSecondsFor(seed.set)
                  : seed.set.reps)
              ?.toString() ??
          '',
      leftReps: seed.set.leftReps?.toString() ?? '',
      rightReps: seed.set.rightReps?.toString() ?? '',
      notes: seed.set.notes ?? '',
      rpe: seed.set.rpe,
      partials: seed.set.partials,
    );
  }

  final String weight;

  /// Seconds for duration-based entries, reps otherwise.
  final String reps;
  final String leftReps;
  final String rightReps;
  final String notes;
  final double? rpe;
  final int? partials;

  SetEntryDraft copyWith({
    String? weight,
    String? reps,
    String? leftReps,
    String? rightReps,
    String? notes,
    double? rpe,
    int? partials,
    bool clearRpe = false,
    bool clearPartials = false,
  }) => SetEntryDraft(
    weight: weight ?? this.weight,
    reps: reps ?? this.reps,
    leftReps: leftReps ?? this.leftReps,
    rightReps: rightReps ?? this.rightReps,
    notes: notes ?? this.notes,
    rpe: clearRpe ? null : rpe ?? this.rpe,
    partials: clearPartials ? null : partials ?? this.partials,
  );
}

enum EntrySubmission { idle, pending, success, failure, superseded }

@immutable
class SetEntryState {
  const SetEntryState({
    required this.draft,
    this.remainingSeconds,
    this.isHolding = false,
    this.autoLog = false,
    this.secondsError,
    this.submission = EntrySubmission.idle,
    this.saveError,
  });

  final SetEntryDraft draft;
  final int? remainingSeconds;
  final bool isHolding;
  final bool autoLog;
  final String? secondsError;
  final EntrySubmission submission;
  final String? saveError;

  bool get actionsDisabled =>
      submission == EntrySubmission.pending ||
      submission == EntrySubmission.success ||
      submission == EntrySubmission.superseded;

  SetEntryState copyWith({
    SetEntryDraft? draft,
    int? remainingSeconds,
    bool? isHolding,
    bool? autoLog,
    String? secondsError,
    EntrySubmission? submission,
    String? saveError,
    bool clearHold = false,
    bool clearErrors = false,
  }) => SetEntryState(
    draft: draft ?? this.draft,
    remainingSeconds: clearHold
        ? null
        : remainingSeconds ?? this.remainingSeconds,
    isHolding: clearHold ? false : isHolding ?? this.isHolding,
    autoLog: autoLog ?? this.autoLog,
    secondsError: clearErrors ? null : secondsError ?? this.secondsError,
    submission: submission ?? this.submission,
    saveError: clearErrors ? null : saveError ?? this.saveError,
  );
}

class SetEntryController extends Notifier<SetEntryState> {
  SetEntryController(this.seed);

  final SetEntrySeed seed;
  Timer? _ticker;
  DateTime? _endsAt;

  @override
  SetEntryState build() {
    ref.onDispose(_cancelHold);
    seed._logging.addListener(_ownershipChanged);
    ref.onDispose(() => seed._logging.removeListener(_ownershipChanged));
    return SetEntryState(
      draft: SetEntryDraft.fromSeed(seed),
      submission: seed._logging.isCurrent
          ? EntrySubmission.idle
          : EntrySubmission.superseded,
      saveError: seed._logging.isCurrent ? null : _profileChanged,
    );
  }

  static const _profileChanged =
      'Local profile changed. Close this set and reopen it.';

  void _ownershipChanged() {
    _cancelHold();
    // Invalidation may run inside a provider's disposal lifecycle, where
    // Riverpod forbids mutating another provider. Authority and the hold are
    // retired immediately; publish presentation state after that lifecycle.
    scheduleMicrotask(() {
      if (ref.mounted) _retire();
    });
  }

  void _retire() {
    _cancelHold();
    if (!ref.mounted) return;
    state = state
        .copyWith(
          submission: EntrySubmission.superseded,
          clearHold: true,
          clearErrors: true,
        )
        .copyWith(saveError: _profileChanged);
  }

  bool get _canAct {
    if (!ref.mounted) return false;
    if (!seed._logging.isCurrent) {
      _retire();
      return false;
    }
    return !state.actionsDisabled;
  }

  void updateDraft(SetEntryDraft draft) {
    if (!ref.mounted || state.submission == EntrySubmission.superseded) return;
    final secondsChanged =
        seed.row.isDurationBased && draft.reps != state.draft.reps;
    if (secondsChanged && (state.isHolding || state.actionsDisabled)) {
      draft = draft.copyWith(reps: state.draft.reps);
    }
    final resetHold =
        secondsChanged && !state.isHolding && !state.actionsDisabled;
    if (resetHold) _cancelHold();
    state = state.copyWith(
      draft: draft,
      clearHold: resetHold,
      clearErrors: resetHold,
    );
  }

  void setAutoLog(bool value) {
    if (!_canAct) return;
    state = state.copyWith(autoLog: value);
  }

  void addPartial() {
    if (!ref.mounted) return;
    final current = state.draft.partials;
    updateDraft(
      state.draft.copyWith(partials: current == null ? 3 : current + 1),
    );
  }

  void removePartial() {
    if (!ref.mounted) return;
    final current = state.draft.partials;
    if (current == null) return;
    updateDraft(
      state.draft.copyWith(partials: current - 1, clearPartials: current <= 1),
    );
  }

  void clearPartials() {
    if (!ref.mounted) return;
    updateDraft(state.draft.copyWith(clearPartials: true));
  }

  void startHold() {
    if (!_canAct ||
        !seed.row.isDurationBased ||
        state.isHolding ||
        state.actionsDisabled) {
      return;
    }
    final seconds = int.tryParse(state.draft.reps.trim());
    if (seconds == null || seconds <= 0) {
      state = state.copyWith(
        clearHold: true,
        secondsError: 'Enter seconds greater than zero',
      );
      return;
    }
    final now = ref.read(setEntryNowProvider);
    _endsAt = now().add(Duration(seconds: seconds));
    state = state.copyWith(
      remainingSeconds: seconds,
      isHolding: true,
      clearErrors: true,
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_canAct) return;
      final remaining = (_endsAt!.difference(now()).inMicroseconds / 1000000)
          .ceil()
          .clamp(0, seconds);
      if (remaining == 0) _cancelHold();
      if (remaining != state.remainingSeconds) {
        state = state.copyWith(
          remainingSeconds: remaining,
          isHolding: remaining > 0,
        );
      }
      if (remaining == 0) {
        unawaited(HapticFeedback.heavyImpact());
        if (state.autoLog) unawaited(log());
      }
    });
  }

  void stopHold() {
    if (!ref.mounted || state.actionsDisabled) return;
    _cancelHold();
    state = state.copyWith(clearHold: true, clearErrors: true);
  }

  void _cancelHold() {
    _ticker?.cancel();
    _ticker = null;
    _endsAt = null;
  }

  Future<void> log() => _submit(SetStatus.completed);
  Future<void> skip() => _submit(SetStatus.skipped);

  Future<void> _submit(SetStatus status) async {
    if (!_canAct) return;
    final draft = state.draft;
    _cancelHold();
    state = state.copyWith(
      submission: EntrySubmission.pending,
      clearHold: true,
      clearErrors: true,
    );
    try {
      final result = await seed._logging.save(
        status: status,
        weight: double.tryParse(draft.weight.trim()),
        reps: int.tryParse(draft.reps.trim()),
        leftReps: int.tryParse(draft.leftReps.trim()),
        rightReps: int.tryParse(draft.rightReps.trim()),
        rpe: draft.rpe,
        partials: draft.partials,
        notes: draft.notes.trim().isEmpty ? null : draft.notes.trim(),
      );
      if (!ref.mounted) return;
      if (result == SetLoggingResult.superseded || !seed._logging.isCurrent) {
        _retire();
        return;
      }
      state = state.copyWith(submission: EntrySubmission.success);
    } catch (_) {
      if (!ref.mounted) return;
      if (!seed._logging.isCurrent) {
        _retire();
        return;
      }
      state = state.copyWith(
        submission: EntrySubmission.failure,
        saveError: 'Could not save set. Please try again.',
      );
    }
  }
}

final setEntryProvider = NotifierProvider.autoDispose
    .family<SetEntryController, SetEntryState, SetEntrySeed>(
      SetEntryController.new,
    );
