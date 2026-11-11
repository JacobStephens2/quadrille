import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/exercises/exercise_catalog_editing.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';

import 'catalog_editing_fixture.dart';

void main() {
  late CatalogEditingFixture fixture;
  setUp(() async {
    fixture = CatalogEditingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  const changed = ExerciseCatalogDraft(name: 'Changed');

  Future<ExerciseCatalogOpening> bind(bool editing) async {
    final owner = fixture.container.read(exerciseCatalogEditingProvider);
    final opening = editing
        ? owner.edit((await fixture.aRepository.getById('e1'))!)
        : owner.add();
    addTearDown(opening.release);
    return opening;
  }

  Future<void> expectOriginal() async {
    expect(
      (await fixture.aRepository.watchAll().first).single.name,
      'A exercise',
    );
    expect(
      (await fixture.bRepository.watchAll().first).single.name,
      'B exercise',
    );
  }

  void retire(String cause, ExerciseCatalogOpening opening) {
    switch (cause) {
      case 'profile transition':
        fixture.switchToB();
      case 'unobserved round trip':
        fixture.switchToB();
        fixture.current = fixture.a;
        fixture.container
            .read(currentProfileProvider.notifier)
            .set(localProfileName);
      case 'exact database replacement':
        fixture.current = fixture.b;
        fixture.container.invalidate(databaseProvider);
      case 'repository replacement':
        fixture.aRepository = CatalogRepository(fixture.a);
        fixture.container.invalidate(exerciseRepositoryProvider);
      case 'editing invalidation':
        fixture.container.invalidate(exerciseCatalogEditingProvider);
      case 'container disposal':
        fixture.container.dispose();
        fixture.disposed = true;
      case 'release':
        opening.release();
    }
  }

  for (final editing in [false, true]) {
    final operation = editing ? 'Edit' : 'Add';

    test(
      '$operation rejects blank names without writes and allows correction',
      () async {
        final opening = await bind(editing);
        expect(
          await opening.save(const ExerciseCatalogDraft(name: ' \n ')),
          ExerciseCatalogEditingState.idle,
        );
        expect(opening.validationMessage, 'Required');
        expect(opening.canSubmit, isTrue);
        await expectOriginal();
        expect(
          await opening.save(changed),
          ExerciseCatalogEditingState.succeeded,
        );
        expect(opening.validationMessage, isNull);
      },
    );

    test(
      '$operation claims pending before reentry and freezes the first input',
      () async {
        final opening = await bind(editing);
        final gate = CatalogWait();
        fixture.aRepository.waiting = gate;
        Future<ExerciseCatalogEditingState>? reentrant;
        opening.addListener(() {
          if (opening.state == ExerciseCatalogEditingState.pending) {
            reentrant = opening.save(
              const ExerciseCatalogDraft(
                name: 'Ignored',
                defaultRestSeconds: 5,
              ),
            );
          }
        });
        final first = opening.save(
          const ExerciseCatalogDraft(name: 'First', defaultRestSeconds: 90),
        );
        expect(reentrant, same(first));
        expect(opening.save(const ExerciseCatalogDraft(name: '')), same(first));
        await gate.entered.future;
        expect(opening.canSubmit, isFalse);
        gate.completion.complete();
        expect(await first, ExerciseCatalogEditingState.succeeded);
        expect(
          await opening.save(changed),
          ExerciseCatalogEditingState.succeeded,
        );
        final rows = await fixture.aRepository.watchAll().first;
        expect(
          rows.map((e) => e.name),
          editing ? ['First'] : ['A exercise', 'First'],
        );
        expect(rows.last.defaultRestSeconds, 90);
        expect(fixture.aRepository.submissions, 1);
        expect(opening.canSubmit, isFalse);
      },
    );

    test(
      '$operation failure is recoverable with an edited retry draft',
      () async {
        final opening = await bind(editing);
        fixture.aRepository.fail = true;
        expect(await opening.save(changed), ExerciseCatalogEditingState.failed);
        expect(opening.errorMessage, isNotNull);
        expect(opening.canSubmit, isTrue);
        await expectOriginal();
        fixture.aRepository.fail = false;
        expect(
          await opening.save(const ExerciseCatalogDraft(name: 'Retried')),
          ExerciseCatalogEditingState.succeeded,
        );
        expect(opening.errorMessage, isNull);
        expect(
          (await fixture.aRepository.watchAll().first).last.name,
          'Retried',
        );
      },
    );

    for (final cause in [
      'profile transition',
      'unobserved round trip',
      'exact database replacement',
      'repository replacement',
      'editing invalidation',
      'container disposal',
      'release',
    ]) {
      test(
        '$operation $cause permanently rejects submission with no writes',
        () async {
          final opening = await bind(editing);
          retire(cause, opening);
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(
            await opening.save(changed),
            ExerciseCatalogEditingState.superseded,
          );
          expect(opening.state, ExerciseCatalogEditingState.superseded);
          await expectOriginal();
          opening.release();
          opening.release();
          if (!fixture.disposed) {
            final fresh = fixture.container
                .read(exerciseCatalogEditingProvider)
                .add();
            addTearDown(fresh.release);
            expect(
              await fresh.save(changed),
              ExerciseCatalogEditingState.succeeded,
            );
            expect(
              await opening.save(changed),
              ExerciseCatalogEditingState.superseded,
            );
          }
        },
      );
    }

    for (final cause in [
      'profile transition',
      'release',
      'container disposal',
    ]) {
      for (final fails in [false, true]) {
        test(
          '$operation accepted ${fails ? 'failure' : 'success'} after $cause stays captured and silent',
          () async {
            final opening = await bind(editing);
            final gate = CatalogWait();
            final repository = fixture.aRepository;
            repository.waiting = gate;
            repository.fail = fails;
            final pending = opening.save(changed);
            await gate.entered.future;
            retire(cause, opening);
            expect(
              await opening.save(changed),
              ExerciseCatalogEditingState.superseded,
            );
            gate.completion.complete();
            expect(await pending, ExerciseCatalogEditingState.superseded);
            expect(opening.errorMessage, isNull);
            final rows = await ExerciseRepository(fixture.a).watchAll().first;
            expect(
              rows.map((e) => e.name),
              fails
                  ? ['A exercise']
                  : editing
                  ? ['Changed']
                  : ['A exercise', 'Changed'],
            );
            expect(
              (await fixture.bRepository.watchAll().first).single.name,
              'B exercise',
            );
          },
        );
      }
    }

    test(
      '$operation reentrant retirement rejects admission before persistence',
      () async {
        final opening = await bind(editing);
        opening.addListener(() {
          if (opening.state == ExerciseCatalogEditingState.pending) {
            fixture.switchToB();
          }
        });
        expect(
          await opening.save(changed),
          ExerciseCatalogEditingState.superseded,
        );
        expect(fixture.aRepository.submissions, 0);
        expect(fixture.bRepository.submissions, 0);
        await expectOriginal();
      },
    );
  }

  test(
    'fresh owner saves independently while retired accepted work remains pending',
    () async {
      final old = await bind(false);
      final gate = CatalogWait();
      fixture.aRepository.waiting = gate;
      final pending = old.save(
        const ExerciseCatalogDraft(name: 'Old accepted'),
      );
      await gate.entered.future;
      fixture.switchToB();
      final fresh = fixture.container
          .read(exerciseCatalogEditingProvider)
          .edit((await fixture.bRepository.getById('e1'))!);
      addTearDown(fresh.release);
      expect(await fresh.save(changed), ExerciseCatalogEditingState.succeeded);
      expect(
        (await fixture.bRepository.watchAll().first).single.name,
        'Changed',
      );
      gate.completion.complete();
      expect(await pending, ExerciseCatalogEditingState.superseded);
      expect((await fixture.aRepository.watchAll().first).map((e) => e.name), [
        'A exercise',
        'Old accepted',
      ]);
    },
  );

  test(
    'separate Add and Edit openings do not serialize or deduplicate',
    () async {
      final addOne = await bind(false);
      final addTwo = await bind(false);
      final edit = await bind(true);
      final gate = CatalogWait();
      fixture.aRepository.waiting = gate;
      final one = addOne.save(const ExerciseCatalogDraft(name: 'One'));
      final two = addTwo.save(const ExerciseCatalogDraft(name: 'Two'));
      final three = edit.save(changed);
      await gate.entered.future;
      expect(fixture.aRepository.submissions, 3);
      gate.completion.complete();
      expect(
        await Future.wait([one, two, three]),
        everyElement(ExerciseCatalogEditingState.succeeded),
      );
      expect((await fixture.aRepository.watchAll().first).map((e) => e.name), [
        'Changed',
        'One',
        'Two',
      ]);
    },
  );

  test(
    'retained rendering owner never creates a current opening after retirement',
    () async {
      final owner = fixture.container.read(exerciseCatalogEditingProvider);
      final original = (await fixture.aRepository.getById('e1'))!;
      fixture.switchToB();
      for (final opening in [owner.add(), owner.edit(original)]) {
        addTearDown(opening.release);
        if (opening.initialExercise != null) {
          expect(opening.initialExercise, same(original));
        }
        expect(
          await opening.save(changed),
          ExerciseCatalogEditingState.superseded,
        );
      }
      await expectOriginal();
    },
  );

  test(
    'Edit retains its original snapshot and repository policies for notes and targets',
    () async {
      final owner = fixture.container.read(exerciseCatalogEditingProvider);
      final original = (await fixture.aRepository.getById('e1'))!;
      final edit = owner.edit(original);
      addTearDown(edit.release);
      await fixture.aRepository.archive('e1');
      expect(edit.initialExercise, same(original));
      expect(
        await edit.save(
          const ExerciseCatalogDraft(name: 'Archived', notes: '  '),
        ),
        ExerciseCatalogEditingState.succeeded,
      );
      final saved = (await fixture.aRepository.getById('e1'))!;
      expect(saved.archived, isTrue);
      expect(saved.notes, 'Original notes');
      await fixture.a
          .update(fixture.a.exercises)
          .write(ExercisesCompanion(deletedAt: Value(DateTime(2026))));
      final tombstoned = owner.edit(saved);
      final missing = owner.edit(saved.copyWith(id: 'missing'));
      addTearDown(tombstoned.release);
      addTearDown(missing.release);
      expect(
        await tombstoned.save(changed),
        ExerciseCatalogEditingState.succeeded,
      );
      expect(
        await missing.save(changed),
        ExerciseCatalogEditingState.succeeded,
      );
      final retained = (await fixture.aRepository.getById('e1'))!;
      expect(retained.name, 'Changed');
      expect(retained.deletedAt, DateTime(2026));
      expect(await fixture.aRepository.getById('missing'), isNull);
    },
  );

  for (final editing in [false, true]) {
    test(
      '${editing ? 'Edit' : 'Add'} normalizes the draft and persists all fields in its captured catalog',
      () async {
        final opening = await bind(editing);
        expect(
          await opening.save(
            const ExerciseCatalogDraft(
              name: '  Row  ',
              category: ExerciseCategory.pull,
              defaultRestSeconds: 90,
              loadKind: LoadKind.bodyweight,
              isUnilateral: true,
              notes: '  controlled  ',
            ),
          ),
          ExerciseCatalogEditingState.succeeded,
        );
        final rows = await fixture.aRepository.watchAll().first;
        final saved = rows.last;
        expect(saved.name, 'Row');
        expect(saved.category, ExerciseCategory.pull);
        expect(saved.defaultRestSeconds, 90);
        expect(saved.loadKind, LoadKind.bodyweight);
        expect(saved.isUnilateral, isTrue);
        expect(saved.notes, 'controlled');
        expect(
          (await fixture.bRepository.watchAll().first).single.name,
          'B exercise',
        );
      },
    );
  }
}
