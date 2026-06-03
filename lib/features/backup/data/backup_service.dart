import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// Versioned JSON export/import of user data — a local backup the user controls
/// and the cloud-sync payload.
///
/// Two scopes:
/// * [exportJson] / [importJson] — full backup (includes app_settings),
///   restore is a wipe-and-replace.
/// * [exportSyncPayload] / [mergeIntoLocal] — the sync scope (workout tables
///   only, no settings/creds), and a row-level last-write-wins MERGE into local
///   so a pull never clobbers unsynced local edits. Tombstones (`deletedAt`)
///   carry deletions.
///
/// Payload v2 shape: `{format, version: 2, tables: {tableKey: [rows]}}`.
class BackupService {
  BackupService(this._db);

  static const String formatTag = 'quadrille.backup';
  static const int formatVersion = 2;

  final QuadrilleDatabase _db;

  // ---- export ----

  Future<String> exportJson({required DateTime now}) async {
    return const JsonEncoder.withIndent('  ').convert({
      'format': formatTag,
      'version': formatVersion,
      'exportedAt': now.toUtc().toIso8601String(),
      'tables': await _exportTables(forSync: false),
    });
  }

  /// The sync-scoped payload: workout tables only (no app_settings, so sync
  /// credentials / device prefs never propagate across devices).
  Future<Map<String, dynamic>> exportSyncPayload() async {
    return {
      'format': formatTag,
      'version': formatVersion,
      'tables': await _exportTables(forSync: true),
    };
  }

  Future<Map<String, List<Map<String, dynamic>>>> _exportTables({
    required bool forSync,
  }) async {
    Future<List<Map<String, dynamic>>> rows<T extends Table, D>(
      TableInfo<T, D> table,
    ) async {
      final data = await _db.select(table).get();
      return data
          .map((r) => (r as dynamic).toJson() as Map<String, dynamic>)
          .toList();
    }

    final tables = <String, List<Map<String, dynamic>>>{
      'exercises': await rows(_db.exercises),
      'workoutTemplates': await rows(_db.workoutTemplates),
      'templateExercises': await rows(_db.templateExercises),
      'workoutSessions': await rows(_db.workoutSessions),
      'sessionExercises': await rows(_db.sessionExercises),
      'setEntries': await rows(_db.setEntries),
    };
    if (!forSync) {
      tables['appSettings'] = await rows(_db.appSettingsTable);
    }
    return tables;
  }

  // ---- full restore (wipe + replace) ----

  Future<ImportSummary> importJson(String jsonString) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException {
      throw const BackupFormatException('Not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('Unexpected backup structure.');
    }
    if (decoded['format'] != formatTag) {
      throw const BackupFormatException('Not a Quadrille backup file.');
    }
    final version = decoded['version'];
    if (version is! int || version > formatVersion) {
      throw BackupFormatException('Unsupported backup version: $version.');
    }
    // v2 nests rows under "tables"; v1 had them at the top level.
    final tables = decoded['tables'] is Map
        ? (decoded['tables'] as Map).cast<String, dynamic>()
        : decoded;
    List<Map<String, dynamic>> list(String key) => (tables[key] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    final summary = ImportSummary(
      exercises: list('exercises').length,
      templates: list('workoutTemplates').length,
      sessions: list('workoutSessions').length,
      sets: list('setEntries').length,
    );

    await _db.transaction(() async {
      await _db.delete(_db.setEntries).go();
      await _db.delete(_db.sessionExercises).go();
      await _db.delete(_db.workoutSessions).go();
      await _db.delete(_db.templateExercises).go();
      await _db.delete(_db.workoutTemplates).go();
      await _db.delete(_db.exercises).go();
      if (tables.containsKey('appSettings')) {
        await _db.delete(_db.appSettingsTable).go();
      }
      await _db.batch((batch) {
        for (final r in list('exercises')) {
          batch.insert(_db.exercises, Exercise.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('workoutTemplates')) {
          batch.insert(_db.workoutTemplates, WorkoutTemplate.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('templateExercises')) {
          batch.insert(_db.templateExercises, TemplateExercise.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('workoutSessions')) {
          batch.insert(_db.workoutSessions, WorkoutSession.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('sessionExercises')) {
          batch.insert(_db.sessionExercises, SessionExercise.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('setEntries')) {
          batch.insert(_db.setEntries, SetEntry.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
        for (final r in list('appSettings')) {
          batch.insert(_db.appSettingsTable, AppSettingsTableData.fromJson(r),
              mode: InsertMode.insertOrReplace);
        }
      });
    });
    return summary;
  }

  /// Clears all workout data (used when carrying guest data into an account so
  /// the guest profile can't leak to the next user on a shared device). Keeps
  /// app_settings (device prefs).
  Future<void> wipeAllData() async {
    await _db.transaction(() async {
      await _db.delete(_db.setEntries).go();
      await _db.delete(_db.sessionExercises).go();
      await _db.delete(_db.workoutSessions).go();
      await _db.delete(_db.templateExercises).go();
      await _db.delete(_db.workoutTemplates).go();
      await _db.delete(_db.exercises).go();
    });
  }

  // ---- sync merge (row-level LWW, no wipe) ----

  /// Merges a sync payload into the local DB: each incoming row is applied only
  /// when it's newer (by max(updatedAt, deletedAt)) than the local row, so
  /// unsynced local edits survive. Parents before children for FK safety.
  Future<void> mergeIntoLocal(Map<String, dynamic> payload) async {
    final tables = (payload['tables'] as Map?)?.cast<String, dynamic>() ?? {};
    List<Map<String, dynamic>> list(String key) => (tables[key] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    await _db.transaction(() async {
      await _mergeTable(_db.exercises, list('exercises'), Exercise.fromJson);
      await _mergeTable(_db.workoutTemplates, list('workoutTemplates'),
          WorkoutTemplate.fromJson);
      await _mergeTable(_db.templateExercises, list('templateExercises'),
          TemplateExercise.fromJson);
      await _mergeTable(
          _db.workoutSessions, list('workoutSessions'), WorkoutSession.fromJson);
      await _mergeTable(_db.sessionExercises, list('sessionExercises'),
          SessionExercise.fromJson);
      await _mergeTable(_db.setEntries, list('setEntries'), SetEntry.fromJson);
    });
  }

  Future<void> _mergeTable<T extends Table, D>(
    TableInfo<T, D> table,
    List<Map<String, dynamic>> incoming,
    Insertable<D> Function(Map<String, dynamic>) fromJson,
  ) async {
    if (incoming.isEmpty) return;
    final localTs = <String, int>{};
    for (final row in await _db.select(table).get()) {
      final json = (row as dynamic).toJson() as Map<String, dynamic>;
      localTs[json['id'] as String] = _rowTimestamp(json);
    }
    await _db.batch((batch) {
      for (final row in incoming) {
        final id = row['id'] as String?;
        if (id == null) continue;
        final local = localTs[id];
        if (local == null || _rowTimestamp(row) >= local) {
          batch.insert(table, fromJson(row), mode: InsertMode.insertOrReplace);
        }
      }
    });
  }

  static int _rowTimestamp(Map<String, dynamic> row) {
    int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
    final u = asInt(row['updatedAt']);
    final d = asInt(row['deletedAt']);
    return u > d ? u : d;
  }
}

/// Counts surfaced after a successful import.
class ImportSummary {
  const ImportSummary({
    required this.exercises,
    required this.templates,
    required this.sessions,
    required this.sets,
  });

  final int exercises;
  final int templates;
  final int sessions;
  final int sets;
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
