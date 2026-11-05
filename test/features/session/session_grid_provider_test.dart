import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';

/// Control only the database boundary; repository and provider remain real.
class ReadControl extends QueryInterceptor {
  Object? failure;
  int reads = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    reads++;
    if (executor is TransactionExecutor && failure != null) {
      return Future.error(failure!);
    }
    return executor.runSelect(statement, args);
  }
}

void main() {
  late ReadControl control;
  late QuadrilleDatabase db;
  late ProviderContainer container;
  late String sessionId;

  setUp(() async {
    control = ReadControl();
    db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(control),
    );
    final templates = TemplateRepository(db);
    final template = await templates.createTemplate(name: 'Push A');
    await templates.addExercise(
      template,
      TemplateExerciseDraft(displayName: 'Bench Press', orderLabel: '1'),
    );
    sessionId = await SessionRepository(db).startFromTemplate(template);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'provider starts loading and forwards complete repository grids',
    () async {
      final states = <AsyncValue<List<SessionGridRow>>>[];
      container.listen(
        sessionGridProvider(sessionId),
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      expect(states.single.isLoading, isTrue);

      final grid = await container.read(sessionGridProvider(sessionId).future);

      expect(grid.single.exercise.displayName, 'Bench Press');
      expect(grid.single.sets, hasLength(3));
      expect(states.last.requireValue, same(grid));
    },
  );

  test(
    'transactional read errors reach the provider asynchronous error state',
    () async {
      final failure = StateError('database read failed');
      control.failure = failure;
      container.listen(sessionGridProvider(sessionId), (_, _) {});

      await expectLater(
        container.read(sessionGridProvider(sessionId).future),
        throwsA(same(failure)),
      );

      expect(
        container.read(sessionGridProvider(sessionId)).error,
        same(failure),
      );
    },
  );

  test(
    'disposing the provider container releases database observation',
    () async {
      final states = <AsyncValue<List<SessionGridRow>>>[];
      container.listen(
        sessionGridProvider(sessionId),
        (_, next) => states.add(next),
      );
      await container.read(sessionGridProvider(sessionId).future);
      container.dispose();
      // Let Drift remove its canceled stream before issuing a new commit.
      await Future<void>.delayed(Duration.zero);
      final reads = control.reads;
      final delivered = states.length;

      await (db.update(db.workoutSessions)
            ..where((s) => s.id.equals(sessionId)))
          .write(const WorkoutSessionsCompanion(name: Value('Changed')));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(control.reads, reads);
      expect(states, hasLength(delivered));
      // tearDown owns a live container even after this explicit lifecycle check.
      container = ProviderContainer();
    },
  );
}
