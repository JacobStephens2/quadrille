import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/exercises/exercise_providers.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/domain/template_exercise_draft.dart';
import 'package:quadrille/features/templates/template_exercise_editing.dart';
import 'package:quadrille/features/templates/template_providers.dart';

import 'template_editing_fixture.dart';

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

  for (final operation in ['Add', 'Edit', 'Delete']) {
    TemplateExerciseOpening bind() {
      final owner = fixture.container.read(templateExerciseEditingProvider);
      final opening = operation == 'Delete'
          ? owner.deletion('t1', 'r1')
          : owner.edit('t1', rowId: operation == 'Edit' ? 'r1' : null);
      addTearDown(opening.release);
      return opening;
    }

    Future<TemplateExerciseEditingState> submit(
      TemplateExerciseOpening opening,
    ) => switch (opening) {
      TemplateExerciseEditorOpening() => opening.save(draft()),
      TemplateExerciseDeletionOpening() => opening.delete(),
    };

    test(
      '$operation claims pending before listeners reenter and is terminal on success',
      () async {
        final opening = bind();
        final gate = EditingWait();
        fixture.aRepository.waiting = gate;
        Future<TemplateExerciseEditingState>? reentrant;
        opening.addListener(() {
          if (opening.state == TemplateExerciseEditingState.pending) {
            reentrant = submit(opening);
          }
        });
        final first = submit(opening);
        expect(reentrant, same(first));
        await gate.entered.future;
        expect(fixture.aRepository.submissions, 1);
        gate.completion.complete();
        expect(await first, TemplateExerciseEditingState.succeeded);
        expect(await submit(opening), TemplateExerciseEditingState.succeeded);
        expect(fixture.aRepository.submissions, 1);
      },
    );

    test(
      '$operation current failure retains the opening and permits retry',
      () async {
        final opening = bind();
        fixture.aRepository.fail = true;
        expect(await submit(opening), TemplateExerciseEditingState.failed);
        expect(opening.state, TemplateExerciseEditingState.failed);
        expect(opening.canSubmit, isTrue);
        await expectOriginal();
        fixture.aRepository.fail = false;
        expect(await submit(opening), TemplateExerciseEditingState.succeeded);
        final rows = await fixture.aRepository.watchExercises('t1').first;
        expect(rows.map((e) => e.displayName), switch (operation) {
          'Add' => ['Bench Press', 'Changed'],
          'Edit' => ['Changed'],
          _ => <String>[],
        });
        expect(
          (await fixture.bRepository.watchExercises('t1').first)
              .single
              .displayName,
          'Bench Press',
        );
      },
    );

    for (final transition in [
      'profile switch',
      'unobserved round trip',
      'database replacement',
      'module invalidation',
      'repository invalidation',
      'catalog invalidation',
      'container disposal',
    ]) {
      test(
        '$operation $transition permanently retires retained openings',
        () async {
          final opening = bind();
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
            case 'module invalidation':
              fixture.container.invalidate(templateExerciseEditingProvider);
            case 'repository invalidation':
              fixture.container.invalidate(templateRepositoryProvider);
            case 'catalog invalidation':
              fixture.container.invalidate(exerciseRepositoryProvider);
            case 'container disposal':
              fixture.container.dispose();
              fixture.disposed = true;
          }
          expect(
            await submit(opening),
            TemplateExerciseEditingState.superseded,
          );
          expect(opening.isCurrent, isFalse);
          await expectOriginal();
          if (!fixture.disposed) {
            expect(
              await submit(bind()),
              TemplateExerciseEditingState.succeeded,
            );
            expect(
              await submit(opening),
              TemplateExerciseEditingState.superseded,
            );
          }
        },
      );
    }

    for (final fails in [false, true]) {
      test(
        '$operation accepted ${fails ? 'failure' : 'success'} stays in A and becomes superseded',
        () async {
          final opening = bind();
          final gate = EditingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          final pending = submit(opening);
          await gate.entered.future;
          fixture.switchToB();
          gate.completion.complete();
          expect(await pending, TemplateExerciseEditingState.superseded);
          expect(opening.state, TemplateExerciseEditingState.superseded);
          expect(
            (await fixture.bRepository.watchExercises('t1').first)
                .single
                .displayName,
            'Bench Press',
          );
          final rows = await fixture.aRepository.watchExercises('t1').first;
          expect(
            rows.map((e) => e.displayName),
            fails
                ? ['Bench Press']
                : switch (operation) {
                    'Add' => ['Bench Press', 'Changed'],
                    'Edit' => ['Changed'],
                    _ => <String>[],
                  },
          );
        },
      );

      test(
        '$operation releasing a presentation suppresses its accepted ${fails ? 'error' : 'success'}',
        () async {
          final opening = bind();
          final gate = EditingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          final pending = submit(opening);
          await gate.entered.future;
          opening.release();
          gate.completion.complete();
          expect(await pending, TemplateExerciseEditingState.superseded);
          expect(
            await submit(opening),
            TemplateExerciseEditingState.superseded,
          );
          expect(fixture.aRepository.submissions, 1);
        },
      );
    }
  }

  test('separate Add openings submit independently', () async {
    final owner = fixture.container.read(templateExerciseEditingProvider);
    final one = owner.edit('t1');
    final two = owner.edit('t1');
    addTearDown(one.release);
    addTearDown(two.release);
    final gate = EditingWait();
    fixture.aRepository.waiting = gate;
    final first = one.save(draft('One'));
    final second = two.save(draft('Two'));
    expect(second, isNot(same(first)));
    expect(fixture.aRepository.submissions, 2);
    gate.completion.complete();
    expect(await first, TemplateExerciseEditingState.succeeded);
    expect(await second, TemplateExerciseEditingState.succeeded);
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
      expect(editor.state, TemplateExerciseEditingState.superseded);
      expect(deletion.state, TemplateExerciseEditingState.superseded);
      expect(await deletion.delete(), TemplateExerciseEditingState.superseded);
      expect(
        await fixture.bRepository.watchExercises('t1').first,
        hasLength(1),
      );
    },
  );

  test(
    'one Add opening shares its first pending draft and succeeds only once',
    () async {
      final opening = fixture.container
          .read(templateExerciseEditingProvider)
          .edit('t1');
      addTearDown(opening.release);
      final gate = EditingWait();
      fixture.aRepository.waiting = gate;
      final first = opening.save(
        TemplateExerciseDraft(displayName: 'First', orderLabel: '2A'),
      );
      final second = opening.save(
        TemplateExerciseDraft(displayName: 'Ignored', orderLabel: '3'),
      );
      expect(second, same(first));
      expect(opening.state, TemplateExerciseEditingState.pending);
      await gate.entered.future;
      gate.completion.complete();
      expect(await first, TemplateExerciseEditingState.succeeded);
      expect(await second, TemplateExerciseEditingState.succeeded);
      expect(
        await opening.save(
          TemplateExerciseDraft(displayName: 'Again', orderLabel: '4'),
        ),
        TemplateExerciseEditingState.succeeded,
      );
      final rows = await fixture.aRepository.watchExercises('t1').first;
      expect(rows.map((row) => row.displayName), ['Bench Press', 'First']);
      expect(rows.last.supersetGroup, '2');
    },
  );
}
