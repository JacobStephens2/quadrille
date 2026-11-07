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

class _SessionNotesDialog extends StatefulWidget {
  const _SessionNotesDialog({required this.initialNotes, required this.onSave});

  final String initialNotes;
  final SaveSessionNotes onSave;

  @override
  State<_SessionNotesDialog> createState() => _SessionNotesDialogState();
}

class _SessionNotesDialogState extends State<_SessionNotesDialog> {
  late final _controller = TextEditingController(text: widget.initialNotes);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(_controller.text);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _saving = false;
          _error =
              'Your local profile changed. Close and reopen session notes.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save notes. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Edit session notes'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              enabled: !_saving,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Session notes'),
            ),
            if (_error != null) Text(_error!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
