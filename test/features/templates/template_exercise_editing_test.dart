import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/core/retained_opening.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/templates/template_exercise_editing.dart';
import 'package:quadrille/features/templates/template_providers.dart';

import 'template_editing_fixture.dart';

// Lifecycle scenarios (reentrancy, every retirement reason and timing,
// retry admission, masking, release) live at the Retained opening seam in
// test/core/retained_opening_test.dart. These tests pin what is specific to
// Template exercise editing: the fixed template/row targets, live catalog
// suggestions behind the retire hook, Add/update/delete persistence, and
// destination retention across a profile switch.

void main() {
  late TemplateEditingFixture fixture;
  setUp(() async {
    fixture = TemplateEditingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  TemplateExerciseDraft draft([String name = 'Changed']) =>
      TemplateExerciseDraft(displayName: name, orderLabel: '2B');

  Future<void> expectOriginal() async {
    for (final repo in [fixture.aRepository, fixture.bRepository]) {
      expect(
        (await repo.watchExercises('t1').first).map((e) => e.displayName),
        ['Bench Press'],
      );
    }
  }

  Future<void> expectBUnchanged() async {
    expect(
      (await fixture.bRepository.watchExercises('t1').first).single.displayName,
      'Bench Press',
    );
  }

  void openingSuite<O extends RetainedOpening<TemplateExerciseEditingState>>({
    required String operation,
    required List<String> expectedRows,
    required O Function(TemplateExerciseEditing owner) openOpening,
    required String Function(O opening) templateIdOf,
    required Future<TemplateExerciseEditingState> Function(O opening)
    submitOpening,
  }) {
    O bind() {
      final owner = fixture.container.read(templateExerciseEditingProvider);
      final opening = openOpening(owner);
      addTearDown(opening.release);
      return opening;
    }

    test('$operation persists its fixed target through A only', () async {
      final opening = bind();
      expect(templateIdOf(opening), 't1');
      expect(opening.state, TemplateExerciseEditingState.idle);
      expect(opening.canSubmit, isTrue);
      expect(
        await submitOpening(opening),
        TemplateExerciseEditingState.succeeded,
      );
      expect(opening.state, TemplateExerciseEditingState.succeeded);
      expect(fixture.aRepository.submissions, 1);
      expect(fixture.bRepository.submissions, 0);
      final rows = await fixture.aRepository.watchExercises('t1').first;
      expect(rows.map((e) => e.displayName), expectedRows);
      await expectBUnchanged();
    });

    test(
      '$operation current failure retains the opening and permits retry',
      () async {
        final opening = bind();
        fixture.aRepository.fail = true;
        expect(
          await submitOpening(opening),
          TemplateExerciseEditingState.failed,
        );
        expect(opening.state, TemplateExerciseEditingState.failed);
        expect(opening.canSubmit, isTrue);
        await expectOriginal();
        fixture.aRepository.fail = false;
        expect(
          await submitOpening(opening),
          TemplateExerciseEditingState.succeeded,
        );
        final rows = await fixture.aRepository.watchExercises('t1').first;
        expect(rows.map((e) => e.displayName), expectedRows);
        await expectBUnchanged();
      },
    );

    test(
      '$operation accepted write retains its destination across a profile switch',
      () async {
        final opening = bind();
        final gate = EditingWait();
        fixture.aRepository.waiting = gate;
        final pending = submitOpening(opening);
        await gate.entered.future;
        fixture.switchToB();
        expect(opening.isCurrent, isFalse);
        expect(opening.state, TemplateExerciseEditingState.superseded);
        gate.completion.complete();
        expect(await pending, TemplateExerciseEditingState.superseded);
        expect(fixture.aRepository.submissions, 1);
        expect(fixture.bRepository.submissions, 0);
        await expectBUnchanged();
        final rows = await fixture.aRepository.watchExercises('t1').first;
        expect(rows.map((e) => e.displayName), expectedRows);
      },
    );
  }

  openingSuite<TemplateExerciseEditorOpening>(
    operation: 'Add',
    expectedRows: ['Bench Press', 'Changed'],
    openOpening: (owner) => owner.edit('t1'),
    templateIdOf: (opening) => opening.templateId,
    submitOpening: (opening) => opening.save(draft()),
  );
  openingSuite<TemplateExerciseEditorOpening>(
    operation: 'Edit',
    expectedRows: ['Changed'],
    openOpening: (owner) => owner.edit('t1', rowId: 'r1'),
    templateIdOf: (opening) => opening.templateId,
    submitOpening: (opening) => opening.save(draft()),
  );
  openingSuite<TemplateExerciseDeletionOpening>(
    operation: 'Delete',
    expectedRows: <String>[],
    openOpening: (owner) => owner.deletion('t1', 'r1'),
    templateIdOf: (opening) => opening.templateId,
    submitOpening: (opening) => opening.delete(),
  );

  test('separate Add openings persist independently', () async {
    final owner = fixture.container.read(templateExerciseEditingProvider);
    final one = owner.edit('t1');
    final two = owner.edit('t1');
    addTearDown(one.release);
    addTearDown(two.release);
    expect(one.templateId, 't1');
    expect(two.templateId, 't1');
    expect(
      await one.save(draft('One')),
      TemplateExerciseEditingState.succeeded,
    );
    expect(two.state, TemplateExerciseEditingState.idle);
    expect(two.canSubmit, isTrue);
    expect(
      await two.save(draft('Two')),
      TemplateExerciseEditingState.succeeded,
    );
    expect(fixture.aRepository.submissions, 2);
    expect(
      (await fixture.aRepository.watchExercises('t1').first).map(
        (e) => e.displayName,
      ),
      unorderedEquals(['Bench Press', 'One', 'Two']),
    );
  });

  Future<void> catalogReady(TemplateExerciseEditorOpening opening) async {
    if (opening.suggestions.isNotEmpty) return;
    final ready = Completer<void>();
    void listener() {
      if (opening.suggestions.isNotEmpty && !ready.isCompleted) {
        ready.complete();
      }
    }

    opening.addListener(listener);
    await ready.future.timeout(const Duration(seconds: 5));
    opening.removeListener(listener);
  }

  test('lone catalog replacement retires the editor opening', () async {
    final opening = fixture.container
        .read(templateExerciseEditingProvider)
        .edit('t1');
    addTearDown(opening.release);
    await catalogReady(opening);
    expect(opening.suggestions.map((e) => e.name), ['A catalog']);
    fixture.container.invalidate(exerciseRepositoryProvider);
    expect(opening.isCurrent, isFalse);
    expect(opening.state, TemplateExerciseEditingState.superseded);
    expect(opening.suggestions, isEmpty);
    expect(
      await opening.save(draft()),
      TemplateExerciseEditingState.superseded,
    );
    await expectOriginal();
  });

  test(
    'lone template-repository replacement retires the deletion opening',
    () async {
      final opening = fixture.container
          .read(templateExerciseEditingProvider)
          .deletion('t1', 'r1');
      addTearDown(opening.release);
      fixture.container.invalidate(templateRepositoryProvider);
      expect(opening.isCurrent, isFalse);
      expect(opening.state, TemplateExerciseEditingState.superseded);
      expect(await opening.delete(), TemplateExerciseEditingState.superseded);
      await expectOriginal();
    },
  );

  test(
    'catalog suggestions stay in the captured opening and disappear on retirement',
    () async {
      final old = fixture.container
          .read(templateExerciseEditingProvider)
          .edit('t1');
      addTearDown(old.release);
      await catalogReady(old);
      expect(old.suggestions.map((e) => e.name), ['A catalog']);
      fixture.switchToB();
      expect(old.suggestions, isEmpty);
      final fresh = fixture.container
          .read(templateExerciseEditingProvider)
          .edit('t1');
      addTearDown(fresh.release);
      await catalogReady(fresh);
      expect(fresh.suggestions.map((e) => e.name), ['B catalog']);
      expect(old.suggestions, isEmpty);
    },
  );

  test(
    'archived templates remain editable and missing or tombstoned rows retain repository semantics',
    () async {
      final owner = fixture.container.read(templateExerciseEditingProvider);
      await fixture.aRepository.archiveTemplate('t1');
      final editor = owner.edit('t1', rowId: 'r1');
      final missingEditor = owner.edit('t1', rowId: 'missing');
      final missingDeletion = owner.deletion('t1', 'missing');
      for (final opening in [editor, missingEditor, missingDeletion]) {
        addTearDown(opening.release);
      }
      expect(
        await editor.save(draft()),
        TemplateExerciseEditingState.succeeded,
      );
      expect(
        (await fixture.aRepository.watchExercises('t1').first)
            .single
            .displayName,
        'Changed',
      );
      expect(
        await missingEditor.save(draft()),
        TemplateExerciseEditingState.succeeded,
      );
      expect(
        await missingDeletion.delete(),
        TemplateExerciseEditingState.succeeded,
      );
      await fixture.aRepository.deleteExercise('r1');
      final tombstoned = owner.edit('t1', rowId: 'r1');
      addTearDown(tombstoned.release);
      expect(
        await tombstoned.save(draft()),
        TemplateExerciseEditingState.succeeded,
      );
      expect(
        await TemplateRepository(fixture.a).watchExercises('t1').first,
        isEmpty,
      );
    },
  );

  test(
    'a retained rendered owner creates only superseded openings after retirement',
    () async {
      final owner = fixture.container.read(templateExerciseEditingProvider);
      fixture.switchToB();
      final editor = owner.edit('t1', rowId: 'r1');
      final deletion = owner.deletion('t1', 'r1');
      addTearDown(editor.release);
      addTearDown(deletion.release);
      expect(editor.templateId, 't1');
      expect(deletion.templateId, 't1');
      expect(editor.state, TemplateExerciseEditingState.superseded);
      expect(deletion.state, TemplateExerciseEditingState.superseded);
      expect(editor.suggestions, isEmpty);
      expect(
        await editor.save(draft()),
        TemplateExerciseEditingState.superseded,
      );
      expect(await deletion.delete(), TemplateExerciseEditingState.superseded);
      expect(
        await fixture.bRepository.watchExercises('t1').first,
        hasLength(1),
      );
    },
  );

  test(
    'catalog subscription is freed on retire and on release and ignores late emissions and errors',
    () async {
      for (final retire in [true, false]) {
        final catalog = ControlledCatalog(fixture.a);
        addTearDown(catalog.controller.close);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith((ref) {
              ref.watch(currentProfileProvider);
              return fixture.current;
            }),
            templateRepositoryProvider.overrideWith(
              (ref) => fixture.aRepository,
            ),
            exerciseRepositoryProvider.overrideWith((ref) => catalog),
          ],
        );
        addTearDown(container.dispose);
        final opening = container
            .read(templateExerciseEditingProvider)
            .edit('t1');
        expect(catalog.controller.hasListener, isTrue);
        catalog.controller.add([catalogExercise('Live')]);
        await Future<void>.delayed(Duration.zero);
        expect(opening.suggestions.map((e) => e.name), ['Live']);
        catalog.controller.addError(StateError('Catalog failed'));
        await Future<void>.delayed(Duration.zero);
        expect(opening.suggestions.map((e) => e.name), ['Live']);
        expect(opening.canSubmit, isTrue);
        if (retire) {
          container.invalidate(templateExerciseEditingProvider);
        } else {
          opening.release();
        }
        await Future<void>.delayed(Duration.zero);
        expect(catalog.controller.hasListener, isFalse);
        expect(opening.suggestions, isEmpty);
        catalog.controller.add([catalogExercise('Late')]);
        catalog.controller.addError(StateError('Late failure'));
        await Future<void>.delayed(Duration.zero);
        expect(opening.suggestions, isEmpty);
        opening.release();
        await Future<void>.delayed(Duration.zero);
        expect(() => opening.addListener(() {}), throwsFlutterError);
      }
    },
  );
}

Exercise catalogExercise(String name) => Exercise(
  id: name,
  name: name,
  category: ExerciseCategory.other,
  defaultRestSeconds: 120,
  loadKind: LoadKind.externalWeight,
  isUnilateral: false,
  archived: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class ControlledCatalog extends ExerciseRepository {
  ControlledCatalog(super.db);

  final controller = StreamController<List<Exercise>>.broadcast();

  @override
  Stream<List<Exercise>> watchAll() => controller.stream;
}
