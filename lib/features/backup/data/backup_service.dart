import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// Versioned JSON export/import of all user data — a local backup the user
/// controls, and the foundation for a future sync payload.
///
/// Import is a full replace (restore-from-backup semantics): the database is
/// wiped and rebuilt inside one transaction, so a malformed file leaves the
/// existing data untouched.
class BackupService {
  BackupService(this._db);

  static const String formatTag = 'quadrille.backup';
  static const int formatVersion = 1;

  final QuadrilleDatabase _db;

  /// Serializes every table (except the ephemeral active timer) to a JSON
  /// string. [now] is injected so callers stamp the time deterministically.
  Future<String> exportJson({required DateTime now}) async {
    Future<List<Map<String, dynamic>>> rows<T extends Table, D>(
      TableInfo<T, D> table,
    ) async {
      final data = await _db.select(table).get();
      return data
          .map((r) => (r as dynamic).toJson() as Map<String, dynamic>)
          .toList();
    }

    final payload = <String, dynamic>{
      'format': formatTag,
      'version': formatVersion,
      'exportedAt': now.toUtc().toIso8601String(),
      'exercises': await rows(_db.exercises),
      'workoutTemplates': await rows(_db.workoutTemplates),
      'templateExercises': await rows(_db.templateExercises),
      'workoutSessions': await rows(_db.workoutSessions),
      'sessionExercises': await rows(_db.sessionExercises),
      'setEntries': await rows(_db.setEntries),
      'appSettings': await rows(_db.appSettingsTable),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Replaces all data from a previously exported [jsonString]. Throws
  /// [BackupFormatException] if the file isn't a recognized Quadrille backup.
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
    final map = decoded;
    if (map['format'] != formatTag) {
      throw const BackupFormatException('Not a Quadrille backup file.');
    }
    final version = map['version'];
    if (version is! int || version > formatVersion) {
      throw BackupFormatException('Unsupported backup version: $version.');
    }

    List<Map<String, dynamic>> list(String key) =>
        (map[key] as List? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

    final summary = ImportSummary(
      exercises: list('exercises').length,
      templates: list('workoutTemplates').length,
      sessions: list('workoutSessions').length,
      sets: list('setEntries').length,
    );

    await _db.transaction(() async {
      // Children before parents (FK-safe delete).
      await _db.delete(_db.setEntries).go();
      await _db.delete(_db.sessionExercises).go();
      await _db.delete(_db.workoutSessions).go();
      await _db.delete(_db.templateExercises).go();
      await _db.delete(_db.workoutTemplates).go();
      await _db.delete(_db.exercises).go();
      await _db.delete(_db.appSettingsTable).go();

      // Parents before children (FK-safe insert).
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
