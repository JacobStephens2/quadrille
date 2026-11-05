import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../domain/reps_in_reserve.dart';
import '../domain/session_grid.dart';
import 'previous_session_reference.dart';
import 'set_entry_controller.dart';

/// Quick entry for one set, with current-session and historical weight defaults.
Future<void> showSetEntrySheet(
  BuildContext context, {
  required SessionGridRow row,
  required SetEntry set,
}) {
  final seed = SetEntrySeed.open(
    ProviderScope.containerOf(context, listen: false),
    row: row,
    set: set,
  );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SetEntrySheet(seed: seed),
  );
}

class _SetEntrySheet extends ConsumerStatefulWidget {
  const _SetEntrySheet({required this.seed});

  final SetEntrySeed seed;
  SessionGridRow get row => seed.row;
  SetEntry get set => seed.set;

  @override
  ConsumerState<_SetEntrySheet> createState() => _SetEntrySheetState();
}

class _SetEntrySheetState extends ConsumerState<_SetEntrySheet> {
  late final TextEditingController _weight;
  late final TextEditingController _repsOrSeconds;
  late final TextEditingController _left;
  late final TextEditingController _right;
  late final TextEditingController _notes;
  late final SetEntrySeed _seed;
  bool _dismissed = false;

  bool get _durationBased => widget.row.isDurationBased;
  NotifierProvider<SetEntryController, SetEntryState> get _entry =>
      setEntryProvider(_seed);

  SessionExercise get _exercise => widget.row.exercise;
  bool get _unilateral => _exercise.isUnilateral && !widget.row.isDurationBased;
  bool get _showWeight => _exercise.loadKind.tracksWeight;

  @override
  void initState() {
    super.initState();
    _seed = widget.seed;
    final draft = ref.read(_entry).draft;
    _weight = TextEditingController(text: draft.weight);
    _repsOrSeconds = TextEditingController(text: draft.reps);
    _left = TextEditingController(text: draft.leftReps);
    _right = TextEditingController(text: draft.rightReps);
    _notes = TextEditingController(text: draft.notes);
  }

  @override
  void dispose() {
    for (final c in [_weight, _repsOrSeconds, _left, _right, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _edit(SetEntryDraft Function(SetEntryDraft) change) {
    ref.read(_entry.notifier).updateDraft(change(ref.read(_entry).draft));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final entry = ref.watch(_entry);
    final draft = entry.draft;
    final canEdit = entry.submission != EntrySubmission.superseded;
    final controller = ref.read(_entry.notifier);
    ref.listen(_entry, (previous, next) {
      if (next.submission == EntrySubmission.success &&
          mounted &&
          !_dismissed) {
        _dismissed = true;
        Navigator.of(context).pop();
      }
    });
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _dismissed = true;
          controller.stopHold();
        }
      },
      child: Padding(
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
                              enabled: canEdit,
                              onChanged: (value) =>
                                  _edit((d) => d.copyWith(weight: value)),
                              autofocus: true,
                              decoration: InputDecoration(
                                labelText:
                                    'Weight (${widget.set.weightUnit.label})',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
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
                            child: _countField(
                              _left,
                              'Left reps',
                              enabled: canEdit,
                              onChanged: (value) =>
                                  _edit((d) => d.copyWith(leftReps: value)),
                              autofocus: !_showWeight,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _countField(
                              _right,
                              'Right reps',
                              enabled: canEdit,
                              onChanged: (value) =>
                                  _edit((d) => d.copyWith(rightReps: value)),
                            ),
                          ),
                        ] else
                          Expanded(
                            child: _countField(
                              _repsOrSeconds,
                              widget.row.isDurationBased ? 'Seconds' : 'Reps',
                              autofocus: !_showWeight,
                              enabled:
                                  canEdit &&
                                  (!_durationBased ||
                                      (!entry.isHolding &&
                                          !entry.actionsDisabled)),
                              errorText: _durationBased
                                  ? entry.secondsError
                                  : null,
                              onChanged: (value) =>
                                  _edit((d) => d.copyWith(reps: value)),
                            ),
                          ),
                      ],
                    ),
                    if (_durationBased) ...[
                      const SizedBox(height: 12),
                      if (entry.remainingSeconds != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            entry.isHolding
                                ? '${entry.remainingSeconds}s remaining'
                                : 'Hold complete',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: entry.actionsDisabled
                            ? null
                            : entry.isHolding
                            ? controller.stopHold
                            : () {
                                FocusScope.of(context).unfocus();
                                controller.startHold();
                              },
                        icon: Icon(entry.isHolding ? Icons.stop : Icons.timer),
                        label: Text(
                          entry.isHolding
                              ? 'Stop hold timer'
                              : 'Start hold timer',
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Log set when timer finishes'),
                        value: entry.autoLog,
                        onChanged: entry.actionsDisabled
                            ? null
                            : controller.setAutoLog,
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
                            selected: draft.rpe == rir.rpe,
                            onSelected: canEdit
                                ? (selected) => _edit(
                                    (d) => d.copyWith(
                                      rpe: rir.rpe,
                                      clearRpe: !selected,
                                    ),
                                  )
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (draft.partials == null)
                          ActionChip(
                            label: const Text('+ Partials'),
                            tooltip: 'Add lengthened-position partial reps',
                            onPressed: canEdit ? controller.addPartial : null,
                          )
                        else ...[
                          IconButton(
                            tooltip: 'Remove partial rep',
                            onPressed: canEdit
                                ? controller.removePartial
                                : null,
                            icon: const Icon(Icons.remove),
                          ),
                          InputChip(
                            label: Text('+${draft.partials}p'),
                            tooltip: 'Lengthened-position partial reps',
                            onDeleted: canEdit
                                ? controller.clearPartials
                                : null,
                            deleteButtonTooltipMessage: 'Clear partials',
                          ),
                          IconButton(
                            tooltip: 'Add partial rep',
                            onPressed: canEdit ? controller.addPartial : null,
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notes,
                      enabled: canEdit,
                      onChanged: (value) =>
                          _edit((d) => d.copyWith(notes: value)),
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
            if (entry.saveError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  entry.saveError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: entry.actionsDisabled ? null : controller.skip,
                      child: const Text('Skip'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: entry.actionsDisabled ? null : controller.log,
                      icon: const Icon(Icons.check),
                      label: const Text('Log set'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countField(
    TextEditingController controller,
    String label, {
    bool autofocus = false,
    bool enabled = true,
    String? errorText,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      decoration: InputDecoration(labelText: label, errorText: errorText),
      onChanged: onChanged,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }
}
