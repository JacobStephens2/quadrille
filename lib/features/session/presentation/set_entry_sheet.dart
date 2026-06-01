import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';
import '../session_providers.dart';

/// Quick entry for one set. Prefills from the set's current value or the
/// [prefillWeight] carried forward from the previous set, so re-logging is fast.
Future<void> showSetEntrySheet(
  BuildContext context, {
  required SessionExercise exercise,
  required SetEntry set,
  double? prefillWeight,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SetEntrySheet(
      exercise: exercise,
      set: set,
      prefillWeight: prefillWeight,
    ),
  );
}

class _SetEntrySheet extends ConsumerStatefulWidget {
  const _SetEntrySheet({
    required this.exercise,
    required this.set,
    this.prefillWeight,
  });

  final SessionExercise exercise;
  final SetEntry set;
  final double? prefillWeight;

  @override
  ConsumerState<_SetEntrySheet> createState() => _SetEntrySheetState();
}

class _SetEntrySheetState extends ConsumerState<_SetEntrySheet> {
  late final TextEditingController _weight;
  late final TextEditingController _reps;
  late final TextEditingController _left;
  late final TextEditingController _right;
  late final TextEditingController _notes;

  bool get _unilateral => widget.exercise.isUnilateral;
  bool get _showWeight => widget.exercise.loadKind != LoadKind.bodyweight &&
      widget.exercise.loadKind != LoadKind.none &&
      widget.exercise.loadKind != LoadKind.timeOnly;

  @override
  void initState() {
    super.initState();
    final s = widget.set;
    _weight = TextEditingController(
      text: (s.weight ?? widget.prefillWeight)?.let(_trimDouble) ?? '',
    );
    _reps = TextEditingController(text: s.reps?.toString() ?? '');
    _left = TextEditingController(text: s.leftReps?.toString() ?? '');
    _right = TextEditingController(text: s.rightReps?.toString() ?? '');
    _notes = TextEditingController(text: s.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [_weight, _reps, _left, _right, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required SetStatus status}) async {
    final repo = ref.read(sessionRepositoryProvider);
    await repo.saveSet(
      widget.set.id,
      weight: double.tryParse(_weight.text.trim()),
      reps: int.tryParse(_reps.text.trim()),
      leftReps: int.tryParse(_left.text.trim()),
      rightReps: int.tryParse(_right.text.trim()),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      status: status,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.exercise.displayName} · set ${widget.set.setNumber}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_showWeight) ...[
                Expanded(
                  child: TextField(
                    controller: _weight,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Weight (${widget.set.weightUnit.label})',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
              ],
              if (_unilateral) ...[
                Expanded(child: _repsField(_left, 'Left reps', autofocus: !_showWeight)),
                const SizedBox(width: 12),
                Expanded(child: _repsField(_right, 'Right reps')),
              ] else
                Expanded(child: _repsField(_reps, 'Reps', autofocus: !_showWeight)),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
            minLines: 1,
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _save(status: SetStatus.skipped),
                  child: const Text('Skip'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () => _save(status: SetStatus.completed),
                  icon: const Icon(Icons.check),
                  label: const Text('Log set'),
                ),
              ),
            ],
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
      autofocus: autofocus,
      decoration: InputDecoration(labelText: label),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }
}

String _trimDouble(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
