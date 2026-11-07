import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../session/session_providers.dart';

typedef DeleteHistorySession = Future<bool> Function();

/// Capture before confirmation so an old dialog cannot delete in a new profile.
final deleteHistorySessionProvider =
    Provider.family<DeleteHistorySession, String>((ref, sessionId) {
      ref.watch(currentProfileProvider);
      final repository = ref.watch(sessionRepositoryProvider);
      var current = true;
      void invalidate() => current = false;
      ref.listen(currentProfileProvider, (_, _) => invalidate());
      ref.listen(databaseProvider, (_, _) => invalidate());
      ref.onDispose(invalidate);
      bool isCurrent() =>
          current &&
          ref.mounted &&
          identical(repository, ref.read(sessionRepositoryProvider));

      return () async {
        if (!isCurrent()) return false;
        final deleted = await repository.deleteCompletedSession(sessionId);
        return isCurrent() && deleted;
      };
    });

/// Keeps one confirmation's pending, retry and obsolete-opening state together.
class HistoryDeletionController extends Notifier<AsyncValue<bool?>> {
  HistoryDeletionController(this._delete);

  final DeleteHistorySession _delete;

  @override
  AsyncValue<bool?> build() => const AsyncData(null);

  Future<void> delete() async {
    if (state.isLoading || state.value != null) return;
    state = const AsyncLoading();
    try {
      final deleted = await _delete();
      if (ref.mounted) state = AsyncData(deleted);
    } catch (error, stack) {
      if (ref.mounted) state = AsyncError(error, stack);
    }
  }
}

final historyDeletionControllerProvider = NotifierProvider.autoDispose
    .family<HistoryDeletionController, AsyncValue<bool?>, DeleteHistorySession>(
      HistoryDeletionController.new,
    );
