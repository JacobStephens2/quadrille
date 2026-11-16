import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/presentation/presentation_opening.dart';
import '../session_providers.dart';
import '../session_notes_editing.dart';

/// The same overall workout notes are editable during and after a session.
class SessionNotesAction extends ConsumerWidget {
  const SessionNotesAction({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A dependency reload can retain the previous profile's workout value.
    // Admit an editor only once this owner's stream supplies a current snapshot.
    final session = ref.watch(sessionProvider(sessionId)).loadedValue;
    final editing = ref.watch(sessionNotesEditingProvider);
    return IconButton(
      tooltip: 'Edit session notes',
      icon: const Icon(Icons.edit_note),
      onPressed: session == null || session.deletedAt != null
          ? null
          : () async {
              final opening = editing.edit(session);
              final presentation = PresentationOpening.capture(context);
              try {
                await showDialog<void>(
                  context: context,
                  builder: (context) => _SessionNotesDialog(
                    opening: opening,
                    presentation: presentation.bindModal(context),
                  ),
                );
              } finally {
                opening.release();
              }
            },
    );
  }
}

class SessionNotesCard extends StatelessWidget {
  const SessionNotesCard({super.key, required this.notes});

  final String? notes;

  @override
  Widget build(BuildContext context) {
    final text = notes;
    if (text == null || text.trim().isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const Icon(Icons.notes),
        title: const Text('Session notes'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(alignment: Alignment.centerLeft, child: Text(text)),
          ),
        ],
      ),
    );
  }
}

class _SessionNotesDialog extends StatefulWidget {
  const _SessionNotesDialog({
    required this.opening,
    required this.presentation,
  });

  final SessionNotesOpening opening;
  final PresentationOpening presentation;

  @override
  State<_SessionNotesDialog> createState() => _SessionNotesDialogState();
}

class _SessionNotesDialogState extends State<_SessionNotesDialog> {
  late final _controller = TextEditingController(
    text: widget.opening.initialNotes,
  );
  bool _silent = false;

  @override
  void dispose() {
    widget.opening.release();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!widget.opening.canSubmit) return;
    setState(() => _silent = false);
    final result = await widget.opening.save(_controller.text);
    if (!mounted) return;
    if (!widget.presentation.isCurrent) {
      // A hidden completion stays silent even after a later uncovering.
      setState(() => _silent = true);
      return;
    }
    if (widget.opening.isCurrent &&
        result == SessionNotesEditingState.succeeded) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.opening,
    builder: (context, _) {
      final opening = widget.opening;
      final pending = opening.state == SessionNotesEditingState.pending;
      final error = !opening.isCurrent
          ? 'Your local profile changed. Close and reopen session notes.'
          : !_silent
          ? opening.errorMessage
          : null;
      return PopScope(
        canPop: !pending,
        child: AlertDialog(
          title: const Text('Edit session notes'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _controller,
                enabled: opening.canSubmit,
                autofocus: true,
                minLines: 4,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Session notes'),
              ),
              if (error != null) Text(error),
            ],
          ),
          actions: [
            TextButton(
              onPressed: pending ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: opening.canSubmit ? _save : null,
              child: Text(pending ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      );
    },
  );
}
