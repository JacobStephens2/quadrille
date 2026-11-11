import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'session_providers.dart';

/// Returns false when the opening's Local profile generation is obsolete.
typedef SaveSessionNotes = Future<bool> Function(String notes);

/// Capture this operation before opening the editor, never at Save time.
final saveSessionNotesProvider = Provider.autoDispose
    .family<SaveSessionNotes, String>((ref, sessionId) {
      final generation = ref.watch(localProfileGenerationProvider);
      final repository = ref.watch(sessionRepositoryProvider);
      var current = true;
      void invalidate() => current = false;
      ref.onDispose(invalidate);
      bool isCurrent() =>
          current &&
          ref.mounted &&
          generation.isCurrent &&
          identical(repository, ref.read(sessionRepositoryProvider));

      return (notes) async {
        if (!isCurrent()) return false;
        await repository.setSessionNotes(sessionId, notes);
        return isCurrent();
      };
    });

/// Pending, retry and obsolete-opening state for one notes editor.
class SessionNotesEditor extends Notifier<AsyncValue<bool?>> {
  SessionNotesEditor(this._save);

  final SaveSessionNotes _save;

  @override
  AsyncValue<bool?> build() => const AsyncData(null);

  Future<void> save(String notes) async {
    if (state.isLoading || state.value == false) return;
    state = const AsyncLoading();
    try {
      final saved = await _save(notes);
      if (ref.mounted) state = AsyncData(saved);
    } catch (error, stack) {
      if (ref.mounted) state = AsyncError(error, stack);
    }
  }
}

final sessionNotesEditorProvider = NotifierProvider.autoDispose
    .family<SessionNotesEditor, AsyncValue<bool?>, SaveSessionNotes>(
      SessionNotesEditor.new,
    );
