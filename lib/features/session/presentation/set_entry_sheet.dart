import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/formatting/compact_number.dart';
import '../domain/reps_in_reserve.dart';
import '../domain/session_grid.dart';
import '../session_providers.dart';
import 'hold_timer_controller.dart';
import 'previous_session_reference.dart';

/// Quick entry for one set, with current-session and historical weight defaults.
Future<void> showSetEntrySheet(
  BuildContext context, {
  required SessionGridRow row,
  required SetEntry set,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SetEntrySheet(row: row, set: set),
  );
}

class _SetEntrySheet extends ConsumerStatefulWidget {
  const _SetEntrySheet({required this.row, required this.set});

  final SessionGridRow row;
  final SetEntry set;

  @override
  ConsumerState<_SetEntrySheet> createState() => _SetEntrySheetState();
}

class _SetEntrySheetState extends ConsumerState<_SetEntrySheet> {
  late final TextEditingController _weight;
  late final TextEditingController _reps;
  late final TextEditingController _left;
  late final TextEditingController _right;
  late final TextEditingController _notes;
  double? _rpe;
  int? _partials;
  String? _secondsError;
  bool _autoLog = false;
  bool _saving = false;

  bool get _durationBased => widget.row.isDurationBased;
  NotifierProvider<HoldTimerController, HoldTimerState> get _holdTimer =>
      holdTimerProvider(widget.set.id);

  SessionExercise get _exercise => widget.row.exercise;
  bool get _unilateral => _exercise.isUnilateral && !widget.row.isDurationBased;
  bool get _showWeight => _exercise.loadKind.tracksWeight;

  @override
  void initState() {
    super.initState();
    final s = widget.set;
    _weight = TextEditingController(
      text: widget.row.prefillWeightFor(s)?.let(compactNumber) ?? '',
    );
    _reps = TextEditingController(
      text:
          (widget.row.isDurationBased
                  ? widget.row.prefillSecondsFor(s)
                  : s.reps)
              ?.toString() ??
          '',
    );
    _left = TextEditingController(text: s.leftReps?.toString() ?? '');
    _right = TextEditingController(text: s.rightReps?.toString() ?? '');
    _notes = TextEditingController(text: s.notes ?? '');
    _rpe = s.rpe;
    _partials = s.partials;
  }

  @override
  void dispose() {
    for (final c in [_weight, _reps, _left, _right, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required SetStatus status}) async {
    if (_saving) return;
    setState(() => _saving = true);
    if (_durationBased) ref.read(_holdTimer.notifier).stop();
    try {
      await ref
          .read(sessionSetControllerProvider(_exercise.sessionId).notifier)
          .saveSet(
            exercise: _exercise,
            set: widget.set,
            weight: double.tryParse(_weight.text.trim()),
            reps: int.tryParse(_reps.text.trim()),
            leftReps: int.tryParse(_left.text.trim()),
            rightReps: int.tryParse(_right.text.trim()),
            rpe: _rpe,
            partials: _partials,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            status: status,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save set. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final hold = _durationBased ? ref.watch(_holdTimer) : null;
    if (_durationBased) {
      ref.listen(_holdTimer, (previous, next) {
        if (previous?.isRunning == true && next.remainingSeconds == 0) {
          unawaited(HapticFeedback.heavyImpact());
          if (_autoLog) unawaited(_save(status: SetStatus.completed));
        }
      });
    }
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${_exercise.displayName} · set ${widget.set.setNumber}',
                    style: theme.textTheme.titleMedium,
                  ),
                  PreviousSessionReference(row: widget.row),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (_showWeight) ...[
                        Expanded(
                          child: TextField(
                            controller: _weight,
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText:
                                  'Weight (${widget.set.weightUnit.label})',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (_unilateral) ...[
                        Expanded(
                          child: _repsField(
                            _left,
                            'Left reps',
                            autofocus: !_showWeight,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _repsField(_right, 'Right reps')),
                      ] else
                        Expanded(
                          child: _repsField(
                            _reps,
                            widget.row.isDurationBased ? 'Seconds' : 'Reps',
                            autofocus: !_showWeight,
                          ),
                        ),
                    ],
                  ),
                  if (hold != null) ...[
                    const SizedBox(height: 12),
                    if (hold.remainingSeconds != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          hold.isRunning
                              ? '${hold.remainingSeconds}s remaining'
                              : 'Hold complete',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : hold.isRunning
                          ? () => ref.read(_holdTimer.notifier).stop()
                          : _startHold,
                      icon: Icon(hold.isRunning ? Icons.stop : Icons.timer),
                      label: Text(
                        hold.isRunning ? 'Stop hold timer' : 'Start hold timer',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Log set when timer finishes'),
                      value: _autoLog,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _autoLog = value),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Reps in reserve (optional)',
                    style: theme.textTheme.labelMedium,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final rir in RepsInReserve.values)
                        ChoiceChip(
                          label: Text('${rir.label} RIR'),
                          selected: _rpe == rir.rpe,
                          onSelected: (selected) =>
                              setState(() => _rpe = selected ? rir.rpe : null),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_partials == null)
                        ActionChip(
                          label: const Text('+ Partials'),
                          tooltip: 'Add lengthened-position partial reps',
                          onPressed: () => setState(() => _partials = 3),
                        )
                      else ...[
                        IconButton(
                          tooltip: 'Remove partial rep',
                          onPressed: () => setState(
                            () => _partials = _partials! > 1
                                ? _partials! - 1
                                : null,
                          ),
                          icon: const Icon(Icons.remove),
                        ),
                        InputChip(
                          label: Text('+${_partials}p'),
                          tooltip: 'Lengthened-position partial reps',
                          onDeleted: () => setState(() => _partials = null),
                          deleteButtonTooltipMessage: 'Clear partials',
                        ),
                        IconButton(
                          tooltip: 'Add partial rep',
                          onPressed: () =>
                              setState(() => _partials = _partials! + 1),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                    minLines: 1,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => _save(status: SetStatus.skipped),
                    child: const Text('Skip'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _save(status: SetStatus.completed),
                    icon: const Icon(Icons.check),
                    label: const Text('Log set'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _repsField(
    TextEditingController controller,
    String label, {
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      enabled: !_durationBased || !ref.watch(_holdTimer).isRunning,
      autofocus: autofocus,
      decoration: InputDecoration(
        labelText: label,
        errorText: _durationBased ? _secondsError : null,
      ),
      onChanged: _durationBased
          ? (_) {
              ref.read(_holdTimer.notifier).stop();
              setState(() => _secondsError = null);
            }
          : null,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }

  void _startHold() {
    final seconds = int.tryParse(_reps.text.trim());
    if (seconds == null || seconds <= 0) {
      setState(() => _secondsError = 'Enter seconds greater than zero');
      return;
    }
    FocusScope.of(context).unfocus();
    ref.read(_holdTimer.notifier).start(seconds);
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
