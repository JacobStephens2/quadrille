import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/exercises/exercise_catalog_editing.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';

import 'catalog_editing_fixture.dart';

// Lifecycle scenarios (reentrancy, every retirement reason and timing,
// retry, release) live at the Retained opening seam in
// test/core/retained_opening_test.dart. These tests pin what is specific to
// Exercise catalog editing: the fixed exercise snapshot, the Add/Edit
// writes, the validation and error messages, draft normalisation, and
// destination retention across a profile switch.
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
        expect(opening.state, ExerciseCatalogEditingState.idle);
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
      '$operation failure is recoverable with an edited retry draft',
      () async {
        final opening = await bind(editing);
        fixture.aRepository.fail = true;
        expect(await opening.save(changed), ExerciseCatalogEditingState.failed);
        expect(
          opening.errorMessage,
          'Could not save this exercise. Please try again.',
        );
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

    test(
      '$operation normalizes the draft and persists all fields in its captured catalog',
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

    test(
      '$operation accepted save retains its destination across a profile switch',
      () async {
        final opening = await bind(editing);
        final gate = CatalogWait();
        fixture.aRepository.waiting = gate;
        final pending = opening.save(changed);
        await gate.entered.future;
        fixture.switchToB();
        expect(opening.isCurrent, isFalse);
        expect(opening.state, ExerciseCatalogEditingState.superseded);
        gate.completion.complete();
        expect(await pending, ExerciseCatalogEditingState.superseded);
        expect(opening.errorMessage, isNull);
        final rows = await fixture.aRepository.watchAll().first;
        expect(
          rows.map((e) => e.name),
          editing ? ['Changed'] : ['A exercise', 'Changed'],
        );
        expect(
          (await fixture.bRepository.watchAll().first).single.name,
          'B exercise',
        );
        expect(fixture.aRepository.submissions, 1);
        expect(fixture.bRepository.submissions, 0);
      },
    );
  }

  test('a blank draft does not disturb a pending or succeeded save', () async {
    final opening = await bind(false);
    final gate = CatalogWait();
    fixture.aRepository.waiting = gate;
    final first = opening.save(const ExerciseCatalogDraft(name: 'First'));
    expect(opening.save(const ExerciseCatalogDraft(name: '')), same(first));
    expect(opening.validationMessage, isNull);
    await gate.entered.future;
    gate.completion.complete();
    expect(await first, ExerciseCatalogEditingState.succeeded);
    expect(
      await opening.save(const ExerciseCatalogDraft(name: '')),
      ExerciseCatalogEditingState.succeeded,
    );
    expect(opening.validationMessage, isNull);
    expect(fixture.aRepository.submissions, 1);
    expect((await fixture.aRepository.watchAll().first).last.name, 'First');
  });

  test(
    'state reports superseded when its captured exercise repository is replaced',
    () async {
      final opening = await bind(false);
      fixture.aRepository.fail = true;
      expect(await opening.save(changed), ExerciseCatalogEditingState.failed);
      expect(opening.state, ExerciseCatalogEditingState.failed);
      expect(
        opening.errorMessage,
        'Could not save this exercise. Please try again.',
      );
      final captured = fixture.aRepository;
      fixture.aRepository = CatalogRepository(fixture.a);
      fixture.container.invalidate(exerciseRepositoryProvider);
      expect(opening.state, ExerciseCatalogEditingState.superseded);
      expect(opening.errorMessage, isNull);
      expect(opening.isCurrent, isFalse);
      expect(opening.canSubmit, isFalse);
      expect(
        await opening.save(changed),
        ExerciseCatalogEditingState.superseded,
      );
      expect(captured.submissions, 1);
      expect(fixture.aRepository.submissions, 0);
      await expectOriginal();
    },
  );

  test('distinct Add and Edit openings retain independent targets', () async {
    final owner = fixture.container.read(exerciseCatalogEditingProvider);
    final original = (await fixture.aRepository.getById('e1'))!;
    final add = owner.add();
    final edit = owner.edit(original);
    addTearDown(add.release);
    addTearDown(edit.release);
    expect(add.initialExercise, isNull);
    expect(edit.initialExercise, same(original));
    expect(
      await add.save(const ExerciseCatalogDraft(name: 'Added')),
      ExerciseCatalogEditingState.succeeded,
    );
    expect(edit.state, ExerciseCatalogEditingState.idle);
    expect(edit.canSubmit, isTrue);
    expect(edit.initialExercise, same(original));
    expect(await edit.save(changed), ExerciseCatalogEditingState.succeeded);
    expect((await fixture.aRepository.watchAll().first).map((e) => e.name), [
      'Added',
      'Changed',
    ]);
  });

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
}
