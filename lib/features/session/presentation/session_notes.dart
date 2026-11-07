import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session_providers.dart';
import '../session_notes_provider.dart';

/// The same overall workout notes are editable during and after a session.
class SessionNotesAction extends ConsumerWidget {
  const SessionNotesAction({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider(sessionId)).value;
    final save = ref.watch(saveSessionNotesProvider(sessionId));
    return IconButton(
      tooltip: 'Edit session notes',
      icon: const Icon(Icons.edit_note),
      onPressed: session == null || session.deletedAt != null
          ? null
          : () async {
              await showDialog<void>(
                context: context,
                builder: (_) => _SessionNotesDialog(
                  initialNotes: session.generalNotes ?? '',
                  onSave: save,
                ),
              );
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

class _SessionNotesDialog extends ConsumerStatefulWidget {
  const _SessionNotesDialog({required this.initialNotes, required this.onSave});

  final String initialNotes;
  final SaveSessionNotes onSave;

  @override
  ConsumerState<_SessionNotesDialog> createState() =>
      _SessionNotesDialogState();
}

class _SessionNotesDialogState extends ConsumerState<_SessionNotesDialog> {
  late final _controller = TextEditingController(text: widget.initialNotes);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = sessionNotesEditorProvider(widget.onSave);
    final state = ref.watch(editor);
    ref.listen(editor, (_, next) {
      if (next.value == true) Navigator.of(context).pop();
    });
    final error = state.hasError
        ? 'Could not save notes. Please try again.'
        : state.value == false
        ? 'Your local profile changed. Close and reopen session notes.'
        : null;
    return PopScope(
      canPop: !state.isLoading,
      child: AlertDialog(
        title: const Text('Edit session notes'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              enabled: !state.isLoading,
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
            onPressed: state.isLoading
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: state.isLoading || state.value == false
                ? null
                : () => ref.read(editor.notifier).save(_controller.text),
            child: Text(state.isLoading ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
