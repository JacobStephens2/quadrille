import 'package:drift/drift.dart';

import '../../../core/database/database.dart';
import '../../../core/domain/enums.dart';

/// Reads and writes the singleton app-settings row (seeded on first launch).
class SettingsRepository {
  SettingsRepository(this._db);

  static const _singleton = 'singleton';

  final QuadrilleDatabase _db;

  Stream<AppSettingsTableData> watch() {
    return (_db.select(_db.appSettingsTable)
          ..where((s) => s.id.equals(_singleton)))
        .watchSingle();
  }

  Future<AppSettingsTableData> read() {
    return (_db.select(_db.appSettingsTable)
          ..where((s) => s.id.equals(_singleton)))
        .getSingle();
  }

  Future<void> update({
    WeightUnit? units,
    int? defaultRestSeconds,
    bool? autoStartTimer,
    bool? keepScreenAwake,
    bool? watchHapticsEnabled,
    String? syncEndpoint,
    Value<String?> syncToken = const Value.absent(),
    bool? autoSync,
    Value<DateTime?> lastSyncAt = const Value.absent(),
    int? lastSyncedRevision,
  }) async {
    await (_db.update(_db.appSettingsTable)
          ..where((s) => s.id.equals(_singleton)))
        .write(
      AppSettingsTableCompanion(
        units: units == null ? const Value.absent() : Value(units),
        defaultRestSeconds: defaultRestSeconds == null
            ? const Value.absent()
            : Value(defaultRestSeconds),
        autoStartTimer:
            autoStartTimer == null ? const Value.absent() : Value(autoStartTimer),
        keepScreenAwake: keepScreenAwake == null
            ? const Value.absent()
            : Value(keepScreenAwake),
        watchHapticsEnabled: watchHapticsEnabled == null
            ? const Value.absent()
            : Value(watchHapticsEnabled),
        syncEndpoint:
            syncEndpoint == null ? const Value.absent() : Value(syncEndpoint),
        syncToken: syncToken,
        autoSync: autoSync == null ? const Value.absent() : Value(autoSync),
        lastSyncAt: lastSyncAt,
        lastSyncedRevision: lastSyncedRevision == null
            ? const Value.absent()
            : Value(lastSyncedRevision),
      ),
    );
  }
}
