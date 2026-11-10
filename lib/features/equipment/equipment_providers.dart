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

/// Feedback and an Undo operation bound to the original save's owner.
class EquipmentBusyResult {
  EquipmentBusyResult._(this.saved, this._isCurrent, this._undo);

  final bool saved;
  final bool Function() _isCurrent;
  final Future<bool> Function() _undo;

  bool get isCurrent => _isCurrent();

  Future<bool> undo() => _undo();
}

/// Serializes taps and keeps feedback within the invoking Local profile.
class EquipmentBusyController extends Notifier<AsyncValue<void>> {
  EquipmentBusyController(this.exerciseName);

  final String exerciseName;
  Object _generation = Object();

  @override
  AsyncValue<void> build() {
    ref.watch(currentProfileProvider);
    ref.watch(equipmentBusyRepositoryProvider);
    _generation = Object();
    return const AsyncData(null);
  }

  Future<EquipmentBusyResult> record() async {
    final repository = ref.read(equipmentBusyRepositoryProvider);
    final generation = _generation;
    bool isCurrent() =>
        ref.mounted &&
        identical(generation, _generation) &&
        identical(repository, ref.read(equipmentBusyRepositoryProvider));
    final at = DateTime.now();
    final id = await _persist(
      isCurrent,
      () => repository.recordBusy(exerciseName, at: at),
    );
    return EquipmentBusyResult._(id != null, isCurrent, () async {
      if (id == null) return false;
      return await _persist(isCurrent, () async {
            await repository.undo(id);
            return true;
          }) ??
          false;
    });
  }

  Future<T?> _persist<T>(
    bool Function() isCurrent,
    Future<T> Function() action,
  ) async {
    if (!isCurrent() || state.isLoading) return null;
    state = const AsyncLoading();
    try {
      final result = await action();
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
