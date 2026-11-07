import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/exercises/data/exercise_history_service.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test(
    'history deletion preserves active workouts and ignores missing records',
    () async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final sessions = SessionRepository(db);
      final template = await TemplateRepository(
        db,
      ).createTemplate(name: 'Push A');
      final active = await sessions.startFromTemplate(template);

      expect(await sessions.deleteCompletedSession(active), isFalse);
      expect(await sessions.deleteCompletedSession('missing'), isFalse);
      expect((await sessions.watchActiveSession().first)!.id, active);
      expect(
        (await sessions.watchSession(active).first)!.status,
        SessionStatus.active,
      );
      expect(await sessions.discardSession(active), isTrue);
      expect(await sessions.deleteCompletedSession(active), isFalse);
    },
  );

  test(
    'completed deletion removes records and syncs without resurrection',
    () async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      final replica = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      addTearDown(replica.close);
      final sessions = SessionRepository(db);
      final templates = TemplateRepository(db);
      final template = await templates.createTemplate(name: 'Push A');
      await templates.addExercise(
        template,
        TemplateExerciseDraft(displayName: 'Bench Press', orderLabel: '1'),
      );
      final id = await sessions.startFromTemplate(template);
      final set = (await sessions.readGrid(id)).single.sets.first;
      await sessions.saveSet(set.id, weight: 100, reps: 10);
      await sessions.completeSession(id);
      final history = ExerciseHistoryService(db);
      expect(
        (await history.watchForName('Bench Press').first).stats.sessionCount,
        1,
      );
      final backup = BackupService(db);
      final stale = await backup.exportSyncPayload();
      final replicaBackup = BackupService(replica);
      await replicaBackup.mergeIntoLocal(stale);

      expect(await sessions.deleteCompletedSession(id), isTrue);

      expect(await sessions.watchHistory().first, isEmpty);
      expect(await sessions.readGrid(id), isEmpty);
      final records = await history.watchForName('Bench Press').first;
      expect(records.sessions, isEmpty);
      expect(records.stats.heaviestWeight, isNull);
      expect(await templates.watchTemplate(template).first, isNotNull);
      final deleted = await backup.exportSyncPayload();
      final tables = deleted['tables'] as Map<String, dynamic>;
      for (final key in ['workoutSessions', 'sessionExercises', 'setEntries']) {
        final rows = (tables[key] as List).cast<Map<String, dynamic>>();
        expect(rows, isNotEmpty);
        expect(rows.every((row) => row['deletedAt'] != null), isTrue);
        expect(
          rows.every((row) => row['updatedAt'] == row['deletedAt']),
          isTrue,
        );
      }
      await replicaBackup.mergeIntoLocal(deleted);
      expect(await SessionRepository(replica).watchHistory().first, isEmpty);
      expect(await SessionRepository(replica).readGrid(id), isEmpty);
      await backup.mergeIntoLocal(stale);
      expect(await sessions.watchHistory().first, isEmpty);
      expect(await sessions.readGrid(id), isEmpty);
      final retained =
          (await backup.exportSyncPayload())['tables'] as Map<String, dynamic>;
      for (final key in ['workoutSessions', 'sessionExercises', 'setEntries']) {
        expect(
          (retained[key] as List).cast<Map<String, dynamic>>().every(
            (row) => row['deletedAt'] != null,
          ),
          isTrue,
        );
      }
      expect(await sessions.deleteCompletedSession(id), isFalse);
    },
  );

  test('unchanged pre-deletion sync rows cannot resurrect history', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionRepository(db);
    final backup = BackupService(db);
    final template = await TemplateRepository(
      db,
    ).createTemplate(name: 'Push A');
    for (var attempt = 0; attempt < 20; attempt++) {
      final id = await sessions.startFromTemplate(template);
      final startedSecond = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await sessions.completeSession(id);
      final stale = await backup.exportSyncPayload();
      expect(await sessions.deleteCompletedSession(id), isTrue);
      final endedSecond = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (startedSecond != endedSecond) continue;
      await backup.mergeIntoLocal(stale);
      expect(
        await sessions.watchHistory().first,
        isEmpty,
        reason:
            'A stale pre-deletion snapshot with the same stored timestamp '
            'must not overwrite the deletion tombstone.',
      );
      return;
    }
    fail('Could not complete and delete within one wall-clock second.');
  });
}
