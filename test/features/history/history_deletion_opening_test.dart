import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/history/history_deletion.dart';
import 'package:quadrille/features/session/session_providers.dart';

import '../exercises/history_fixture.dart';
import 'history_deletion_fixture.dart';

void main() {
  late DeletionFixture fixture;
  setUp(() async {
    fixture = DeletionFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  Future<HistoryDeletionOpening> open() async {
    final owner = fixture.container.read(historyDeletionProvider);
    final workout = (await fixture.aRepository.watchSession('session').first)!;
    final opening = owner.open(workout);
    addTearDown(opening.release);
    return opening;
  }

  test(
    'one opening claims pending before reentry and deletion is terminal',
    () async {
      final opening = await open();
      expect(opening.sessionId, 'session');
      expect(opening.name, 'Push session');
      expect(opening.startedAt, HistoryFixture.date);
      expect(opening.state, HistoryDeletionState.idle);
      expect(opening.canSubmit, isTrue);
      final gate = DeletionWrite();
      fixture.aRepository.waiting = gate;
      Future<HistoryDeletionState>? reentrant;
      opening.addListener(() {
        if (opening.state == HistoryDeletionState.pending) {
          expect(opening.canSubmit, isFalse);
          reentrant = opening.delete();
        }
      });
      final first = opening.delete();
      expect(reentrant, same(first));
      expect(opening.delete(), same(first));
      await gate.entered.future;
      expect(fixture.aRepository.submissions, 1);
      gate.completion.complete();
      expect(await first, HistoryDeletionState.deleted);
      expect(opening.canSubmit, isFalse);
      expect(await opening.delete(), HistoryDeletionState.deleted);
      expect(fixture.aRepository.submissions, 1);
      expect(await fixture.exists(fixture.aRepository), isFalse);
      expect(await fixture.exists(fixture.bRepository), isTrue);
    },
  );

  test('a current failure permits one independent retry', () async {
    final opening = await open();
    final failed = DeletionWrite()..fail = true;
    fixture.aRepository.waiting = failed;
    final first = opening.delete();
    await failed.entered.future;
    failed.completion.complete();
    expect(await first, HistoryDeletionState.failed);
    expect(opening.state, HistoryDeletionState.failed);
    expect(opening.canSubmit, isTrue);
    expect(await fixture.exists(fixture.aRepository), isTrue);

    final gate = DeletionWrite();
    fixture.aRepository.waiting = gate;
    final retry = opening.delete();
    expect(retry, isNot(same(first)));
    expect(opening.delete(), same(retry));
    await gate.entered.future;
    gate.completion.complete();
    expect(await retry, HistoryDeletionState.deleted);
    expect(fixture.aRepository.submissions, 2);
    expect(await fixture.exists(fixture.aRepository), isFalse);
  });

  for (final target in ['missing', 'deleted', 'discarded', 'active']) {
    test(
      '$target workout is unavailable and terminal through the opening',
      () async {
        final workout = (await fixture.aRepository
            .watchSession('session')
            .first)!;
        var snapshot = workout;
        switch (target) {
          case 'missing':
            snapshot = workout.copyWith(id: 'missing');
          case 'deleted':
            await fixture.aRepository.deleteCompletedSession('session');
          case 'discarded':
          case 'active':
            await HistoryFixture(
              fixture.a,
            ).workout('protected', status: SessionStatus.active);
            snapshot = (await fixture.aRepository
                .watchSession('protected')
                .first)!;
            if (target == 'discarded') {
              await fixture.aRepository.discardSession('protected');
            }
        }
        final opening = fixture.container
            .read(historyDeletionProvider)
            .open(snapshot);
        addTearDown(opening.release);
        final before = fixture.aRepository.submissions;
        expect(await opening.delete(), HistoryDeletionState.unavailable);
        expect(opening.state, HistoryDeletionState.unavailable);
        expect(opening.isCurrent, isTrue);
        expect(opening.canSubmit, isFalse);
        expect(await opening.delete(), HistoryDeletionState.unavailable);
        expect(fixture.aRepository.submissions, before + 1);
        if (target == 'active') {
          expect(await fixture.aRepository.readGrid('protected'), hasLength(1));
        }
      },
    );
  }

  test(
    'independent confirmations retain their snapshots and compete through persistence',
    () async {
      final first = await open();
      final second = await open();
      final gate = DeletionWrite();
      fixture.aRepository.waiting = gate;
      final deletion = first.delete();
      await gate.entered.future;
      expect(second.state, HistoryDeletionState.idle);
      fixture.aRepository.waiting = null;
      expect(await second.delete(), HistoryDeletionState.deleted);
      gate.completion.complete();
      expect(await deletion, HistoryDeletionState.unavailable);
      expect(first.name, 'Push session');
      expect(first.startedAt, HistoryFixture.date);
      expect(second.name, first.name);
      expect(fixture.aRepository.submissions, 2);
    },
  );

  void retire(String reason) {
    switch (reason) {
      case 'release':
        throw StateError('Release is opening-specific');
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
        fixture.replacement = fixture.bRepository;
        fixture.container.invalidate(sessionRepositoryProvider);
      case 'module invalidation':
        fixture.container.invalidate(historyDeletionProvider);
      case 'container disposal':
        fixture.disposeOwner();
    }
  }

  for (final reason in [
    'release',
    'profile switch',
    'unobserved round trip',
    'database replacement',
    'repository replacement',
    'module invalidation',
    'container disposal',
  ]) {
    for (final duringNotification in [false, true]) {
      test(
        '$reason ${duringNotification ? 'from a pending listener' : 'before submission'} rejects admission',
        () async {
          final opening = await open();
          void revoke() {
            if (reason == 'release') {
              opening.release();
              opening.release();
            } else {
              retire(reason);
            }
          }

          if (duringNotification) {
            opening.addListener(() {
              if (opening.state == HistoryDeletionState.pending) revoke();
            });
          } else {
            revoke();
          }
          expect(await opening.delete(), HistoryDeletionState.superseded);
          expect(opening.state, HistoryDeletionState.superseded);
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(fixture.aRepository.submissions, 0);
          expect(fixture.bRepository.submissions, 0);
          expect(await fixture.exists(fixture.aRepository), isTrue);
          expect(await fixture.exists(fixture.bRepository), isTrue);
        },
      );
    }

    for (final outcome in ['success', 'failure', 'unavailable']) {
      test(
        '$reason supersedes accepted $outcome and retains its destination',
        () async {
          final owner = fixture.container.read(historyDeletionProvider);
          final snapshot = (await fixture.aRepository
              .watchSession('session')
              .first)!;
          final opening = await open();
          final gate = DeletionWrite()
            ..fail = outcome == 'failure'
            ..unavailable = outcome == 'unavailable';
          fixture.aRepository.waiting = gate;
          var notifications = 0;
          opening.addListener(() => notifications++);
          final pending = opening.delete();
          await gate.entered.future;
          if (reason == 'release') {
            opening.release();
            opening.release();
          } else {
            retire(reason);
          }
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(await opening.delete(), HistoryDeletionState.superseded);
          gate.completion.complete();
          expect(await pending, HistoryDeletionState.superseded);
          expect(opening.state, HistoryDeletionState.superseded);
          expect(
            await fixture.exists(fixture.aRepository),
            outcome != 'success',
          );
          expect(await fixture.exists(fixture.bRepository), isTrue);
          expect(fixture.aRepository.submissions, 1);
          expect(fixture.bRepository.submissions, 0);
          if (reason == 'release') {
            expect(notifications, 1);
          } else {
            final obsolete = owner.open(snapshot);
            addTearDown(obsolete.release);
            expect(obsolete.canSubmit, isFalse);
          }

          if (fixture.disposed) fixture.createOwner();
          final destination =
              fixture.replacement ??
              (identical(fixture.current, fixture.a)
                  ? fixture.aRepository
                  : fixture.bRepository);
          // The old target may now be deleted, but a new owner's opening still
          // admits persistence and the repository decides target availability.
          destination.waiting = null;
          final fresh = fixture.container
              .read(historyDeletionProvider)
              .open(snapshot);
          addTearDown(fresh.release);
          expect(fresh.canSubmit, isTrue);
          final available = await fixture.exists(destination);
          expect(
            await fresh.delete(),
            available
                ? HistoryDeletionState.deleted
                : HistoryDeletionState.unavailable,
          );
          expect(opening.isCurrent, isFalse);
        },
      );
    }
  }

  test('an unobserved owner retains openings across provider pumps', () async {
    final opening = await open();
    await fixture.container.pump();
    expect(opening.canSubmit, isTrue);
    expect(await opening.delete(), HistoryDeletionState.deleted);
  });
}
