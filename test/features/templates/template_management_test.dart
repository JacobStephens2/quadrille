import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/template_management.dart';
import 'package:quadrille/features/templates/template_providers.dart';

import 'template_management_fixture.dart';

// Lifecycle scenarios (reentrancy, every retirement reason and timing,
// retry admission, release) live at the Retained opening seam in
// test/core/retained_opening_test.dart. These tests pin what is specific
// to Template management: the four actions and their result identifier,
// blank-name failure, the duplicate/archive sharing key, copied rows, and
// destination retention across a profile switch.
void main() {
  late ManagementFixture fixture;
  setUp(() async {
    fixture = ManagementFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  TemplateManagementOpening bind(
    TemplateManagementAction action, {
    String id = 't1',
    String sourceName = 'Push A',
  }) {
    final owner = fixture.container.read(templateManagementProvider);
    final opening = switch (action) {
      TemplateManagementAction.create => owner.create(),
      TemplateManagementAction.rename => owner.rename(id, sourceName),
      TemplateManagementAction.duplicate => owner.duplicate(id, sourceName),
      TemplateManagementAction.archive => owner.archive(id),
    };
    addTearDown(opening.release);
    return opening;
  }

  Future<void> expectOriginal() async {
    for (final db in [fixture.a, fixture.b]) {
      final repo = TemplateRepository(db);
      expect((await repo.watchTemplates().first).map((t) => t.name), [
        'Push A',
      ]);
      expect((await repo.watchTemplate('t1').first)!.archived, isFalse);
    }
  }

  for (final action in TemplateManagementAction.values) {
    test(
      '${action.name} succeeds and persists only in its captured destination',
      () async {
        final opening = bind(action);
        expect(
          await opening.submit(name: ' Changed '),
          TemplateManagementState.succeeded,
        );
        expect(fixture.aRepository.submissions, 1);
        expect(opening.canSubmit, isFalse);
        final a = TemplateRepository(fixture.a);
        final result = await a.watchTemplate(opening.resultId!).first;
        expect(result, isNotNull);
        expect(result!.name, switch (action) {
          TemplateManagementAction.create ||
          TemplateManagementAction.rename => 'Changed',
          TemplateManagementAction.duplicate => 'Push A (copy)',
          TemplateManagementAction.archive => 'Push A',
        });
        if (action == TemplateManagementAction.archive) {
          expect(await a.watchTemplates().first, isEmpty);
        }
        if (action == TemplateManagementAction.duplicate) {
          expect(result.id, isNot('t1'));
          expect(result.dayLabel, 'Monday');
          expect(result.notes, 'Warm up');
          expect(result.sortOrder, 5);
          final rows = await a.watchExercises(result.id).first;
          expect(rows.single.id, isNot('r1'));
          expect(rows.single.displayName, 'Bench Press');
        }
        expect(
          (await fixture.bRepository.watchTemplates().first).map((t) => t.name),
          ['Push A'],
        );
      },
    );

    test(
      '${action.name} failure is recoverable and retry retains its name',
      () async {
        final opening = bind(action);
        fixture.aRepository.fail = true;
        expect(
          await opening.submit(name: ' Retry name '),
          TemplateManagementState.failed,
        );
        expect(opening.errorMessage, contains('Please try again'));
        expect(opening.canSubmit, isTrue);
        await expectOriginal();
        fixture.aRepository.fail = false;
        expect(await opening.submit(), TemplateManagementState.succeeded);
        if (opening.requiresName) {
          expect(
            (await fixture.aRepository.watchTemplate(opening.resultId!).first)!
                .name,
            'Retry name',
          );
        }
      },
    );

    for (final fails in [false, true]) {
      test(
        '${action.name} accepted ${fails ? 'failure' : 'success'} after a profile switch stays in captured A',
        () async {
          final opening = bind(action);
          final repository = fixture.aRepository;
          final gate = ManagementGate();
          repository.gate = gate;
          repository.fail = fails;
          final pending = opening.submit(name: 'Captured');
          await gate.entered.future;
          fixture.switchToB();
          expect(opening.isCurrent, isFalse);
          // Canonical prologue (Spec #98): retirement rejects new
          // submission, so this returns superseded immediately instead
          // of joining the pending future.
          expect(opening.submit(name: 'Again'), isNot(same(pending)));
          expect(
            await opening.submit(name: 'Again'),
            TemplateManagementState.superseded,
          );
          gate.completion.complete();
          expect(await pending, TemplateManagementState.superseded);
          expect(opening.state, TemplateManagementState.superseded);
          expect(repository.submissions, 1);
          final a = TemplateRepository(fixture.a);
          final rows = await a.watchTemplates().first;
          expect(
            rows.map((t) => t.name),
            fails
                ? ['Push A']
                : switch (action) {
                    TemplateManagementAction.create => ['Captured', 'Push A'],
                    TemplateManagementAction.rename => ['Captured'],
                    TemplateManagementAction.duplicate => [
                      'Push A',
                      'Push A (copy)',
                    ],
                    TemplateManagementAction.archive => <String>[],
                  },
          );
          expect(
            (await fixture.bRepository.watchTemplates().first).map(
              (t) => t.name,
            ),
            ['Push A'],
          );
        },
      );
    }
  }

  for (final action in [
    TemplateManagementAction.create,
    TemplateManagementAction.rename,
  ]) {
    test(
      '${action.name} rejects blank names without persistence and allows correction',
      () async {
        final opening = bind(action);
        expect(
          await opening.submit(name: '  \n  '),
          TemplateManagementState.failed,
        );
        expect(opening.errorMessage, 'Name is required');
        expect(fixture.aRepository.submissions, 0);
        await expectOriginal();
        fixture.aRepository.fail = true;
        expect(
          await opening.submit(name: ' Corrected '),
          TemplateManagementState.failed,
        );
        expect(opening.errorMessage, contains('Please try again'));
        fixture.aRepository.fail = false;
        expect(await opening.submit(), TemplateManagementState.succeeded);
      },
    );
  }

  test(
    'a blank name does not disturb a pending or succeeded submission',
    () async {
      final opening = bind(TemplateManagementAction.create);
      final gate = ManagementGate();
      fixture.aRepository.gate = gate;
      final first = opening.submit(name: 'First');
      expect(opening.submit(name: '  '), same(first));
      expect(opening.errorMessage, isNull);
      await gate.entered.future;
      gate.completion.complete();
      expect(await first, TemplateManagementState.succeeded);
      expect(
        await opening.submit(name: '  '),
        TemplateManagementState.succeeded,
      );
      expect(opening.errorMessage, isNull);
      expect(fixture.aRepository.submissions, 1);
      expect(
        (await fixture.aRepository.watchTemplate(opening.resultId!).first)!
            .name,
        'First',
      );
    },
  );

  test(
    'state reports superseded when its captured template repository is replaced',
    () async {
      final opening = bind(TemplateManagementAction.create);
      fixture.aRepository.fail = true;
      expect(
        await opening.submit(name: 'Changed'),
        TemplateManagementState.failed,
      );
      expect(
        opening.errorMessage,
        'Could not create template. Please try again.',
      );
      final captured = fixture.aRepository;
      fixture.container.invalidate(templateRepositoryProvider);
      expect(opening.state, TemplateManagementState.superseded);
      expect(opening.errorMessage, isNull);
      expect(opening.isCurrent, isFalse);
      expect(opening.canSubmit, isFalse);
      expect(
        await opening.submit(name: 'Again'),
        TemplateManagementState.superseded,
      );
      expect(captured.submissions, 1);
      await expectOriginal();
    },
  );

  for (final action in [
    TemplateManagementAction.duplicate,
    TemplateManagementAction.archive,
  ]) {
    test(
      '${action.name} shares only in-flight submissions by operation and target',
      () async {
        final first = bind(action);
        final second = bind(action, sourceName: 'Later display name');
        final gate = ManagementGate();
        fixture.aRepository.gate = gate;
        Future<TemplateManagementState>? joined;
        first.addListener(() {
          if (first.state == TemplateManagementState.pending) {
            joined = second.submit();
          }
        });
        final pending = first.submit();
        await gate.entered.future;
        expect(fixture.aRepository.submissions, 1);
        first.release();
        gate.completion.complete();
        expect(await pending, TemplateManagementState.superseded);
        expect(await joined, TemplateManagementState.succeeded);
        expect(second.resultId, isNotNull);
        final later = bind(action);
        expect(await later.submit(), TemplateManagementState.succeeded);
        expect(fixture.aRepository.submissions, 2);
        if (action == TemplateManagementAction.duplicate) {
          expect(later.resultId, isNot(second.resultId));
          expect(
            (await fixture.aRepository.watchTemplates().first).map(
              (t) => t.name,
            ),
            ['Push A', 'Push A (copy)', 'Push A (copy)'],
          );
        }
      },
    );
  }

  test(
    'different immediate operations and targets do not share admission',
    () async {
      final gate = ManagementGate();
      fixture.aRepository.gate = gate;
      final copy = bind(TemplateManagementAction.duplicate);
      final missing = bind(TemplateManagementAction.duplicate, id: 'missing');
      final archive = bind(TemplateManagementAction.archive);
      final futures = [copy.submit(), missing.submit(), archive.submit()];
      expect(fixture.aRepository.submissions, 3);
      gate.completion.complete();
      expect(await Future.wait(futures), [
        TemplateManagementState.succeeded,
        TemplateManagementState.failed,
        TemplateManagementState.succeeded,
      ]);
    },
  );

  test(
    'duplicate uses its opening source name and copies only live rows',
    () async {
      final opening = bind(
        TemplateManagementAction.duplicate,
        sourceName: 'Frozen name',
      );
      await fixture.aRepository.updateTemplate('t1', name: 'Renamed meanwhile');
      await fixture.aRepository.deleteExercise('r1');
      expect(await opening.submit(), TemplateManagementState.succeeded);
      expect(
        (await fixture.aRepository.watchTemplate(opening.resultId!).first)!
            .name,
        'Frozen name (copy)',
      );
      expect(
        await fixture.aRepository.watchExercises(opening.resultId!).first,
        isEmpty,
      );
    },
  );

  test(
    'archived, tombstoned and missing targets retain repository policy',
    () async {
      await fixture.aRepository.archiveTemplate('t1');
      await (fixture.a.update(fixture.a.workoutTemplates)
            ..where((t) => t.id.equals('t1')))
          .write(WorkoutTemplatesCompanion(deletedAt: Value(DateTime(2026))));
      for (final action in [
        TemplateManagementAction.rename,
        TemplateManagementAction.duplicate,
        TemplateManagementAction.archive,
      ]) {
        expect(
          await bind(action).submit(name: 'Still permitted'),
          TemplateManagementState.succeeded,
        );
        expect(
          await bind(action, id: 'missing').submit(name: 'Missing'),
          action == TemplateManagementAction.duplicate
              ? TemplateManagementState.failed
              : TemplateManagementState.succeeded,
        );
      }
      expect(
        (await fixture.aRepository.watchTemplate('t1').first)!.deletedAt,
        isNotNull,
      );
      expect(
        (await fixture.aRepository.watchTemplate('t1').first)!.archived,
        isTrue,
      );
    },
  );
}
