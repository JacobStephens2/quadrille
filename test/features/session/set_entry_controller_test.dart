import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/domain/rep_target.dart';
import 'package:quadrille/features/session/presentation/set_entry_controller.dart';
import 'package:quadrille/features/session/session_providers.dart';

import 'set_entry_fixture.dart';

void main() {
  for (final (kind, target, durationBased, initial) in [
    (LoadKind.bodyweight, RepTarget.duration(20, 30), true, '20'),
    (LoadKind.timeOnly, RepTarget.none, true, ''),
    (
      LoadKind.externalWeight,
      const RepTarget(repMin: 8, durationMin: Duration(seconds: 20)),
      false,
      '',
    ),
  ]) {
    testWidgets(
      '$kind with $target preserves duration classification and initial values',
      (tester) async {
        final f = await EntryFixture.create(
          tester,
          loadKind: kind,
          target: target,
          unilateral: true,
        );
        final provider = setEntryProvider(f.seed());
        final subscription = f.container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        final entry = f.container.read(provider.notifier);
        expect(f.container.read(provider).draft.reps, initial);
        entry.updateDraft(f.container.read(provider).draft.copyWith(reps: '2'));
        entry.startHold();
        expect(f.container.read(provider).isHolding, durationBased);
        expect(f.sessions.writes, isEmpty);
        entry.stopHold();
      },
    );
  }

  testWidgets(
    'draft restores persisted values and carries earlier weight and seconds',
    (tester) async {
      final f = await EntryFixture.create(tester);
      await tester.runAsync(
        () => f.sessions.saveSet(
          f.row.sets.first.id,
          weight: 30.5,
          reps: 23,
          rpe: 8,
          partials: 4,
          notes: 'stored',
        ),
      );
      final row = (await tester.runAsync(
        () => f.sessions.readGrid(f.row.exercise.sessionId),
      ))!.single;
      final first = setEntryProvider(
        SetEntrySeed(row: row, set: row.sets.first),
      );
      final second = setEntryProvider(
        SetEntrySeed(row: row, set: row.sets.last),
      );
      final a = f.container.listen(first, (_, _) {});
      final b = f.container.listen(second, (_, _) {});
      addTearDown(a.close);
      addTearDown(b.close);
      final persisted = f.container.read(first).draft;
      expect(persisted.weight, '30.5');
      expect(persisted.reps, '23');
      expect(persisted.rpe, 8);
      expect(persisted.partials, 4);
      expect(persisted.notes, 'stored');
      expect(f.container.read(second).draft.weight, '30.5');
      expect(f.container.read(second).draft.reps, '23');
      expect(f.container.read(second).draft.rpe, isNull);
      expect(f.container.read(second).draft.partials, isNull);
      expect(f.sessions.writes, hasLength(1));
    },
  );

  testWidgets(
    'delayed expiry logs the latest draft once and holds the post-set guard',
    (tester) async {
      final haptics = recordHaptics(tester);
      final f = await EntryFixture.create(tester);
      final provider = setEntryProvider(f.seed());
      final subscription = f.container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final entry = f.container.read(provider.notifier);
      entry.startHold();
      entry.updateDraft(
        f.container
            .read(provider)
            .draft
            .copyWith(
              weight: '50',
              reps: '99',
              rpe: 8,
              partials: 4,
              notes: '  steady  ',
            ),
      );
      expect(f.container.read(provider).draft.reps, '2');
      entry.setAutoLog(true);
      f.notifications.permission = Completer<bool>();
      f.now = f.now.add(const Duration(milliseconds: 1250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(f.container.read(provider).remainingSeconds, 1);
      f.now = f.now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(milliseconds: 250));
      await f.flush(tester);
      expect(f.container.read(provider).submission, EntrySubmission.pending);
      expect(f.notifications.requests, 1);
      final saved = await f.saved(tester);
      expect(saved.weight, 50);
      expect(saved.reps, 2);
      expect(saved.rpe, 8);
      expect(saved.partials, 4);
      expect(saved.notes, 'steady');
      await entry.skip();
      await entry.log();
      await tester.pump(const Duration(seconds: 10));
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      expect(f.sessions.writes, [SetStatus.completed]);
      f.notifications.permission!.complete(true);
      await f.flush(tester);
      expect(f.container.read(provider).submission, EntrySubmission.success);
      expect(f.notifications.bodies, hasLength(1));
      expect(f.watch.snapshots, hasLength(1));
    },
  );

  for (final status in [SetStatus.completed, SetStatus.skipped]) {
    testWidgets('manual $status cancels expiry before delayed persistence', (
      tester,
    ) async {
      final f = await EntryFixture.create(tester);
      final provider = setEntryProvider(f.seed());
      final subscription = f.container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final entry = f.container.read(provider.notifier);
      entry.setAutoLog(true);
      entry.startHold();
      f.sessions.persistence = Completer<void>();
      final saving = status == SetStatus.completed ? entry.log() : entry.skip();
      expect(f.container.read(provider).isHolding, isFalse);
      f.now = f.now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      await entry.log();
      await entry.skip();
      expect(f.sessions.writes, [status]);
      expect((await f.saved(tester)).status, SetStatus.pending);
      f.sessions.persistence!.complete();
      await f.finish(tester, saving);
      expect((await f.saved(tester)).status, status);
      expect(
        f.notifications.bodies,
        hasLength(status == SetStatus.completed ? 1 : 0),
      );
      expect(
        f.container
            .read(sessionSetControllerProvider(f.row.exercise.sessionId))
            ?.id,
        f.row.sets.first.id,
      );
    });
  }

  testWidgets('invalid seconds, stopping, and auto-log off never submit', (
    tester,
  ) async {
    final haptics = recordHaptics(tester);
    final f = await EntryFixture.create(tester);
    final provider = setEntryProvider(f.seed());
    final subscription = f.container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final entry = f.container.read(provider.notifier);
    expect(f.sessions.writes, isEmpty);
    expect(f.container.read(provider).autoLog, isFalse);
    for (final seconds in ['', '0', '-2', '1.5', 'bad']) {
      entry.updateDraft(
        f.container.read(provider).draft.copyWith(reps: seconds),
      );
      entry.startHold();
      expect(
        f.container.read(provider).secondsError,
        'Enter seconds greater than zero',
      );
      expect(f.container.read(provider).isHolding, isFalse);
    }
    entry.updateDraft(f.container.read(provider).draft.copyWith(reps: '2'));
    expect(f.container.read(provider).secondsError, isNull);
    entry.setAutoLog(true);
    entry.startHold();
    entry.stopHold();
    f.now = f.now.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(haptics, isEmpty);
    entry.startHold();
    entry.setAutoLog(false);
    // A backward clock jump must not show more than the entered duration.
    f.now = f.now.subtract(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(f.container.read(provider).remainingSeconds, 2);
    f.now = f.now.add(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 10));
    expect(f.container.read(provider).remainingSeconds, 0);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);
    expect(f.sessions.writes, isEmpty);
    expect((await f.saved(tester)).status, SetStatus.pending);
    entry.updateDraft(f.container.read(provider).draft.copyWith(reps: '3'));
    expect(f.container.read(provider).remainingSeconds, isNull);
  });

  for (final automatic in [false, true]) {
    for (final postSet in [false, true]) {
      testWidgets(
        '${automatic ? 'automatic' : 'manual'} ${postSet ? 'post-set' : 'persistence'} failure is retryable without auto retry',
        (tester) async {
          final f = await EntryFixture.create(tester);
          final provider = setEntryProvider(f.seed());
          final subscription = f.container.listen(provider, (_, _) {});
          addTearDown(subscription.close);
          final entry = f.container.read(provider.notifier);
          entry.updateDraft(
            f.container.read(provider).draft.copyWith(notes: ' retained '),
          );
          if (postSet) {
            f.notifications.failure = StateError('notification failed');
          } else {
            f.sessions.failure = StateError('write failed');
          }
          if (automatic) {
            entry.setAutoLog(true);
            entry.startHold();
            f.now = f.now.add(const Duration(seconds: 2));
            await tester.pump(const Duration(milliseconds: 250));
            await f.flush(tester);
          } else {
            await f.finish(tester, entry.log());
          }
          expect(
            f.container.read(provider).submission,
            EntrySubmission.failure,
          );
          expect(f.container.read(provider).saveError, isNotEmpty);
          expect(f.container.read(provider).draft.notes, ' retained ');
          expect(
            (await f.saved(tester)).status,
            postSet ? SetStatus.completed : SetStatus.pending,
          );
          await tester.pump(const Duration(seconds: 30));
          expect(f.sessions.writes, [SetStatus.completed]);
          expect(tester.takeException(), isNull);
          f.notifications.failure = null;
          f.sessions.failure = null;
          await f.finish(tester, entry.log());
          expect(
            f.container.read(provider).submission,
            EntrySubmission.success,
          );
          expect(f.container.read(provider).saveError, isNull);
          expect(f.sessions.writes, [SetStatus.completed, SetStatus.completed]);
        },
      );
    }
  }

  for (final postSet in [false, true]) {
    testWidgets(
      'disposal during ${postSet ? 'post-set work' : 'persistence'} lets the accepted save finish without entry updates',
      (tester) async {
        final f = await EntryFixture.create(tester);
        final provider = setEntryProvider(f.seed());
        final outcomes = <EntrySubmission>[];
        final subscription = f.container.listen(
          provider,
          (_, next) => outcomes.add(next.submission),
        );
        final entry = f.container.read(provider.notifier);
        if (postSet) {
          f.notifications.permission = Completer<bool>();
        } else {
          f.sessions.persistence = Completer<void>();
        }
        final saving = entry.log();
        if (postSet) {
          await f.flush(tester);
          expect(f.notifications.requests, 1);
        }
        subscription.close();
        await tester.pump(Duration.zero);
        expect(f.container.exists(provider), isFalse);
        final before = List<EntrySubmission>.of(outcomes);
        f.sessions.persistence?.complete();
        f.notifications.permission?.complete(true);
        await f.finish(tester, saving);
        expect(outcomes, before);
        expect((await f.saved(tester)).status, SetStatus.completed);
        expect(f.notifications.bodies, hasLength(1));
        expect(f.watch.snapshots, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'closing cancels a hold and reopening has fresh persisted defaults',
    (tester) async {
      final f = await EntryFixture.create(tester);
      final seed = f.seed();
      final provider = setEntryProvider(seed);
      final subscription = f.container.listen(provider, (_, _) {});
      final entry = f.container.read(provider.notifier);
      entry.updateDraft(
        f.container
            .read(provider)
            .draft
            .copyWith(weight: '99', notes: 'unsaved'),
      );
      entry.setAutoLog(true);
      entry.startHold();
      subscription.close();
      await tester.pump(Duration.zero);
      expect(f.container.exists(provider), isFalse);
      f.now = f.now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 20));
      expect(f.sessions.writes, isEmpty);
      final reopened = setEntryProvider(f.seed());
      final reopenedSubscription = f.container.listen(reopened, (_, _) {});
      addTearDown(reopenedSubscription.close);
      final fresh = f.container.read(reopened);
      expect(fresh.draft.weight, '');
      expect(fresh.draft.notes, '');
      expect(fresh.draft.reps, '2');
      expect(fresh.autoLog, isFalse);
      expect(fresh.remainingSeconds, isNull);
      expect(fresh.submission, EntrySubmission.idle);
      final controller = f.container.read(reopened.notifier);
      controller.updateDraft(fresh.draft.copyWith(reps: '7', weight: '10'));
      await f.finish(tester, controller.log());
      final current = (await tester.runAsync(
        () => f.sessions.readGrid(f.row.exercise.sessionId),
      ))!.single;
      // A new seed for the same set can coexist with the terminal old entry.
      final persisted = setEntryProvider(f.seed(current));
      final persistedSubscription = f.container.listen(persisted, (_, _) {});
      addTearDown(persistedSubscription.close);
      expect(f.container.read(persisted).draft.reps, '7');
      expect(f.container.read(persisted).draft.weight, '10');
      expect(f.container.read(persisted).autoLog, isFalse);
      expect(f.container.read(persisted).submission, EntrySubmission.idle);
    },
  );

  testWidgets(
    'unilateral raw inputs retain parsing and blank-note normalization',
    (tester) async {
      final f = await EntryFixture.create(
        tester,
        timed: false,
        unilateral: true,
      );
      final provider = setEntryProvider(f.seed());
      final subscription = f.container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final entry = f.container.read(provider.notifier);
      entry.startHold();
      expect(f.container.read(provider).isHolding, isFalse);
      entry.updateDraft(
        const SetEntryDraft(
          weight: 'invalid',
          reps: '',
          leftReps: ' 8 ',
          rightReps: '9',
          notes: ' \n ',
          rpe: 9,
          partials: 3,
        ),
      );
      f.sessions.persistence = Completer<void>();
      final saving = entry.log();
      entry.updateDraft(
        const SetEntryDraft(
          weight: '60',
          leftReps: '1',
          rightReps: '2',
          rpe: 7,
          partials: 5,
          notes: 'later',
        ),
      );
      f.sessions.persistence!.complete();
      await f.finish(tester, saving);
      final saved = await f.saved(tester);
      expect(saved.weight, isNull);
      expect(saved.reps, isNull);
      expect(saved.leftReps, 8);
      expect(saved.rightReps, 9);
      expect(saved.rpe, 9);
      expect(saved.partials, 3);
      expect(saved.notes, isNull);
    },
  );

  testWidgets(
    'rep submission captures inputs and rejects duplicates until closed',
    (tester) async {
      final f = await EntryFixture.create(tester, timed: false);
      final provider = setEntryProvider(f.seed());
      final subscription = f.container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final entry = f.container.read(provider.notifier);
      entry.updateDraft(
        f.container.read(provider).draft.copyWith(weight: ' 30.5 ', reps: '12'),
      );
      f.sessions.persistence = Completer<void>();
      final saving = entry.log();
      expect(f.container.read(provider).submission, EntrySubmission.pending);
      expect(f.sessions.writes, [SetStatus.completed]);
      entry.updateDraft(
        f.container.read(provider).draft.copyWith(weight: '90', reps: '3'),
      );
      await entry.skip();
      await entry.log();
      expect(f.container.read(provider).submission, EntrySubmission.pending);
      f.sessions.persistence!.complete();
      await f.finish(tester, saving);
      expect(f.container.read(provider).submission, EntrySubmission.success);
      final saved = await f.saved(tester);
      expect(saved.weight, 30.5);
      expect(saved.reps, 12);
      expect(f.notifications.bodies, ['Next: 1 · Exercise (Set 2)']);
      expect(f.watch.snapshots, hasLength(1));
      await entry.skip();
      await entry.log();
      expect(f.sessions.writes, [SetStatus.completed]);
    },
  );
}
