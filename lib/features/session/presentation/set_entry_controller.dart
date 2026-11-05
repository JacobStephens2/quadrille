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
  const SetEntrySeed({required this.row, required this.set});

  final SessionGridRow row;
  final SetEntry set;
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

enum EntrySubmission { idle, pending, success, failure }

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
      submission == EntrySubmission.success;

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
    return SetEntryState(draft: SetEntryDraft.fromSeed(seed));
  }

  void updateDraft(SetEntryDraft draft) {
    if (!ref.mounted) return;
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
    if (!ref.mounted || state.actionsDisabled) return;
    state = state.copyWith(autoLog: value);
  }

  void startHold() {
    if (!ref.mounted ||
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
    if (!ref.mounted || state.actionsDisabled) return;
    final draft = state.draft;
    _cancelHold();
    state = state.copyWith(
      submission: EntrySubmission.pending,
      clearHold: true,
      clearErrors: true,
    );
    try {
      final logging = ref.read(
        sessionSetControllerProvider(seed.row.exercise.sessionId).notifier,
      );
      await logging.saveSet(
        exercise: seed.row.exercise,
        set: seed.set,
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
      state = state.copyWith(submission: EntrySubmission.success);
    } catch (_) {
      if (!ref.mounted) return;
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
