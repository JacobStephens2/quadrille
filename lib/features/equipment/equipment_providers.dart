import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'data/equipment_busy_repository.dart';
import 'domain/equipment_busy_history.dart';

final equipmentBusyRepositoryProvider = Provider<EquipmentBusyRepository>((
  ref,
) {
  return EquipmentBusyRepository(ref.watch(databaseProvider));
});

final equipmentBusyHistoryProvider = StreamProvider.autoDispose
    .family<EquipmentBusyHistory, String>((ref, name) {
      return ref.watch(equipmentBusyRepositoryProvider).watchHistory(name);
    });

/// Serializes taps and keeps feedback within the invoking Local profile.
class EquipmentBusyController extends Notifier<AsyncValue<void>> {
  EquipmentBusyController(this.exerciseName);

  final String exerciseName;

  @override
  AsyncValue<void> build() {
    ref.watch(equipmentBusyRepositoryProvider);
    return const AsyncData(null);
  }

  Future<String?> record() {
    final at = DateTime.now();
    return _persist(
      (repository) => repository.recordBusy(exerciseName, at: at),
    );
  }

  Future<bool> undo(String id) async {
    return await _persist((repository) async {
          await repository.undo(id);
          return true;
        }) ??
        false;
  }

  Future<T?> _persist<T>(
    Future<T> Function(EquipmentBusyRepository) action,
  ) async {
    if (state.isLoading) return null;
    final repository = ref.read(equipmentBusyRepositoryProvider);
    bool isCurrent() =>
        ref.mounted &&
        identical(repository, ref.read(equipmentBusyRepositoryProvider));
    state = const AsyncLoading();
    try {
      final result = await action(repository);
      if (!isCurrent()) return null;
      state = const AsyncData(null);
      return result;
    } catch (error, stack) {
      if (isCurrent()) state = AsyncError(error, stack);
      return null;
    }
  }
}

final equipmentBusyControllerProvider = NotifierProvider.autoDispose
    .family<EquipmentBusyController, AsyncValue<void>, String>(
      EquipmentBusyController.new,
    );
