import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/domain/session_grid.dart';
import 'package:quadrille/features/session/presentation/set_entry_controller.dart';
import 'package:quadrille/features/session/session_providers.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';
import 'package:quadrille/features/settings/settings_providers.dart';

import 'set_entry_ownership_fixture.dart';

void main() {
  for (final skip in [false, true]) {
    test(
      'opening in A cannot ${skip ? 'skip' : 'log'} into matching B identifiers',
      () async {
        final f = EntryOwnershipFixture();
        await f.open();
        addTearDown(f.close);
        final opening = openEntry(f, await f.row(f.a));
        opening.controller.updateDraft(
          const SetEntryDraft(weight: '88', reps: '2'),
        );
        f.switchTo('b');
        await (skip ? opening.controller.skip() : opening.controller.log());
        expect((await f.row(f.b)).sets.first.weight, 70);
        expect((await f.row(f.b)).sets.first.status, SetStatus.pending);
        expect((await f.timer(f.b))?.label, 'Existing rest');
        expect(opening.state().submission, EntrySubmission.superseded);
        expect(opening.state().draft.weight, '88');
      },
    );
  }

  test('binding precedes construction of the entry controller', () async {
    final f = EntryOwnershipFixture();
    await f.open();
    addTearDown(f.close);
    final seed = f.seed(await f.row(f.a));
    f.switchTo('b');
    final provider = setEntryProvider(seed);
    final subscription = f.container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await f.container.read(provider.notifier).log();
    expect(f.container.read(provider).submission, EntrySubmission.superseded);
    expect((await f.row(f.b)).sets.first.weight, 70);
  });

  test(
    'A to B to A without a provider read permanently retires the opening',
    () async {
      final f = EntryOwnershipFixture();
      await f.open();
      addTearDown(f.close);
      final opening = openEntry(f, await f.row(f.a));
      f.switchTo('b');
      f.switchTo('a');
      await opening.controller.log();
      expect((await f.row(f.a)).sets.first.status, SetStatus.pending);
      expect(opening.state().submission, EntrySubmission.superseded);
      final fresh = openEntry(f, await f.row(f.a));
      await fresh.controller.log();
      expect(fresh.state().submission, EntrySubmission.success);
    },
  );

  test('same-name database replacement retires the opening', () async {
    final f = EntryOwnershipFixture();
    await f.open();
    addTearDown(f.close);
    final original = f.a;
    final opening = openEntry(f, await f.row(original));
    f.a = await f.addDatabase();
    f.container.invalidate(databaseProvider);
    await opening.controller.skip();
    expect(opening.state().submission, EntrySubmission.superseded);
    expect((await f.row(f.a)).sets.first.status, SetStatus.pending);
    expect((await f.row(original)).sets.first.status, SetStatus.pending);
  });

  for (final stage in ['persistence', 'grid']) {
    for (final fail in [false, true]) {
      if (stage == 'grid' && fail) continue;
      test(
        'switch during $stage ${fail ? 'failure' : 'success'} stops later logging stages',
        () async {
          final f = EntryOwnershipFixture();
          await f.open();
          addTearDown(f.close);
          final opening = openEntry(f, await f.row(f.a));
          opening.controller.updateDraft(
            const SetEntryDraft(weight: '88', reps: '2'),
          );
          final wait = EntryWait();
          if (stage == 'persistence') {
            f.waits.first.persistence = wait;
            f.waits.first.fail = fail;
          } else {
            f.waits.first.grid = wait;
          }
          final saving = opening.controller.log();
          await wait.entered.future;
          final bTimer = await f.timer(f.b);
          f.switchTo('b');
          await Future<void>.value();
          expect(opening.state().submission, EntrySubmission.superseded);
          wait.completion.complete();
          await saving;
          expect(opening.state().submission, EntrySubmission.superseded);
          expect(
            opening.state().saveError,
            'Local profile changed. Close this set and reopen it.',
          );
          expect(opening.state().draft.weight, '88');
          expect((await f.row(f.b)).sets.first.weight, 70);
          expect(await f.timer(f.b), bTimer);
          expect(f.notifications.requests, 0);
          expect(
            f.container.read(sessionSetControllerProvider('session')),
            isNull,
          );
          f.waits.first.grid = null;
          expect((await f.row(f.a)).sets.first.weight, fail ? 70 : 88);
        },
      );
    }
  }

  for (final stage in ['persistence', 'grid', 'alerts']) {
    test('fresh B work finishes while obsolete A $stage waits', () async {
      final f = EntryOwnershipFixture();
      await f.open();
      addTearDown(f.close);
      final opening = openEntry(f, await f.row(f.a));
      final wait = EntryWait();
      if (stage == 'persistence') {
        f.waits.first.persistence = wait;
      } else if (stage == 'grid') {
        f.waits.first.grid = wait;
      } else {
        f.notifications.scheduling = wait.completion;
      }
      final saving = opening.controller.log();
      await (stage == 'alerts'
          ? f.notifications.schedulingEntered.future
          : wait.entered.future);
      f.switchTo('b');
      expect((await f.timer(f.b))?.label, 'Existing rest');
      if (stage == 'alerts') f.notifications.scheduling = null;
      final fresh = openEntry(f, await f.row(f.b), index: 1);
      await fresh.controller.log();
      expect(fresh.state().submission, EntrySubmission.success);
      expect((await f.row(f.b)).sets.last.status, SetStatus.completed);
      final bTimer = await f.timer(f.b);
      expect(
        f.container.read(sessionSetControllerProvider('session'))?.id,
        'set-2',
      );
      wait.completion.complete();
      await saving;
      expect(opening.state().submission, EntrySubmission.superseded);
      expect(
        f.container.read(sessionSetControllerProvider('session'))?.id,
        'set-2',
      );
      expect(await f.timer(f.b), bTimer);
    });
  }

  test(
    'last-logged recommendations reset on each ownership generation',
    () async {
      final f = EntryOwnershipFixture();
      await f.open();
      addTearDown(f.close);
      final opening = openEntry(f, await f.row(f.a), index: 1);
      await opening.controller.skip();
      expect(
        f.container.read(sessionSetControllerProvider('session'))?.id,
        'set-2',
      );
      f.switchTo('b');
      final gridSubscription = f.container.listen(
        sessionGridProvider('session'),
        (_, _) {},
      );
      addTearDown(gridSubscription.close);
      await f.container.read(sessionGridProvider('session').future);
      expect(f.container.read(sessionSetControllerProvider('session')), isNull);
      expect(
        f.container.read(sessionRecommendationProvider('session'))?.set.id,
        'set-1',
      );
      final fresh = openEntry(f, await f.row(f.b));
      await fresh.controller.skip();
      f.switchTo('a');
      f.switchTo('b');
      expect(f.container.read(sessionSetControllerProvider('session')), isNull);
      final replacement = await f.addDatabase();
      f.b = replacement;
      f.container.invalidate(databaseProvider);
      expect(f.container.read(sessionSetControllerProvider('session')), isNull);
    },
  );

  test(
    'Auto-start rest policy is captured at submission rather than opening',
    () async {
      final f = EntryOwnershipFixture();
      await f.open();
      addTearDown(f.close);
      final settings = f.container.listen(settingsProvider, (_, _) {});
      addTearDown(settings.close);
      await f.container.read(settingsProvider.future);
      final opening = openEntry(f, await f.row(f.a));
      await SettingsRepository(f.a).update(autoStartTimer: false);
      f.container.invalidate(settingsProvider);
      expect(
        (await f.container.read(settingsProvider.future)).autoStartTimer,
        isFalse,
      );
      await opening.controller.log();
      expect(opening.state().submission, EntrySubmission.success);
      expect((await f.row(f.a)).sets.first.status, SetStatus.completed);
      expect((await f.timer(f.a))?.label, 'Existing rest');
      expect(f.notifications.requests, 0);
    },
  );

  testWidgets(
    'retired hold cannot auto-log or restart and preserves its draft',
    (tester) async {
      final f = EntryOwnershipFixture();
      await tester.runAsync(f.open);
      addTearDown(() => tester.runAsync(f.close));
      final row = (await tester.runAsync(() => f.row(f.a)))!;
      final opening = openEntry(f, row);
      opening.controller.updateDraft(
        const SetEntryDraft(weight: '88', reps: '2'),
      );
      opening.controller.setAutoLog(true);
      opening.controller.startHold();
      f.switchTo('b');
      f.switchTo('a');
      f.now = f.now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      opening.controller.startHold();
      opening.controller.setAutoLog(false);
      opening.controller.updateDraft(const SetEntryDraft(weight: '99'));
      await opening.controller.log();
      await opening.controller.skip();
      expect(opening.state().submission, EntrySubmission.superseded);
      expect(opening.state().isHolding, isFalse);
      expect(opening.state().draft.weight, '88');
      expect(
        (await tester.runAsync(() => f.row(f.a)))!.sets.first.status,
        SetStatus.pending,
      );
      expect(
        (await tester.runAsync(() => f.row(f.b)))!.sets.first.status,
        SetStatus.pending,
      );
      expect(f.notifications.requests, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

({SetEntryController controller, SetEntryState Function() state}) openEntry(
  EntryOwnershipFixture f,
  SessionGridRow row, {
  int index = 0,
}) {
  final provider = setEntryProvider(f.seed(row, index: index));
  final subscription = f.container.listen(provider, (_, _) {});
  addTearDown(subscription.close);
  return (
    controller: f.container.read(provider.notifier),
    state: () => f.container.read(provider),
  );
}
