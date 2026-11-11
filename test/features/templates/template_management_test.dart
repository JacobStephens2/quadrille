import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/template_management.dart';
import 'package:quadrille/features/templates/template_providers.dart';

import 'template_management_fixture.dart';

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

  void retire(String transition) {
    switch (transition) {
      case 'profile switch':
        fixture.switchToB();
      case 'unobserved round trip':
        fixture.switchToB();
        fixture.current = fixture.a;
        fixture.container
            .read(currentProfileProvider.notifier)
            .set(localProfileName);
      case 'database replacement':
        fixture.current = fixture.b;
        fixture.container.invalidate(databaseProvider);
      case 'repository replacement':
        fixture.container.invalidate(templateRepositoryProvider);
      case 'management invalidation':
        fixture.container.invalidate(templateManagementProvider);
      case 'container disposal':
        fixture.container.dispose();
        fixture.disposed = true;
    }
  }

  for (final action in TemplateManagementAction.values) {
    test(
      '${action.name} succeeds once and persists only in its captured destination',
      () async {
        final opening = bind(action);
        final gate = ManagementGate();
        fixture.aRepository.gate = gate;
        Future<TemplateManagementState>? reentrant;
        opening.addListener(() {
          if (opening.state == TemplateManagementState.pending) {
            reentrant = opening.submit(name: 'Ignored');
          }
        });
        final pending = opening.submit(name: ' Changed ');
        expect(reentrant, same(pending));
        expect(opening.canSubmit, isFalse);
        expect(opening.submit(name: 'Also ignored'), same(pending));
        await gate.entered.future;
        gate.completion.complete();
        expect(await pending, TemplateManagementState.succeeded);
        expect(
          await opening.submit(name: 'Again'),
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

    test(
      '${action.name} cancellation and release before admission produce no writes',
      () async {
        final opening = bind(action);
        opening.release();
        opening.release();
        expect(
          await opening.submit(name: 'Cancelled'),
          TemplateManagementState.superseded,
        );
        expect(fixture.aRepository.submissions, 0);
        await expectOriginal();
      },
    );

    test(
      '${action.name} retirement during pending notification rejects repository submission',
      () async {
        final opening = bind(action);
        opening.addListener(() {
          if (opening.state == TemplateManagementState.pending) {
            fixture.switchToB();
          }
        });
        expect(
          await opening.submit(name: 'Too late'),
          TemplateManagementState.superseded,
        );
        expect(fixture.aRepository.submissions, 0);
        await expectOriginal();
      },
    );

    for (final transition in [
      'profile switch',
      'unobserved round trip',
      'database replacement',
      'repository replacement',
      'management invalidation',
      'container disposal',
    ]) {
      test(
        '${action.name} $transition permanently retires old openings before rebuild',
        () async {
          final owner = fixture.container.read(templateManagementProvider);
          final opening = bind(action);
          retire(transition);
          expect(
            await opening.submit(name: 'Obsolete'),
            TemplateManagementState.superseded,
          );
          expect(opening.isCurrent, isFalse);
          expect(opening.state, TemplateManagementState.superseded);
          expect(fixture.aRepository.submissions, 0);
          await expectOriginal();
          final retained = owner.create();
          addTearDown(retained.release);
          expect(
            await retained.submit(name: 'Stale owner'),
            TemplateManagementState.superseded,
          );
          if (!fixture.disposed) {
            final fresh = bind(action);
            expect(
              await fresh.submit(name: 'Fresh'),
              TemplateManagementState.succeeded,
            );
            expect(
              await opening.submit(name: 'Again'),
              TemplateManagementState.superseded,
            );
          }
        },
      );
    }

    for (final fails in [false, true]) {
      for (final ending in [
        'profile switch',
        'container disposal',
        'release',
      ]) {
        test(
          '${action.name} accepted ${fails ? 'failure' : 'success'} after $ending stays in captured A',
          () async {
            final opening = bind(action);
            final repository = fixture.aRepository;
            final gate = ManagementGate();
            repository.gate = gate;
            repository.fail = fails;
            final pending = opening.submit(name: 'Captured');
            await gate.entered.future;
            if (ending == 'release') {
              opening.release();
            } else {
              retire(ending);
            }
            expect(opening.isCurrent, isFalse);
            expect(opening.submit(name: 'Again'), same(pending));
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
        expect(
          await opening.submit(name: ' Corrected '),
          TemplateManagementState.succeeded,
        );
      },
    );
  }

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

  test(
    'create retains its Local profile and becomes obsolete before submission',
    () async {
      final opening = fixture.container
          .read(templateManagementProvider)
          .create();
      addTearDown(opening.release);
      fixture.switchToB();
      expect(
        await opening.submit(name: ' A only '),
        TemplateManagementState.superseded,
      );
      expect(opening.canSubmit, isFalse);
      for (final repo in [fixture.aRepository, fixture.bRepository]) {
        expect((await repo.watchTemplates().first).map((t) => t.name), [
          'Push A',
        ]);
      }
      fixture.current = fixture.a;
      fixture.container
          .read(currentProfileProvider.notifier)
          .set(localProfileName);
      expect(
        await opening.submit(name: 'Again'),
        TemplateManagementState.superseded,
      );
    },
  );
}
